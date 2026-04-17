// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Staking.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract StakingTest is Test {
    MockERC20 internal stakingToken;
    MockERC20 internal rewardToken;
    Staking internal staking;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant INITIAL_MINT = 1_000_000 ether;
    uint256 internal constant STAKE_AMOUNT = 100 ether;
    uint256 internal constant REWARD_PER_BLOCK = 1 ether;

    function setUp() public {
        stakingToken = new MockERC20("Stake Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");

        stakingToken.mint(alice, INITIAL_MINT);
        stakingToken.mint(bob, INITIAL_MINT);
        rewardToken.mint(owner, INITIAL_MINT);

        uint256 startBlock = block.number;
        uint256 endBlock = startBlock + 1_000;

        staking = new Staking(
            address(stakingToken),
            address(rewardToken),
            REWARD_PER_BLOCK,
            startBlock,
            endBlock
        );

        // fund rewards
        rewardToken.approve(address(staking), INITIAL_MINT);
        staking.fundRewards(500_000 ether);
    }



    function testConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(address(0), address(rewardToken), REWARD_PER_BLOCK, block.number, block.number + 10);

        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(address(stakingToken), address(0), REWARD_PER_BLOCK, block.number, block.number + 10);
    }

    function testConstructorRevertsOnZeroRewardPerBlock() public {
        vm.expectRevert(Staking.ZeroAmount.selector);
        new Staking(address(stakingToken), address(rewardToken), 0, block.number, block.number + 10);
    }

    function testConstructorRevertsOnInvalidRange() public {
        vm.expectRevert(Staking.InvalidRewardRange.selector);
        new Staking(address(stakingToken), address(rewardToken), REWARD_PER_BLOCK, 10, 5);
    }

  

    function testDepositAndAccrueRewards() public {
        vm.startPrank(alice);
        stakingToken.approve(address(staking), STAKE_AMOUNT);
        staking.deposit(STAKE_AMOUNT);
        vm.stopPrank();

 
        vm.roll(block.number + 10);


        uint256 pending = staking.pendingReward(alice);
        assertEq(pending, 10 * REWARD_PER_BLOCK, "pending reward");

        uint256 beforeBalance = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.claim();

        uint256 afterBalance = rewardToken.balanceOf(alice);
        assertEq(afterBalance - beforeBalance, 10 * REWARD_PER_BLOCK, "claimed reward");
    }

    function testWithdrawReturnsPrincipalAndKeepsRewardsCorrect() public {
        vm.startPrank(alice);
        stakingToken.approve(address(staking), STAKE_AMOUNT);
        staking.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        vm.roll(block.number + 5);

        vm.prank(alice);
        staking.withdraw(STAKE_AMOUNT);

   
        assertEq(stakingToken.balanceOf(alice), INITIAL_MINT, "principal returned");


        uint256 expectedReward = 5 * REWARD_PER_BLOCK;
        uint256 aliceRewardBalance = rewardToken.balanceOf(alice);
        assertEq(aliceRewardBalance, expectedReward, "reward on withdraw");
        (uint256 amount, uint256 rewardDebt) = staking.userInfo(alice);
        assertEq(amount, 0, "user amount");
        assertEq(rewardDebt, 0, "user rewardDebt");
    }

    function testDepositBeforeStartReverts() public {
    
        uint256 startBlock = block.number + 10;
        uint256 endBlock = startBlock + 100;

        Staking futurePool = new Staking(
            address(stakingToken),
            address(rewardToken),
            REWARD_PER_BLOCK,
            startBlock,
            endBlock
        );

        rewardToken.approve(address(futurePool), INITIAL_MINT);
        futurePool.fundRewards(1000 ether);

        vm.startPrank(alice);
        stakingToken.approve(address(futurePool), STAKE_AMOUNT);
        vm.expectRevert(Staking.RewardsNotStarted.selector);
        futurePool.deposit(STAKE_AMOUNT);
        vm.stopPrank();
    }

    // --- owner functions ---

    function testOnlyOwnerCanSetOwner() public {
        vm.prank(alice);
        vm.expectRevert(Staking.NotOwner.selector);
        staking.setOwner(bob);

        staking.setOwner(bob);
        assertEq(staking.owner(), bob);
    }

    function testPausePreventsUserActions() public {
        staking.setPaused(true);
        vm.expectRevert(Staking.ContractPaused.selector);
        staking.deposit(0);

        vm.expectRevert(Staking.ContractPaused.selector);
        staking.withdraw(0);

        vm.expectRevert(Staking.ContractPaused.selector);
        staking.claim();
    }

    function testFundAndWithdrawUnusedRewards() public {
        uint256 initialFunded = staking.totalRewardsFunded();

        // withdraw part of unused rewards
        uint256 withdrawAmount = 10_000 ether;
        uint256 before = rewardToken.balanceOf(owner);

        staking.withdrawUnusedRewards(owner, withdrawAmount);

        assertEq(staking.totalRewardsFunded(), initialFunded - withdrawAmount);
        assertEq(rewardToken.balanceOf(owner) - before, withdrawAmount);
    }

    function testWithdrawUnusedRewardsCannotExceedAvailable() public {

        vm.roll(block.number + 100);

        uint256 available = _availableRewardBalanceExternal();
        vm.expectRevert(Staking.InsufficientRewardFunding.selector);
        staking.withdrawUnusedRewards(owner, available + 1);
    }


    function testEmergencyWithdrawSkipsRewardsAndResetsUser() public {
        vm.startPrank(alice);
        stakingToken.approve(address(staking), STAKE_AMOUNT);
        staking.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        vm.roll(block.number + 20);

        vm.prank(alice);
        staking.emergencyWithdraw();


        assertEq(stakingToken.balanceOf(alice), INITIAL_MINT, "principal");
        assertEq(rewardToken.balanceOf(alice), 0, "no rewards");

        (uint256 amount, uint256 rewardDebt) = staking.userInfo(alice);
        assertEq(amount, 0);
        assertEq(rewardDebt, 0);
    }

      function testGetUserPositionReturnsExpectedValues() public {
        vm.startPrank(alice);
        stakingToken.approve(address(staking), STAKE_AMOUNT);
        staking.deposit(STAKE_AMOUNT);
        vm.stopPrank();
        vm.roll(block.number + 12);
        (uint256 stakedAmount, uint256 pending, uint256 rewardDebt) = staking.getUserPosition(alice);
        assertEq(stakedAmount, STAKE_AMOUNT, "staked amount");
        assertEq(pending, 12 * REWARD_PER_BLOCK, "pending reward");
        assertEq(rewardDebt, 0, "reward debt");
    }



    function _availableRewardBalanceExternal() internal view returns (uint256) {

        uint256 fundedMinusPaid = staking.totalRewardsFunded() - staking.totalRewardsPaid();
        uint256 contractRewardBalance = rewardToken.balanceOf(address(staking));

        if (address(rewardToken) == address(stakingToken)) {
            uint256 totalStaked = staking.totalStaked();
            if (contractRewardBalance <= totalStaked) return 0;
            contractRewardBalance -= totalStaked;
        }

        return contractRewardBalance < fundedMinusPaid ? contractRewardBalance : fundedMinusPaid;
    }
}

