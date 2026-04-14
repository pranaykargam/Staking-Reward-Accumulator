## Staking Protocol
Simple block-based staking contract in `src/Staking.sol`.

### What was improved
- Added **safer token transfers** with explicit return-value checks.
- Added **custom errors** for lower gas and clearer failure reasons.
- Added **events** for deposit, withdraw, claim, and emergency withdraw.
- Added constructor validation for zero token addresses.
- Added `emergencyWithdraw()` so users can recover staked principal without claiming rewards.
- Replaced repeated `1e12` literals with a `PRECISION` constant for readability.


### Core behavior
- Rewards accrue per block as `rewardPerBlock`.
- Global accumulator `accRewardPerToken` tracks rewards per staked token using scaled math.
- User rewards are settled via:
  - `_updatePool()` to update global rewards
  - `_harvest(user)` to transfer pending rewards
  - `_updateUser(user)` to refresh `rewardDebt`

  
### Quick flow
- Stake: `deposit(amount)`
- Unstake: `withdraw(amount)`
- Claim only: `claim()`
- Emergency principal exit: `emergencyWithdraw()`