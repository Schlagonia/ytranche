# ytranche

ytranche is a generic Tranche layer for a Yearn V3 vault.

The system lets multiple ERC-4626 Tranche strategies share one underlying
Yearn V3 vault while the `TrancheController` keeps the economic accounting:
priority order, target accrual, profit sharing, losses, reserve support, and
solvency.

A/B/E is just the current test configuration. The contracts do not hard-code
senior, junior, or equity Tranches. A Tranche is a registered strategy address
with a priority, a target rate, and an excess-profit share.

## System Shape

```
users
  |
  v
TrancheStrategy / LockedTrancheStrategy
  |
  v
TrancheController  <---- optional same-asset 4626 reserve
  |
  v
Yearn V3 main vault
```

Supporting contracts:

- `Hook`: rate limits, deposit caps, main-vault deposit gating, and withdrawal caps.
- `Authorizer`: shared role authority for controller, hook, and emergency flows.
- `EmergencyAdmin`: centralized pause, shutdown, emergency withdraw, and max-debt-zero actions.

## TrancheController

`TrancheController` is the source of truth for Tranche economics.

Each registered Tranche has:

- `priority`: senior first, junior last.
- `targetRatePerSecondWad`: the Tranche's target accrual rate.
- `excessShareBps`: share of profit left after targets.
- `baselineAssets`: principal plus realized target and realized excess.
- `pendingExcess`: profit assigned at settlement but not yet realized into the strategy.
- `frozen`: pauses target accrual after a loss until management or a profitable settle unfreezes it.

Governance registers Tranches in priority order with `registerTranche` or
inserts one with `registerTrancheAt`. There is no removal path. To wind down a
Tranche, set its target and excess share to zero and let holders exit.

## Tranche Strategies

Tranche strategies are the user-facing ERC-4626 vaults.

`TrancheStrategy` is the base strategy. Deposits are atomic. Withdrawals are
atomic when the hook and main vault allow liquidity. The strategy does not own
the waterfall math. It asks the controller for `liveAssets()` and routes assets
through `depositFromTranche()` and `withdrawFromTranche()`.

`LockedTrancheStrategy` adds a withdrawal cooldown. Deposits stay atomic, but
users must call `startCooldown(shares)` before redeeming. The cooldown record is
one bucket per user and can be cancelled or overwritten. Cooled shares remain
economically active while they wait.

Both strategies use the hook for deposit and withdrawal caps, and both realize
controller-assigned `pendingExcess` during `report()` so profit unlocks through
the normal Yearn strategy accounting instead of jumping instantly into NAV.

## Settlement

`settle()` is keeper-called. It is the only place the Tranche waterfall moves.

Settlement does this:

1. Accrues every Tranche target into `baselineAssets`.
2. Compares main-vault assets against total Tranche claims.
3. If profitable, assigns excess profit by `excessShareBps` into `pendingExcess`.
4. If losing, draws the reserve first, then applies losses junior-to-senior.

Losses hit `pendingExcess` before `baselineAssets`. Any Tranche that absorbs a
loss is frozen. A strictly profitable settle unfreezes frozen Tranches.

The reserve is optional. It must be a same-asset ERC-4626 vault when set. It is
a settlement backstop, not a redemption source.

## Hook

`Hook` is policy plumbing, not economics.

It is wired into the Yearn V3 main vault as deposit and withdrawal hook, and it
is also called by each Tranche strategy.

It controls:

- Aggregate deposit limits per Tranche and for the main vault.
- Rolling deposit and withdrawal rate limits.
- Main-vault direct-deposit gating through `open` and `allowed`.
- Withdrawal caps based on main-vault deliverable assets.

Deposits and withdrawals are not blocked just because `controller.isSolvent()`
is false. Withdrawals are still bounded by hook rate limits and main-vault
deliverable liquidity.

Tranche-level user gating lives on each Tranche strategy through the inherited
Yearn `BaseHealthCheck` surface. Main-vault direct deposit gating lives on
`Hook`.

## Authorizer

`Authorizer` is the shared access-control contract.

Roles:

- `GOVERNANCE_ROLE`: runtime superuser for `isAuthorized()` checks.
- `DEFAULT_ADMIN_ROLE`: role membership and role-admin root.
- `MANAGEMENT_ROLE`: operational config and keeper/emergency administration.
- `KEEPER_ROLE`: settlement.
- `EMERGENCY_ROLE`: emergency actions.

Governance and default admin start as the same address at init, but they move
through separate two-step handoffs and may diverge. Governance does not get
`MANAGEMENT_ROLE` by default. Management is passed separately at construction.

`setRoleAdmin(role, adminRole)` lets the default admin update non-core role
admin relationships. Core handoff roles are locked.

## Emergency Admin

`EmergencyAdmin` is a small pass-through for halt actions:

- pause a vault or strategy,
- shut down a vault,
- shut down a strategy,
- call strategy `emergencyWithdraw`,
- set a vault strategy's max debt to zero.

The contract must hold the needed Yearn vault roles for those actions to land.

## Current Test Configuration

The tests use three Tranches to exercise the generic system:

| Name | Strategy | Target | Excess share | Liquidity |
| ---- | -------- | ------ | ------------ | --------- |
| A | `TrancheStrategy` | 4.25% | 0% | atomic withdrawals |
| B | `LockedTrancheStrategy` | 4.25% | 40% | cooldown withdrawals |
| E | `LockedTrancheStrategy` | 0% | 60% | cooldown withdrawals |

That setup is a configuration, not a protocol limit. More Tranches can be added
or inserted as long as total excess share stays under `10_000` bps.

## Build And Test

```bash
forge build
forge test
make test
```

Current root suite:

- 86 passing
- 1 skipped Spark fork sanity test

Tests cover controller settlement, reserve behavior, Tranche deposits and
withdrawals, cooldowns, hook limits and gating, emergency actions, role
handoffs, insertion/deprecation, and loss/profit waterfall behavior.
