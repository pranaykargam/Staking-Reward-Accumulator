// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//  MasterChef is important because it solves the scalability problem of rewarding millions of users by using a mathematical formula based on function 
// "accumulated rewards per token" rather than looping through every staker.

// That interface is just the minimal ERC‑20 API your staking contract needs so it can move tokens in and out
// this interface is the small “bridge” that lets your staking contract talk to any ERC‑20 token for staking and rewards.

// The key differentiator of MasterChef compared to other DeFi staking protocols is its reward debt mechanism. When users deposit tokens, MasterChef calculates their "reward debt" as their deposited balance multiplied by the current reward accumulator.
//  This prevents users from claiming rewards they didn't earn—for example, if Bob deposits after Alice has been staking for a while, he can't immediately claim rewards that Alice earned.


// Gas efficiency: Uses a single accumulator variable rather than iterating through all users
// Automatic reward distribution: Rewards are transferred immediately when users deposit or withdraw, not stored separately
// Multi-pool support: A single MasterChef contract manages multiple staking pools with different reward weights
// Block-based timing: Uses block numbers rather than timestamps for reward calculations
// Self-minting rewards: MasterChef mints reward tokens to itself rather than requiring pre-funded rewards
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract Staking {

    // Quick confirmation of what counts as state variables:

   // ✅ Declared at contract level (not inside functions)
   // ✅ Stored on-chain (persist across transactions)
  // ✅ Include: constants, immutables, public/private vars

  // Immutables (set once in constructor, read from bytecode):

  // Mutable public state variables (readable via getters, updatable):

  // Constructors initialize the object’s state at creation time and can enforce required values or validation.

// State variables are the fields that hold the object’s data and can usually be read or changed later depending on visibility and whether they are final.

// A constructor is a special function with the same name as the class and ** no return type **, while a state variable is just a variable declared inside the class.


// olidity cannot handle decimals well, so it stores the number scaled up,
    uint256 private constant PRECISION = 1e12; // 12 decimals matches most stablecoin oracles and prediction market needs

    IERC20 public immutable REWARD_TOKEN;
    uint256 public immutable REWARD_PER_BLOCK; // e.g. 1000 REWARD per block
    uint256 public immutable START_BLOCK;
    uint256 public immutable END_BLOCK;

    uint256 public lastRewardBlock; // like lastUpdateBlockNumber
    uint256 public accRewardPerToken; // accumulated reward per 1 TOKEN, scaled by 1e12
    uint256 public totalStaked; // total TOKEN in the pool
    uint256 public totalRewardsFunded;
    uint256 public totalRewardsPaid;
    uint256 public totalAllocPoint;
    address public owner;
    bool public isPaused;
    uint256 private _locked = 1;

// blue print for the UserInfo
    struct UserInfo {
        uint256 amount; // how many TOKEN the user has staked
        uint256 rewardDebt; // amount * accRewardPerToken / 1e12 at last action
    }

    // blueprint for each reward pool
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint; // how many reward points assigned to this pool
        uint256 lastRewardBlock; // last block number that reward distribution occurs
        uint256 accRewardPerShare; // accumulated reward per share, times 1e12
        uint256 totalStaked; // total tokens staked in this pool
    }

    // it stores the data of UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    PoolInfo[] public poolInfo;

    error ZeroAddress();
    error NotOwner();
    error ZeroAmount();
    error WithdrawExceedsBalance();
    error RewardsNotStarted();
    error InvalidRewardRange();
    error InvalidPool();
    error ContractPaused();
    error Reentrancy();
    error InsufficientRewardFunding();
    error TokenTransferFailed();


// display only this user’s deposit history, instead of scanning every deposit made by everyone.
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event PauseUpdated(bool isPaused);
    event RewardFunded(address indexed by, uint256 amount);
    event RewardWithdrawn(address indexed to, uint256 amount);
    event Deposited(uint256 indexed pid, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event Claimed(uint256 indexed pid, address indexed user, uint256 amount);
    event EmergencyWithdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event PoolAdded(uint256 indexed pid, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);

    // ========== constructor ==========
  // We use the constructor to initialize the contract with correct values before anyone starts using it.
      constructor(
        address _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) {
        if (_rewardToken == address(0))
            revert ZeroAddress();
        if (_rewardPerBlock == 0) revert ZeroAmount();
        if (_endBlock <= _startBlock) revert InvalidRewardRange();
        REWARD_TOKEN = IERC20(_rewardToken);
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        END_BLOCK = _endBlock;
        lastRewardBlock = _startBlock;
        owner = msg.sender;
    }

    // ========== view math helper ==========
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        // Because it is view, it only reads state and does not modify balances or update checkpoints.
        _requireValidPool(_pid);
        UserInfo memory user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfo[_pid];
        uint256 _accRewardPerToken = pool.accRewardPerShare;

        uint256 fromBlock = pool.lastRewardBlock;
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (
            toBlock > fromBlock &&
            pool.totalStaked != 0 &&
            totalAllocPoint != 0
        ) {
            uint256 blocks = toBlock - fromBlock;
            uint256 reward = (blocks * REWARD_PER_BLOCK * pool.allocPoint) / totalAllocPoint;
            _accRewardPerToken += (reward * PRECISION) / pool.totalStaked;
        }
        return (user.amount * _accRewardPerToken) / PRECISION - user.rewardDebt;
    }

    // ========== core math logic ==========
// reusable piece of code
  
    modifier onlyOwner(){
        if (msg.sender != owner) revert NotOwner();
        _;
    }


    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2; //(Lock before execution)
        _; // (Execute the function)
        _locked = 1; // (Unlock after completion)
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _requireValidPool(uint256 _pid) internal view {
        if (_pid >= poolInfo.length) revert InvalidPool();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock_ = block.number > START_BLOCK ? block.number : START_BLOCK;
        totalAllocPoint += _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock_,
            accRewardPerShare: 0,
            totalStaked: 0
        }));
        emit PoolAdded(poolInfo.length - 1, _allocPoint);
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        _requireValidPool(_pid);
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint;
        emit PoolUpdated(_pid, _allocPoint);
    }

  

     // It implements the MasterChef pattern - Instead of looping through all stakers,
  // it maintains a single accumulator (accRewardPerToken) that tracks accumulated rewards per token.

  // rewardDebt means: the rewards the contract has already counted for you.
// Simple example:
// Alice stakes early. Rewards grow. Later Bob joins.
// Without rewardDebt, Bob might look like he deserves some old rewards from before he joined. That would be unfair.

    
    function _updatePool(uint256 _pid) internal {
        _requireValidPool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (toBlock <= pool.lastRewardBlock) return;

        if (pool.totalStaked == 0 || totalAllocPoint == 0) {
            pool.lastRewardBlock = toBlock;
            return;
        }

        uint256 blocks = toBlock - pool.lastRewardBlock;
        uint256 reward = (blocks * REWARD_PER_BLOCK * pool.allocPoint) / totalAllocPoint;

        // assume rewardToken is pre-funded to this contract
        pool.accRewardPerShare += (reward * PRECISION) / pool.totalStaked;
        pool.lastRewardBlock = toBlock;

        // accRewardPerShare = it tracks how much reward each 1 staked token has earned until now.
    }

    function massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }





    // settle user's pending reward and send it
    // Harvest function means collect your earned rewards.

    // harvest is the moment when we are calculating and paying the user’s current pending reward.
    function _harvest(uint256 _pid, address _user) internal {
        _requireValidPool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 pending = (user.amount * pool.accRewardPerShare) /
            PRECISION -
            user.rewardDebt;
        if (pending > 0) {
            if (pending > _availableRewardBalance())
                revert InsufficientRewardFunding();
            totalRewardsPaid += pending;
            _safeTransfer(REWARD_TOKEN, _user, pending);
            emit Claimed(_pid, _user, pending);
        }
    }


// // _updateUser() is not the place where we calculate what the user should receive, so we do not subtract rewardDebt there.
    function _updateUser(uint256 _pid, address _user) internal {
        _requireValidPool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bool success = token.transfer(to, amount);
        if (!success) revert TokenTransferFailed();
    }


// It makes sure the token transfer really happened; if not, the whole transaction fails.
    function _safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success = token.transferFrom(from, to, amount);
        if (!success) revert TokenTransferFailed();
    }


// This function calculates the maximum reward tokens currently available for distribution from the contract.

//      Example setup
// totalRewardsFunded = 10,000
// totalRewardsPaid = 3,000
// contractRewardBalance = 8,000
// totalStaked = 2,000
// REWARD_TOKEN != STAKING_TOKEN

// Then:
// fundedMinusPaid = 10,000 - 3,000 = 7,000
// Since reward token and staking token are different, no principal subtraction happens.
// Return value = min(8,000, 7,000) = 7,000
// So _availableRewardBalance() returns 7,000.
    function _availableRewardBalance() internal view returns (uint256) {
        uint256 fundedMinusPaid = totalRewardsFunded - totalRewardsPaid;
        uint256 contractRewardBalance = REWARD_TOKEN.balanceOf(address(this));

        return
            contractRewardBalance < fundedMinusPaid
                ? contractRewardBalance 
                : fundedMinusPaid;
    }

    // ========== owner functions ==========

// onlyOwner → only current owner can call.
// require(_newOwner != address(0)) → new owner must be valid.
// owner = _newOwner → update in storage.
    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerUpdated(owner, _newOwner);
        owner = _newOwner;
    }




// It’s an admin function that lets the contract owner pause or unpause the protocol.
// To give the owner an emergency stop switch for the protocol.


// Here are the 3 major reasons to mark owner-only functions like setPaused as external in Solidity:
// Gas Optimization
// Owner calls via MetaMask/wallet transaction
// Contract never calls itself (no internal usage)
// Industry Standard
// OpenZeppelin (Ownable, Pausable, AccessControl) uses external for all owner-only functions:
    function setPaused (bool _paused) external onlyOwner {
        isPaused = _paused;
        emit PauseUpdated (_paused);
    }


// This function lets the contract owner put reward tokens into the contract so that they can later be paid out to users as rewards.

//  it adds reward tokens into the contract’s pool, it does not send them to users yet.    
        function fundRewards(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        _safeTransferFrom(REWARD_TOKEN, msg.sender, address(this), _amount);
        totalRewardsFunded += _amount;
        emit RewardFunded(msg.sender, _amount);
    }




    function withdrawUnusedRewards(
        address _to,
        uint256 _amount // _amount: how many reward tokens to withdraw.
    ) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > _availableRewardBalance())
            revert InsufficientRewardFunding();

        totalRewardsFunded -= _amount;
        _safeTransfer(REWARD_TOKEN, _to, _amount);
        emit RewardWithdrawn(_to, _amount);
    }

    // ========== core user functions ==========

    // deposit = "stake" in one function
    function deposit(uint256 _pid, uint256 _amount) external {
        depositFor(_pid, msg.sender, _amount);
    }

// depositFor is a staking/deposit function that lets any caller deposit _amount of STAKING_TOKEN into the protocol on behalf of a _beneficiary,
//  while correctly updating rewards and accounting for that user. It is typically used in a stake‑and‑earn‑rewards design pattern
    function depositFor(
        uint256 _pid,
        address _beneficiary,
        uint256 _amount
    ) public whenNotPaused nonReentrant {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (block.number < START_BLOCK) revert RewardsNotStarted();
        _requireValidPool(_pid);

        PoolInfo storage pool = poolInfo[_pid];

        // 1) synchronize rewards state for the whole pool
        _updatePool(_pid);
        // 2) settle any pending rewards for the beneficiary
        _harvest(_pid, _beneficiary);

        if (_amount > 0) {
            // transfer stake from caller to contract, then credit beneficiary
            _safeTransferFrom(
                pool.lpToken,
                msg.sender,
                address(this),
                _amount
            );
            userInfo[_pid][_beneficiary].amount += _amount;
            pool.totalStaked += _amount;
            totalStaked += _amount;
            emit Deposited(_pid, _beneficiary, _amount);
        }

        // 3) refresh the beneficiary's reward debt snapshot
        _updateUser(_pid, _beneficiary);
    }

    function withdraw(uint256 _pid, uint256 _amount) external whenNotPaused nonReentrant {
        _requireValidPool(_pid);
        PoolInfo storage pool = poolInfo[_pid];

        // synchronize reward accumulation before withdrawing
        _updatePool(_pid);
        // pay any pending rewards for the withdrawer
        _harvest(_pid, msg.sender);

        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount < _amount) revert WithdrawExceedsBalance();

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
            totalStaked -= _amount;
            _safeTransfer(pool.lpToken, msg.sender, _amount);
            emit Withdrawn(_pid, msg.sender, _amount);
        }

        // refresh withdrawer's reward debt to the new state
        _updateUser(_pid, msg.sender);
    }

    function claim(uint256 _pid) external whenNotPaused nonReentrant {
        _requireValidPool(_pid);
        _updatePool(_pid);
        _harvest(_pid, msg.sender);
        _updateUser(_pid, msg.sender);
    }


// “Send all staked tokens back to the user, wipe their stake and reward snapshot, and ensure they can’t get stuck in the pool.”
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        _requireValidPool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) return;

        user.amount = 0;
        user.rewardDebt = 0;
        pool.totalStaked -= amount;
        totalStaked -= amount;

        _safeTransfer(pool.lpToken, msg.sender, amount);
        emit EmergencyWithdrawn(_pid, msg.sender, amount);
    }


// is a view function in a Solidity staking contract that retrieves a user's current staked amount, pending rewards (unharvested), 
// and rewardDebt (tracks claimed rewards to prevent double-claiming).
    function getUserPosition(
        uint256 _pid,
        address _user
    )
        external
        view
        returns (uint256 stakedAmount, uint256 pending, uint256 rewardDebt)
    {
        _requireValidPool(_pid);
        UserInfo memory user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfo[_pid];
        stakedAmount = user.amount;
        rewardDebt = user.rewardDebt;

        uint256 _accRewardPerToken = pool.accRewardPerShare;
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (
            toBlock > pool.lastRewardBlock &&
            pool.totalStaked != 0 &&
            totalAllocPoint != 0
        ) {
            uint256 blocks = toBlock - pool.lastRewardBlock;
            uint256 reward = (blocks * REWARD_PER_BLOCK * pool.allocPoint) / totalAllocPoint;
            _accRewardPerToken += (reward * PRECISION) / pool.totalStaked;
        }

        pending =
            (user.amount * _accRewardPerToken) /
            PRECISION -
            user.rewardDebt;
    }
}
