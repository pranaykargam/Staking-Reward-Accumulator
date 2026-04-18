# Staking Protocol — Theory

This project implements a **block-emission staking pool**: users lock a **staking token**, and the contract distributes a **reward token** over time according to a fixed schedule.

<img src = "./images/img-01.png>

## What problem the math solves

Rewards must be **fair and proportional** to stake size and **time in the pool**, without iterating over every user whenever a block passes. On-chain, you cannot afford \(O(n)\) updates per block.

The standard pattern is a **global reward index** plus a **per-user snapshot** (often called “debt” or “reward debt”). Intuition:

- Think of `accRewardPerToken` as “**cumulative reward units earned per 1 staked token**, since the beginning of the program,” stored with extra precision so fractional rewards do not round away.
- Each user stores `rewardDebt`, which is “**how much of that cumulative index this user has already been credited for**,” at their last interaction.

Then **pending reward** for a user is always:

\[
\text{pending} = \text{stakedAmount} \times \frac{\text{accRewardPerToken}}{\text{PRECISION}} - \text{rewardDebt}
\]

Whenever the user stakes more, withdraws, or claims, the contract **settles** pending rewards, then **resets** `rewardDebt` to match the new stake amount against the current index.

---

## Block schedule and emissions

- **`REWARD_PER_BLOCK`**: how many reward tokens the *program* intends to emit **per block** while the schedule is active.
- **`START_BLOCK` / `END_BLOCK`**: the window in which emissions accrue. After `END_BLOCK`, the pool stops growing the global index (rewards are “capped” in time).

Between two block heights, if nothing changed in total stake, each staked token should receive an equal share of `blocks × REWARD_PER_BLOCK`. The contract folds that into `accRewardPerToken` in `_updatePool()`.

If **`totalStaked == 0`**, there is no one to allocate rewards to: the contract still advances `lastRewardBlock` so time does not create “phantom” backpay for the first depositor.

---

## The global accumulator (`accRewardPerToken`)

`_updatePool()`:

1. Computes how many blocks have passed since `lastRewardBlock`, capped by `min(block.number, END_BLOCK)`.
2. Computes `reward = blocks × REWARD_PER_BLOCK`.
3. Distributes that reward across all stake: increment  
   `accRewardPerToken += reward × PRECISION / totalStaked`.

**`PRECISION`** (here `1e12`) is a fixed scaling factor. Solidity has no floats; scaling keeps division from wiping out small per-block increments.

---

## Per-user accounting (`amount`, `rewardDebt`)

- **`amount`**: principal staked (in staking token units).
- **`rewardDebt`**: not “money owed,” but a **checkpoint** in index space:  
  `rewardDebt = amount × accRewardPerToken / PRECISION` **after** each successful settle + stake update.

This is the same idea as **MasterChef-style** staking: constant-time updates for any number of users.

---

## Funding vs accounting (why `totalRewardsFunded` / `totalRewardsPaid`)

The emission math says *how much users ought to earn*. The contract also tracks **liquidity actually reserved for rewards**:

- **`fundRewards`**: owner pulls reward tokens in and increases `totalRewardsFunded`.
- **`_harvest`**: when paying pending rewards, increases `totalRewardsPaid` and transfers reward tokens out.

Payouts are bounded by an internal **available reward** notion so the contract does not promise more than it should relative to balance and funding (and when staking token equals reward token, **staked principal is not treated as spendable reward**).

---

## Main functions — theory

**Constructor**  
Fixes the economic parameters: which tokens, emission rate, and the block window. Initializes `lastRewardBlock` to the start of the schedule so the index evolves from a known point.

**`pendingReward` / `getUserPosition`**  
Read-only projections: they **simulate** the same index math `_updatePool` would apply, without changing state, so UIs can show “what you would have if we settled now.”

**`fundRewards`**  
Owner **capitalizes** the reward budget: reward tokens enter the contract and the funded total increases. Without funding (and actual token balance), the math might say users earned something the vault cannot pay.

**`withdrawUnusedRewards`**  
Owner can reclaim **surplus** reward inventory that is still marked as funded but is not needed to honor already-accrued obligations—after refreshing the pool math so the books stay consistent.

**`setOwner` / `setPaused`**  
Governance and circuit breaker: pause stops normal user flows that move stake or claim rewards; emergency exit remains a separate design choice in this contract.

**`deposit` / `depositFor`**  
The three-step pattern: **(1)** advance global index, **(2)** pay the beneficiary anything already earned at the old stake, **(3)** change stake, **(4)** set `rewardDebt` to the new baseline. `depositFor` is the same theory with an explicit beneficiary (e.g. staking on behalf of another address).

**`withdraw`**  
Same settle-then-update pattern, but reduces `amount` and returns staking token principal after harvesting rewards.

**`claim`**  
Settles rewards without changing stake: update pool, pay pending, refresh `rewardDebt`.

**`emergencyWithdraw`**  
Returns staked principal **without** going through the reward settlement path: a safety valve when users prefer exit over waiting on reward mechanics (they forgo pending rewards by design).

---

## Quick mental model

1. **Time → global index** (`accRewardPerToken`).  
2. **Stake → personal checkpoint** (`rewardDebt`).  
3. **Difference → pending rewards.**  
4. **Funding → solvent payouts** in real ERC-20 balances.

That separation—**schedule + index + checkpoint + funding**—is the core theory of this project.
