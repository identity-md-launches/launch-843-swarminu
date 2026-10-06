# SwarmInu (SI)

A fixed-supply ERC-20 with a 2% transfer fee paid to a fixed wallet, built to launch through the IdentityMD
`ProjectFactory.launchCustom` path into a single-sided Uniswap v4 pool against IMD.

| | |
|---|---|
| Contract | `src/SwarmInu.sol` |
| Name / symbol | `SwarmInu` / `SI` |
| Decimals | 18 |
| Supply | 1,000,000,000 SI (`1000000000000000000000000000` minor units), minted once in the constructor to the deployer |
| Fee | 2% (`FEE_BPS = 200`) of every ordinary transfer |
| Fee recipient | `0x66522f25035C3FAFd2c6D950a506FDa457E06344` (constant, cannot be changed) |
| Compiler | solc 0.8.26, EVM `cancun`, optimizer 200 runs, `bytecode_hash = "none"` |

## What the token does

- **Supply.** The constructor mints the whole supply to `msg.sender` (the factory in a launch). There is no mint
  function, no burn function, and nothing else that changes `totalSupply`.
- **Fee.** On an ordinary `transfer` or `transferFrom` of `value`, the sender is debited exactly `value`,
  `value * 200 / 10000` (rounded down) is credited to the fee recipient, and the rest to the recipient. Two `Transfer`
  events are emitted: sender → fee recipient, sender → recipient. `transferFrom` spends the full `value` of allowance.
- **Rounding.** The fee rounds down, so a transfer of fewer than 50 minor units (5e-17 SI) pays nothing.
- **No administration.** No owner, pause, blacklist, freeze, seize, fee setter, exemption setter, proxy or upgrade.
  The fee rate, the fee recipient and the exemptions are fixed at deployment. "Owner" in the brief is read as the
  wallet that receives the fee; it has no power over the token or over anyone's balance.

### Transfers that pay no fee

The launch has flows that must move exactly the amount stated, or the launch is refused. These skip the fee:

| Exempt | Rule | Why |
|---|---|---|
| The factory | caller, sender or recipient is `factory` | funds the distributor, seeds the pool, forwards the remainder |
| The Uniswap v4 PoolManager | recipient is `poolManager` | v4 credits an incoming payment by balance difference; a short payment can leave the swap unsettled |
| The launch's MerkleDistributor | sender or recipient is `factory.distributorOf(launchNumber)`, read at transfer time | claims must arrive whole |
| The fee recipient | sender or recipient is `FEE_RECIPIENT` | paying itself would only emit a second event |

`isFeeExempt(operator, from, to)` and `distributor()` expose the same decision the transfer makes.

The distributor read is a `staticcall` capped at 100,000 gas that copies one word of return data. If the factory has
no code, reverts, runs out of gas, or answers with anything but a clean address, the token treats the launch as having
no distributor and charges the fee as usual. The factory can therefore never make a transfer revert; the worst a
misbehaving factory can do is add up to 100,000 gas to a transfer or choose which single address gets the
distributor's exemption.

### PoolManager payouts and fee limits — read this before launch

**SI payouts from the PoolManager pay 2%; incoming SI payments are exempt.** This covers buys, liquidity withdrawals,
flash-accounting relays and ERC-6909 claim redemptions, unless another exemption in the table applies. The manager is
debited the full payout: the recipient gets `amount - feeOn(amount)` and the fee wallet gets `feeOn(amount)`.
Direct sells and seeding still credit the PoolManager in full, so its balance-difference settlement succeeds.

Consequences for integrations:

1. A v4 swap delta or quote describes gross SI output. The buyer receives 2% less, rounded as above. Integrations must
   check the final recipient's balance increase for minimum-output protection, including for exact-output swaps.
   The tests exercise direct settlement against the real PoolManager; they do not certify a production router.
2. A router that takes SI to itself and then forwards to a wallet incurs two token fees: 100 SI gross becomes 98 SI
   at the router and 96.04 SI at the wallet. Taking directly to the final recipient avoids the extra forwarding fee.
   A router that forwards the gross quote instead of its actual balance can revert.
3. Paying SI in and taking it out to another ordinary wallet now pays the fee on withdrawal.
   `test_transferRoutedThroughThePoolManagerPaysTheFee` covers this relay. ERC-6909 claims can still be transferred
   without calling SI; redemption to a non-exempt recipient pays the fee, as tested in `test/SwarmInuClaims.t.sol`.
   The token cannot charge each transfer of a separate claim or wrapper token, or activity entirely inside v4 that
   does not transfer SI.
4. Direct sells into the configured PoolManager pay no token fee. Charging every buy and sell would require a
   separate pool-level mechanism; this token adds no swap hook.

Other things a fee-on-transfer token implies: contracts that assume they receive the amount sent (some vaults, bridges
and staking contracts) will mis-account SI unless they measure the balance they actually received.

## Launch parameters

The token and economics below are what this project supplies for the launch manifest. The manifest itself
(`launch.json`) is written by a separate step.

### Token

| Field | Value |
|---|---|
| `kind` | `custom_token` |
| `token.contract` | `SwarmInu` |
| `token.name` / `token.symbol` | `SwarmInu` / `SI` |
| `token.decimals` | `18` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `token.constructorArgs` | `["$factory", "$poolManager", "$launchNumber"]` — `(address, address, uint64)`, in that order |
| `contracts` | none |

The constructor rejects a zero `factory` or `poolManager`. It does not require the deployer to be `factory`; the
supply goes to whoever deploys.

### Economics, as read from the brief

| Field | Value | Reading |
|---|---|---|
| Paired currency | IMD | "launch it on uniswap v4 … and IMD" |
| `economics.initialMarketCapWei` | `400000000000000000000` | "based on 400 IMD tokens": the whole 1,000,000,000 SI valued at 400 IMD, with IMD at 18 decimals |
| `economics.poolBps` | `9000` | "one sided liquidity … with the full supply": everything the requester has |
| `economics.remainderTo` | the requester's wallet; `0x66522f25035C3FAFd2c6D950a506FDa457E06344` if the fee wallet is the requester's | receives only rounding dust at `poolBps = 9000` |
| IMD added to the pool | none | "don't add tokens of IMD just one side" |

Ten percent of the supply goes to the swarm's MerkleDistributor by the network's construction, before the pool is
seeded. "The full supply" in the pool therefore means the requester's full 90% (900,000,000 SI); it cannot be 100%.

### Opening price and range

At a 400 IMD market cap one SI opens at 0.0000004 IMD (2,500,000 SI per IMD). The pool's `sqrtPriceX96` depends on
which currency sorts first, which is only known once the token's address is:

| Order | Price the pool stores | `sqrtPriceX96` | Tick |
|---|---|---|---|
| SI is `currency0` (SI address < IMD address) | IMD per SI = 4e-7 | `50108289675009586237282760` | −147326 |
| SI is `currency1` (SI address > IMD address) | SI per IMD = 2.5e6 | `125270724187523965593206900784803` | 147325 |

Both values are `floor(sqrt(ratio · 2^192))` and are pinned by `test_openingPriceIsA400ImdMarketCap`.

A single-sided seed is a position whose range lies entirely on the side of the opening price where only SI is owed:

- SI as `currency0`: `tickLower` is the first usable tick strictly above the opening tick, `tickUpper` the maximum
  usable tick.
- SI as `currency1`: `tickLower` is the minimum usable tick, `tickUpper` the last usable tick at or below the opening
  tick.

The tests derive these with `LaunchMath` in `test/utils/LaunchHarness.sol` and seed 900,000,000 SI with zero IMD
against a real PoolManager in both orders. Because the range starts at a usable tick, the first trade executes up to
one tick spacing above the 400 IMD level (at most about 2% for a spacing of 200).

The market cap fixes the opening price only. Buying a large part of the pool costs far more than 360 IMD, because the
price rises along the curve as SI leaves the pool.

### Not decided here

- **IMD's address and decimals.** No `network.json` was provided to this task, so the IMD address is not in this
  repository and its 18 decimals are an assumption. If IMD has other decimals, `initialMarketCapWei` changes.
- **Pool fee and tick spacing.** The brief names neither. The tests use 1% (`10000`) and a spacing of `200` as an
  illustration only.
- **Chain, factory, PoolManager and launch number.** Resolved by the deployer into the constructor arguments.
- **Who holds the seeded liquidity position** and whether it can be withdrawn is the factory's behaviour, not the
  token's.

## Assumptions

1. The fee applies to SI transfers, including PoolManager payouts; direct sells into that manager remain exempt.
2. The fee wallet is fixed forever. If `0x6652…6344` is lost or compromised, fees keep going there; there is no way
   to redirect them.
3. The factory deploys the token itself, so it receives the supply and is the `factory` argument.
4. `distributorOf(uint64)` on the factory returns the launch's distributor, or the zero address before it exists.
5. The PoolManager address given at deployment is the only v4 PoolManager on the chain. A different PoolManager, or a
   v2/v3 pool, gets no exemption: its swaps are taxed, and v2/v3 routers need their fee-on-transfer swap functions.

## Operational responsibilities

- **Requester:** confirm the reading of the economics above and the consequence that v4 payouts pay the token fee
  while direct sells do not; control the key of the fee wallet; confirm the wallet can hold ERC-20s on the launch chain.
- **Network deployer:** resolve `$factory`, `$poolManager`, `$launchNumber`; derive the opening price and range from
  the manifest; verify the source on the chain's explorer. Validate the chosen router's payout routing and minimum-output
  checks against the net amount received before release. This repository contains no deploy script, broadcasts nothing
  and holds no keys.
- **Reviewer:** the tests here are not an audit. The token takes a fee from other people's transfers and should get an
  independent adversarial review before release.

## Trust

- The fee recipient receives 2% of ordinary transfers and has no other power.
- The factory names the distributor live on each applicable transfer. If the factory is upgradeable or its record can
  be changed, whoever controls it can move the distributor's fee exemption to another address. Removing the real
  distributor's exemption makes its subsequent claims pay the fee. The token does not latch or require code at that
  address; the deployer must verify the factory's record management.
- The factory is also exempt as a `transferFrom` operator, so it can move any approved amount to a chosen recipient
  without a fee. It still needs the holder's allowance and cannot move unapproved balances, mint, block transfers or
  change the fee. The deployer must verify the factory's allowance-consuming entry points; the token does not restrict
  who can call them. `test_factoryAsSpenderMovesExactAmounts` and `test_exemptionFollowsTheFactorysCurrentAnswer`
  demonstrate these trust assumptions.
- Nobody can pause the token or freeze, seize or burn a holder's balance.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

No environment variables, network access, `ffi` or filesystem access are used.

- `test/SwarmInu.t.sol` — supply and metadata, the fee on `transfer` and `transferFrom`, rounding, a fuzzed
  conservation check, every exemption, a factory that does not answer (no code, revert, gas burn, short, dirty or
  oversized answer), insufficient balance and allowance, the absence of any administrative function, and a scan of the
  runtime for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.
- `test/SwarmInuLaunch.t.sol` — the launch against a real Uniswap v4 `PoolManager` with the IMD stand-in sorted on
  either side: the swarm's share and a claim arrive whole, the pool opens at the 400 IMD price, 90% of the supply seeds
  it with no IMD, a trader receives the buy net of the fee and sells its entire balance, bought tokens pay another fee
  when forwarded, and relaying through the PoolManager pays the fee; and the failures: a range that would need IMD,
  a seed larger than the factory's balance, selling more than held, buying with no IMD.
- `test/SwarmInuClaims.t.sol` — a real PoolManager with no pool: SI is wrapped into ERC-6909 claims, claims change hands,
  redemption pays the fee, and excessive or repeated redemptions revert without moving SI.
- `test/utils/` — mocks of the factory, a plain pair token, a trader, and the launch arithmetic. Test scaffolding only;
  the real factory, distributor and pool hook are the network's and are not reproduced here.

Slither, Mythril and long fuzz campaigns were not run.

## Dependencies

Vendored as plain files under `lib/`, trimmed to what the build needs:

| Library | Version | Used by |
|---|---|---|
| OpenZeppelin Contracts | v5.4.0 (`c64a1edb`), `ERC20` and its imports only | `src/SwarmInu.sol` |
| forge-std | v1.9.7 (`77041d2c`) | tests |
| Uniswap v4-core | commit `46c68346`, `src/` without `src/test/` | tests |
| solmate | commit `89365b88`, `auth/Owned.sol` only | v4-core's `ProtocolFees` |

v4-core's `PoolManager` is under the Business Source License (see `lib/v4-core/licenses/`). It is compiled here only
to test against and is not part of the deployed token.
