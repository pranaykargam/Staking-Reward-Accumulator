// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// That interface is just the minimal ERC‑20 API your staking contract needs so it can move tokens in and out
// this interface is the small “bridge” that lets your staking contract talk to any ERC‑20 token for staking and rewards.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}





contract Staking {
    uint256 private constant PRECISION = 1e12; // 12 decimals matches most stablecoin oracles and prediction market needs 

    IERC20 public immutable STAKING_TOKEN;   
    IERC20 public immutable REWARD_TOKEN;    

    uint256 public immutable REWARD_PER_BLOCK;    // e.g. 1000 REWARD per block
    uint256 public immutable START_BLOCK;
    uint256 public immutable END_BLOCK;
    uint256 public lastRewardBlock;            // like lastUpdateBlockNumber
    uint256 public accRewardPerToken;          // accumulated reward per 1 TOKEN, scaled by 1e12
    uint256 public totalStaked;                // total TOKEN in the pool
    uint256 public totalRewardsFunded;
    uint256 public totalRewardsPaid;
    address public owner;
    bool public isPaused;
    uint256 private _locked = 1;

    struct UserInfo {
        uint256 amount;        // how many TOKEN the user has staked
        uint256 rewardDebt;    // amount * accRewardPerToken / 1e12 at last action
    }

    mapping(address => UserInfo) public userInfo;

    error ZeroAddress();
    error NotOwner();
    error ZeroAmount();
    error WithdrawExceedsBalance();
    error RewardsNotStarted();
    error InvalidRewardRange();
    error ContractPaused();
    error Reentrancy();
    error InsufficientRewardFunding();
    error TokenTransferFailed();

    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event PauseUpdated(bool isPaused);
    event RewardFunded(address indexed by, uint256 amount);
    event RewardWithdrawn(address indexed to, uint256 amount);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);

    constructor(
        address _stakingToken,
        address _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) revert ZeroAddress();
        if (_rewardPerBlock == 0) revert ZeroAmount();
        if (_endBlock <= _startBlock) revert InvalidRewardRange();
        STAKING_TOKEN = IERC20(_stakingToken);
        REWARD_TOKEN = IERC20(_rewardToken);
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        END_BLOCK = _endBlock;
        lastRewardBlock = _startBlock;
        owner = msg.sender;
    }

    // ========== view math helper ==========

    function pendingReward(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 _accRewardPerToken = accRewardPerToken;

        uint256 fromBlock = lastRewardBlock;
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (toBlock > fromBlock && totalStaked != 0) {
            uint256 blocks = toBlock - fromBlock;
            uint256 reward = blocks * REWARD_PER_BLOCK;
            _accRewardPerToken += reward * PRECISION / totalStaked;
        }

        return user.amount * _accRewardPerToken / PRECISION - user.rewardDebt;
    }

    // ========== core math logic ==========

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // update global accumulator based on how many blocks passed
    function _updatePool() internal {
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (toBlock <= lastRewardBlock) return;

        if (totalStaked == 0) {
            lastRewardBlock = toBlock;
            return;
        }

        uint256 blocks = toBlock - lastRewardBlock;
        uint256 reward = blocks * REWARD_PER_BLOCK;

        // assume rewardToken is pre-funded to this contract
        accRewardPerToken += reward * PRECISION / totalStaked;
        lastRewardBlock = toBlock;
    }

    // settle user's pending reward and send it
    function _harvest(address _user) internal {
        UserInfo storage user = userInfo[_user];
        uint256 pending = user.amount * accRewardPerToken / PRECISION - user.rewardDebt;
        if (pending > 0) {
            if (pending > _availableRewardBalance()) revert InsufficientRewardFunding();
            totalRewardsPaid += pending;
            _safeTransfer(REWARD_TOKEN, _user, pending);
            emit Claimed(_user, pending);
        }
    }

    // update user's rewardDebt snapshot
    function _updateUser(address _user) internal {
        UserInfo storage user = userInfo[_user];
        user.rewardDebt = user.amount * accRewardPerToken / PRECISION;
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bool success = token.transfer(to, amount);
        if (!success) revert TokenTransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bool success = token.transferFrom(from, to, amount);
        if (!success) revert TokenTransferFailed();
    }

    function _availableRewardBalance() internal view returns (uint256) {
        uint256 fundedMinusPaid = totalRewardsFunded - totalRewardsPaid;
        uint256 contractRewardBalance = REWARD_TOKEN.balanceOf(address(this));

        // If staking token and reward token are the same asset, staked principal must remain untouchable.
        if (address(REWARD_TOKEN) == address(STAKING_TOKEN)) {
            if (contractRewardBalance <= totalStaked) return 0;
            contractRewardBalance -= totalStaked;
        }

        return contractRewardBalance < fundedMinusPaid ? contractRewardBalance : fundedMinusPaid;
    }

    // ========== owner functions ==========

    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerUpdated(owner, _newOwner);
        owner = _newOwner;
    }

    function setPaused(bool _paused) external onlyOwner {
        isPaused = _paused;
        emit PauseUpdated(_paused);
    }

    function fundRewards(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        _safeTransferFrom(REWARD_TOKEN, msg.sender, address(this), _amount);
        totalRewardsFunded += _amount;
        emit RewardFunded(msg.sender, _amount);
    }

    function withdrawUnusedRewards(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        _updatePool();
        if (_amount > _availableRewardBalance()) revert InsufficientRewardFunding();

        totalRewardsFunded -= _amount;
        _safeTransfer(REWARD_TOKEN, _to, _amount);
        emit RewardWithdrawn(_to, _amount);
    }

    // ========== core user functions ==========

    // deposit = "stake" in one function
    function deposit(uint256 _amount) external {
        depositFor(msg.sender, _amount);
    }

    function depositFor(address _beneficiary, uint256 _amount) public whenNotPaused nonReentrant {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (block.number < START_BLOCK) revert RewardsNotStarted();

        _updatePool();                 // 1) update global math
        _harvest(_beneficiary);        // 2) pay old rewards
        if (_amount > 0) {
            _safeTransferFrom(STAKING_TOKEN, msg.sender, address(this), _amount);
            userInfo[_beneficiary].amount += _amount;
            totalStaked += _amount;
            emit Deposited(_beneficiary, _amount);
        }
        _updateUser(_beneficiary);     // 3) refresh rewardDebt
    }

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        _updatePool();
        _harvest(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount < _amount) revert WithdrawExceedsBalance();

        if (_amount > 0) {
            user.amount -= _amount;
            totalStaked -= _amount;
            _safeTransfer(STAKING_TOKEN, msg.sender, _amount);
            emit Withdrawn(msg.sender, _amount);
        }

        _updateUser(msg.sender);
    }


    function claim() external whenNotPaused nonReentrant {
        _updatePool();
        _harvest(msg.sender);
        _updateUser(msg.sender);
    }


    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) return;

        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;

        _safeTransfer(STAKING_TOKEN, msg.sender, amount);
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    function getUserPosition(address _user)
        external
        view
        returns (uint256 stakedAmount, uint256 pending, uint256 rewardDebt)
    {
        UserInfo memory user = userInfo[_user];
        stakedAmount = user.amount;
        rewardDebt = user.rewardDebt;

        uint256 _accRewardPerToken = accRewardPerToken;
        uint256 toBlock = _min(block.number, END_BLOCK);
        if (toBlock > lastRewardBlock && totalStaked != 0) {
            uint256 blocks = toBlock - lastRewardBlock;
            uint256 reward = blocks * REWARD_PER_BLOCK;
            _accRewardPerToken += reward * PRECISION / totalStaked;
        }

        pending = user.amount * _accRewardPerToken / PRECISION - user.rewardDebt;
    }
}

