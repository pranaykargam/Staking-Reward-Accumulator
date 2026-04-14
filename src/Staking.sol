// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Staking {
    uint256 private constant PRECISION = 1e12;

    IERC20 public immutable STAKING_TOKEN;   // TOKEN users stake
    IERC20 public immutable REWARD_TOKEN;    // REWARD users earn

    uint256 public immutable REWARD_PER_BLOCK;    // e.g. 1000 REWARD per block
    uint256 public lastRewardBlock;            // like lastUpdateBlockNumber
    uint256 public accRewardPerToken;          // accumulated reward per 1 TOKEN, scaled by 1e12
    uint256 public totalStaked;                // total TOKEN in the pool

    struct UserInfo {
        uint256 amount;        // how many TOKEN the user has staked
        uint256 rewardDebt;    // amount * accRewardPerToken / 1e12 at last action
    }

    mapping(address => UserInfo) public userInfo;

    error ZeroAddress();
    error WithdrawExceedsBalance();
    error TokenTransferFailed();

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);

    constructor(
        address _stakingToken,
        address _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) revert ZeroAddress();
        STAKING_TOKEN = IERC20(_stakingToken);
        REWARD_TOKEN = IERC20(_rewardToken);
        REWARD_PER_BLOCK = _rewardPerBlock;
        lastRewardBlock = _startBlock;
    }

    // ========== view math helper ==========

    function pendingReward(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 _accRewardPerToken = accRewardPerToken;

        if (block.number > lastRewardBlock && totalStaked != 0) {
            uint256 blocks = block.number - lastRewardBlock;
            uint256 reward = blocks * REWARD_PER_BLOCK;
            _accRewardPerToken += reward * PRECISION / totalStaked;
        }

        return user.amount * _accRewardPerToken / PRECISION - user.rewardDebt;
    }

    // ========== core math logic ==========

    // update global accumulator based on how many blocks passed
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) return;

        if (totalStaked == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 blocks = block.number - lastRewardBlock;
        uint256 reward = blocks * REWARD_PER_BLOCK;

        // assume rewardToken is pre-funded to this contract
        accRewardPerToken += reward * PRECISION / totalStaked;
        lastRewardBlock = block.number;
    }

    // settle user's pending reward and send it
    function _harvest(address _user) internal {
        UserInfo storage user = userInfo[_user];
        uint256 pending = user.amount * accRewardPerToken / PRECISION - user.rewardDebt;
        if (pending > 0) {
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

    // ========== core user functions ==========

    // deposit = "stake" in one function
    function deposit(uint256 _amount) external {
        _updatePool();                 // 1) update global math
        _harvest(msg.sender);          // 2) pay old rewards
        if (_amount > 0) {
            _safeTransferFrom(STAKING_TOKEN, msg.sender, address(this), _amount);
            userInfo[msg.sender].amount += _amount;
            totalStaked += _amount;
            emit Deposited(msg.sender, _amount);
        }
        _updateUser(msg.sender);       // 3) refresh rewardDebt
    }

    function withdraw(uint256 _amount) external {
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

    // optional: claim rewards without changing stake
    function claim() external {
        _updatePool();
        _harvest(msg.sender);
        _updateUser(msg.sender);
    }

    // emergency path: skip rewards, only unstake principal
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) return;

        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;

        _safeTransfer(STAKING_TOKEN, msg.sender, amount);
        emit EmergencyWithdrawn(msg.sender, amount);
    }
}

