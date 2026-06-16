# ytranche — A/B/E tranche system on top of Yearn V3

A small, opinionated structured-vault product layered on a Yearn V3
multi-strategy vault. Economically-symmetric tranches plus an optional 4626
reserve buffer:

| Tranche / bucket | Contract                  | Role                 | Liquidity                                  | Default target / excess               |
|------------------|---------------------------|----------------------|--------------------------------------------|---------------------------------------|
| **A — Senior**   | `TrancheStrategy`         | safer, predictable   | atomic deposit & withdraw                  | **4.25 %/yr** target, **0 %** excess  |
| **B — Junior**   | `LockedTrancheStrategy`   | levered upside       | deposit atomic, 14 d cooldown + 7 d window | **4.25 %/yr** target, **40 %** excess |
| **E — Equity**   | `LockedTrancheStrategy`   | first-loss / promote | deposit atomic, 14 d cooldown + 7 d window | **0 %** target, **60 %** excess       |
| **Reserve**      | any same-asset 4626 vault | settlement first-loss buffer | governance-funded (e.g. sUSDS / yvUSDC) | n/a                              |

Tranches are **symmetric** — one `Tranche` struct, one code path. They differ
only in:

1. **target rate** (annualised BPS → continuous simple-interest accrual),
2. **excess-share** (BPS of post-target profit; Σ across tranches ≤ MAX_BPS),
3. **position** in the priority list — index `0` is most senior. New tranches
   can be inserted anywhere (`registerTrancheAt`); to retire one, zero its
   target + excess (it then stops earning but stays in the waterfall to wind
   down). There is no removal.

The reserve is **optional** (settable, may be `address(0)`), lives in a
same-asset 4626 vault, earns that vault's yield, and absorbs loss **first** at
settlement. It is **not** a redemption source.

---

## Architecture

```
                         ┌───────────────────────────────────┐
                         │              Authorizer            │  OZ AccessControlEnumerable
                         │  GOVERNANCE superuser +             │  every privileged call on
                         │  MANAGEMENT → {EMERGENCY, KEEPER}   │  Hook + Controller delegates here
                         └─────────────────┬─────────────────┘
                                           │ access control
 ┌────────────────┐ ┌────────────────┐ ┌──┴─────────────┐   ┌──────────────────────────┐
 │ TrancheStrat A │ │ Locked B       │ │ Locked E       │   │            Hook           │
 │   (atomic)     │ │ (cooldown+win) │ │ (cooldown+win) │   │ rate-limits /             │
 └───────┬────────┘ └───────┬────────┘ └───────┬────────┘   │ allow-list + vault hooks  │
         │ deposit/withdraw │                  │            └─────────────┬────────────┘
         ▼                  ▼                  ▼     depositCap/withdrawCap + consume
               ┌───────────────────────────────────────────┐             │
               │               TrancheController            │◀────────────┘
               │  • Tranche[] (target + excess + freeze)     │
               │  • settle() — accrue, then loss/profit      │
               │  • routes underlying into the main vault    │
               └──────────┬───────────────────────┬─────────┘
                          │                        │
                ┌─────────▼──────────┐  ┌──────────▼────────────────┐
                │ Yearn V3 risky     │  │ reserve 4626 (optional)   │
                │ multi-strat vault  │  │ • settlement first-loss   │
                │ deposit/withdraw   │  │ • earns underlying yield  │
                │   hook = Hook      │  └───────────────────────────┘
                └────────────────────┘
```

### Contract set

| File | Purpose |
|------|---------|
| `lib/tokenized-strategy` | Upstream Yearn tokenized-strategy branch `constant_accual`. Tests etch its `TokenizedStrategy` bytecode at the fixed implementation address. |
| `lib/yearn-vaults-v3` | Upstream Yearn V3 vault branch `310`. Tests deploy the Vyper `VaultV3`, `VaultFactory`, and a real vault via `VyperDeployer`. |
| `lib/tokenized-strategy-periphery/src/utils/{Authorizer,EmergencyAdmin}.sol` | Reusable shared role authority and Yearn emergency pass-throughs. |
| `src/Authorizer.sol` | Shared access control (OZ `AccessControlEnumerable`). Constructor takes separate governance and management addresses; governance is the superuser but does not hold `MANAGEMENT_ROLE`; management administers keeper/emergency; governance moves through the pending-governance role handoff. |
| `src/utils/Authorized.sol` | Base for Hook + Controller: holds the immutable `AUTHORIZER` and role-check modifiers that delegate to it. |
| `src/EmergencyAdmin.sol` | Emergency pass-through for vault/strategy pause, shutdown, emergency withdraw, and setting a vault strategy's max debt to zero. |
| `src/Hook.sol` | Rolling rate limits, aggregate deposit ceilings, and main-vault allow-list. Wired as the vault's `deposit_hook` / `withdraw_hook`. Returns *actual asset caps* via `depositCap`/`withdrawCap` (strategies `min` them with their own limits) and meters usage through the shared hook surface. |
| `src/TrancheController.sol` | Source of truth for all tranche economics (per-tranche target + excess + frozen + baseline; settlement waterfall). Hook-agnostic — tranches reference the Hook, not the controller. Reserve vault is optional and settable. |
| `src/TrancheStrategy.sol` | Base tranche strategy — atomic deposits & redemptions (tranche A). Immutable `CONTROLLER`, settable `hook`. |
| `src/LockedTrancheStrategy.sol` | `TrancheStrategy` + cooldown layer: per-user `(cooldownEnd, windowEnd, shares)`; `startCooldown` overwrites, `cancelCooldown` clears; redemption valid only in `[cooldownEnd, cooldownEnd + window]`. Used for B and E. |

Test mocks (`src/test/mocks/`): `MockERC20`, `MockStrategy` (behind the real
Yearn V3 vault for simulated PnL / withdraw-limit checks), `MockReserveVault`
(sync-redeemable same-asset 4626).

---

## Access control

Every privileged function delegates to the `Authorizer`:

- **GOVERNANCE** — superuser for anything. Structural/economic config: register tranches,
  set target/excess rates, set the reserve vault, sweep the reserve. Handed
  off through the pending-governance role handoff.
- **MANAGEMENT** — limits, allow-list, rate-limit window, `unfreeze`, and
  administration of keeper/emergency membership.
- **EMERGENCY** — halt actions through `EmergencyAdmin`: pause/shutdown,
  strategy `emergencyWithdraw`, and zeroing a vault strategy's max debt.
- **KEEPER** — `settle()`.

`onlyTranche` (registered-tranche identity) gates the strategy↔controller and
strategy↔hook routing calls and is separate from the role system.

---

## Settlement flow

Keeper-driven, on the standard Yearn report cadence:

```
keeper.run() {
    for s in riskyStrategies: s.report()              # _harvestAndReport
    for s in riskyStrategies: mainVault.process_report(s)
    controller.settle()                               # the waterfall
    aTranche.report(); bTranche.report(); eTranche.report()  # pick up new NAV + realize excess
}
```

`controller.settle()` is the single place economics happen:

```
1. accrue every tranche:  baseline += baseline * targetRate * dt
2. totalClaim = Σ (baseline + pendingExcess)          # see totalClaims()
3. pnl = vaultAssets() - totalClaim

if pnl < 0 (loss):
    a) reserve absorbs first (drawn into the main vault)
    b) then tranches junior → senior, each from its total claim:
       pendingExcess first, then baseline.
       ANY loss (pending or baseline) freezes the tranche and emits
       TrancheLoss(tranche, amount). pendingExcess is part of the claim, so
       the loss order is constant whether or not excess has been realized.

else (profit):
    for each tranche: pendingExcess += pnl * excessShareBps / MAX_BPS
    # stays out of live NAV until the tranche calls realizeExcess() in report();
    # a strictly profitable settle also unfreezes any frozen tranche.
    # any remainder (Σ excessShareBps < MAX_BPS) stays in the main vault.
```

**Safe-note property:** the senior tranche is haircut last (reserve, then every
more-junior tranche, are exhausted first) — enforced purely by priority order.

---

## Accrual model

Each tranche carries `baselineAssets` (principal + realized target + realized
excess), `targetRatePerSecondWad`, `lastAccrual`, `excessShareBps`, `frozen`,
and `pendingExcess`. Live NAV is computed on the fly and published via
`liveAssets(tranche)` — the value the strategy's `totalAssets` surfaces, so the
4626 path prices deposits/redemptions at the live post-target PPS:

```
liveAssets = baselineAssets * (1 + targetRate * (now − lastAccrual))   # 0 if frozen
```

State-changing flows roll `baselineAssets` forward then apply: deposit `+= amt`,
withdraw `-= amt` (capped to the baseline), cooldown start (B/E) leaves the
baseline unchanged, settlement updates it via the waterfall. `frozen` pauses
target accrual after any loss; a profitable settle clears it.

---

## Reserve

Protocol-owned in v1. `fundReserve(amount)` deposits underlying into the 4626
reserve vault (open, but funded by governance in practice). The reserve:

- absorbs loss **first** at settlement (`_drawReserveToMain`),
- counts toward `isSolvent()` while target interest accrues ahead of realized
  vault yield,
- is **never** a redemption source — tranche withdraw limits are capped at the
  main vault's deliverable (`vaultMaxWithdraw`), so redemptions are sourced
  entirely from the main vault.

`setReserveVault(addr)` swaps (or clears, with `address(0)`) the reserve;
the previous vault must be emptied first via `withdrawReserve`, which transfers
the 4626 **shares** out (not the underlying).

---

## Hook / limits

The Hook is consulted two ways: by the tranche strategies via
`depositCap`/`withdrawCap` (checked in `availableDepositLimit`/`...Withdraw...`)
plus `consumeDeposit`/`consumeWithdraw` (metered by the tranche in
`_deployFunds`/`_freeFunds`); and directly by the Yearn vault as
`deposit_hook`/`withdraw_hook` (`available_*_limit`, `post_*`).

| Setting | Effect |
|---------|--------|
| `depositLimits[target]` | Aggregate deposit ceiling for a tranche, or the main vault via `address(VAULT)` |
| `setDepositRateLimit` / `setWithdrawRateLimit` + `rateLimitWindow` | Per-window rolling rate limits |
| `setOpen(vault, bool)` + `allowed[vault][addr]` | Per-vault deposit gate |
| `!controller.isSolvent()` | Blocks tranche withdrawals through `withdrawCap`; deposits remain allowed |

Vaults are **gated by default**: a vault admits a depositor only if it is
`open` or the depositor is in its `allowed` set. This is **per-vault** (each
tranche, and the main vault keyed by `address(VAULT)`) and applies to
**deposits** only — withdrawals are never gated, so holders can always exit.
The controller's own tranche-routed main-vault deposits are always permitted
(end users are gated at the tranche). Withdraw limits are capped at the main
vault's loss-allowing deliverable, and any loss a `redeem` realizes is passed
through to the exiting holder.

---

## Build / test

```bash
forge build        # compile
forge test         # 82 passing, 1 skipped (Spark fork sanity check)
make test          # same
make trace         # verbose
```

Tests use Vyper FFI to compile/deploy the Yearn V3 vault branch locally
(Vyper `0.3.10`). Coverage: A/B deposit-withdraw + cooldown; reserve funding,
migration, and clear-to-zero; Hook rate-limits/allow-list; EmergencyAdmin
pause/shutdown/emergency-withdraw/max-debt-zero paths; full Authorizer role
matrix + governance handoff; the loss waterfall (reserve → junior → senior, freeze +
`TrancheLoss`) and profit waterfall; redeem-loss passthrough; positional
tranche insertion + deprecation; and golden illustration numbers.

---

## Production deployment

```bash
# 0) Deploy/locate the Yearn V3 VaultV3 + VaultFactory and a vault for `asset`.
#    Note it as MAIN_VAULT; have a same-asset 4626 ready as RESERVE_VAULT.

# 1) One-shot deploy: Authorizer → Controller → Hook → tranches; the script also
#    sets the reserve vault (broadcaster must be GOV).
ASSET=0x.. MAIN_VAULT=0x.. RESERVE_VAULT=0x.. GOV=0x.. MANAGEMENT=0x.. KEEPER=0x.. \
  forge script script/Deploy.s.sol --broadcast --rpc-url $RPC

# 2) Operator follow-ups on the main vault (printed by the script):
authorizer.grantRole(KEEPER_ROLE, keeper) # from MANAGEMENT
mainVault.add_strategy(liquidParking); mainVault.update_max_debt_for_strategy(...)
mainVault.set_default_queue([liquidParking, ...risky]); mainVault.set_auto_allocate(true)
mainVault.set_minimum_total_idle(0); mainVault.set_deposit_limit(<cap>)
mainVault.set_deposit_hook(Hook); mainVault.set_withdraw_hook(Hook)
```

---

## Notes / tradeoffs

- **Per-second rounding.** Linear simple-interest with integer division rounds
  down a few wei per million units/year; tests tolerate ~1e15 dust.
- **PPS is approximate around unreported PnL.** Between settlements tranches
  price off the last settled baseline; the risky strategies' `profitMaxUnlockTime`
  plus the 14-day B/E cooldown bound the manipulation window.
- **Reserve is settlement-only**, so size the liquid-parking strategy to cover
  expected redemption flow; a deficit redemption realizes the loss to the
  exiting holder rather than tapping the reserve.
- **Cooldown is single-bucket per user** — calling `startCooldown` again resets
  the whole pending amount's maturity; use distinct addresses for separate
  schedules.
- **No external equity depositors in v1.** Promote economics assume a single
  (protocol) equity holder; external equity is a v2 design.
