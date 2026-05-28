# vault-steth-adapter

**Standard-Spoke-only stVault collateral for AAVE v4, with formally-verified invariant: a healthy stVault is never drained.**

Borrowers can pledge mint capacity from their per-borrower Lido stVault, receive a freely-transferable ERC-20 (`vaultStETH`), supply it as collateral on AAVE Main Spoke, and borrow stablecoins against it. At liquidation, a liquidator receives `vaultStETH` via standard AAVE liquidation logic and atomically redeems it for real wstETH from the borrower's specific vault in the same transaction.

**Key properties:**
- **Zero custom AAVE Spokes.** A single asset-listing AIP is the entire AAVE governance ask. The custom logic lives entirely on our side (one ERC-20, one Adapter, one PledgeGuard pattern, one atomic Factory) and uses standard `IDashboard.mintShares` against real Lido vaults.
- **Healthy stVault never drained.** External redemption is gated by on-chain AAVE `healthFactor` reads. A redemption against a borrower's vault requires either (a) the borrower's HF < 1e18 on AAVE Main Spoke, OR (b) the borrower's explicit voluntary-close opt-in, OR (c) the caller IS the borrower. This invariant is formally verified by Halmos symbolic execution against the Adapter's full external surface — 12/12 checks pass, covering every reachable calldata combination.

See [`docs/ADR.md`](docs/ADR.md) for the architecture decision (including the rejected alternatives) and [`docs/Implementation-Plan.md`](docs/Implementation-Plan.md) for the build plan.

## Architecture in one diagram

```text
       Borrower ──fund ETH──▶ Lido stVault (real, per-borrower Dashboard)
                                    │
                                    │ MINT_ROLE  → Adapter
                                    │ DEFAULT_ADMIN_ROLE → PledgeGuard (locks roles)
                                    ▼
       Borrower ─pledge(shares)──▶ Adapter ──mint──▶ vaultStETH (freely transferable ERC-20)
                                                                │
                                                                │ supply as collateral
                                                                ▼
                                                       AAVE Main Spoke
                                                       (standard listing,
                                                        no custom code)

  Liquidation (atomic, one block):
      Liquidator ─liquidationCall─▶ AAVE Main Spoke ──vaultStETH─▶ Liquidator
      Liquidator ─redeem──────────▶ Adapter ──Lido.mintShares──▶ Borrower's stVault ──wstETH──▶ recipient
```

## Contracts

| Contract | Purpose |
| --- | --- |
| [`src/VaultStETH.sol`](src/VaultStETH.sol) | Freely-transferable ERC-20. Mint and burn restricted to the Adapter; everything else is standard ERC-20. |
| [`src/Adapter.sol`](src/Adapter.sol) | Issues `vaultStETH` against pledged Lido stVaults. On `redeem`, drains ONLY a marked dashboard whose borrower has HF < 1e18 on AAVE (liquidation queue, re-verified at selection time) OR who explicitly opted in via `markForVoluntaryClose`. `selfRedeem` lets a borrower drain their OWN vault bypassing the queue. `cleanupLiquidationQueue` is permissionless and persists demotion of recovered borrowers. |
| [`src/PledgeGuard.sol`](src/PledgeGuard.sol) | Per-borrower wrapper that holds Dashboard admin + pledge-affecting roles. Borrower retains only safe direct-use roles. Blocks validator exit, voluntary disconnect, and dashboard ownership transfer. |
| [`src/StVaultFactory.sol`](src/StVaultFactory.sol) | Atomic deployment: real Lido `createVaultWithDashboard`, fresh `PledgeGuard`, full role-graph wiring, `Adapter.registerDashboard`. One transaction, no half-state. |
| [`src/interfaces/IAavePool.sol`](src/interfaces/IAavePool.sol) | Minimal interface to AAVE v4 Main Spoke / v3 Pool for `getUserAccountData` healthFactor reads. |
| [`src/Addresses.sol`](src/Addresses.sol) | Verified mainnet addresses for Lido V3 + AAVE v4 / v3. |

## Build & test

Requirements: Foundry (`forge`), `solc 0.8.25` (installed automatically). For fork tests, an Ethereum mainnet RPC. For Halmos symbolic tests, `pip install halmos`.

```bash
# Build
forge build

# Unit tests (no fork)
forge test --match-path 'test/VaultStETH.t.sol'

# Full forge suite (mainnet fork — needs RPC)
export MAINNET_RPC_URL=https://your-rpc-url
forge test --no-match-path 'test/HalmosInvariants.t.sol'

# Halmos symbolic verification (no fork; uses deployed mocks)
halmos --contract HalmosInvariantsTest --no-status
```

A public RPC (`https://ethereum-rpc.publicnode.com`) is used as a fallback if `MAINNET_RPC_URL` is not set.

## Test coverage

All test files; every fork test exercises real Lido V3 contracts on a mainnet fork. **No `vm.mockCall`.** Halmos symbolic tests use deployed (real-contract) mocks for Lido Dashboard / stETH / wstETH, since Halmos cannot fork. Test count and coverage:

| File | Tests | Type | Highlights |
| --- | --- | --- | --- |
| [`test/VaultStETH.t.sol`](test/VaultStETH.t.sol) | 13 | unit | Adapter-only mint/burn; freely-transferable semantics; ERC-20 standard behaviors; fuzz roundtrip |
| [`test/Factory.t.sol`](test/Factory.t.sol) | 7 | fork | Atomic deployment; full Dashboard role graph; multiple borrowers; revert paths |
| [`test/PledgeGuard.t.sol`](test/PledgeGuard.t.sol) | 14 | fork | Withdraw bounded by `withdrawableValue`; pledge-undermining actions blocked; Ownable2Step |
| [`test/Adapter.t.sol`](test/Adapter.t.sol) | 21 | fork | Pledge/unpledge; redeem against marked vault; queue priority; HF boundary behavior |
| [`test/Liquidation.t.sol`](test/Liquidation.t.sol) | 5 | fork | End-to-end: pledge → mark → seize → redeem → real wstETH; atomic same-block; partial liquidation |
| [`test/HFGating.t.sol`](test/HFGating.t.sol) | 9 | fork | The core invariant: healthy borrowers never drained even when others are liquidating, even with attackers, even after recovery+relapse |
| [`test/SelfRedeem.t.sol`](test/SelfRedeem.t.sol) | 10 | fork | Borrower-only drain of own vault; revert paths for non-borrowers |
| [`test/HalmosInvariants.t.sol`](test/HalmosInvariants.t.sol) | **12 symbolic** | **formal verification** | Halmos proofs over the Adapter's full external surface — see "Formal verification" below |
| **Total** | **79 forge + 12 halmos** | | All passing |

Full forge suite runs in ~17 seconds on a typical RPC. Halmos suite runs in ~5 seconds.

## Formal verification (Halmos)

The production invariant — **"a healthy stVault is never drained by an external call"** — is formally proven by Halmos symbolic execution in [`test/HalmosInvariants.t.sol`](test/HalmosInvariants.t.sol).

The key check, `check_HealthyAliceNeverDrainedByExternalCall`, uses `svm.createCalldata("Adapter")` to generate symbolic calldata covering every non-view function on the Adapter with every possible parameter combination. Halmos explores all 68 reachable execution paths and proves the invariant holds against every one.

### Running the proof

```bash
halmos --contract HalmosInvariantsTest --no-status
```

### What's proven

```
[PASS] check_HealthyAliceNeverDrainedByExternalCall(address)         (68 paths)
[PASS] check_HealthyAliceUntouchedEvenWhenBobLiquidating(address)    (78 paths)
[PASS] check_HealthyAliceUntouchedEvenWhenBobVoluntary(address)      (77 paths)
[PASS] check_redeem_NeverDrainsHealthyDashboard(address,uint256,address)
[PASS] check_markForLiquidation_RejectsHealthy(address)
[PASS] check_markForLiquidation_BoundaryStrict(address,uint256)
[PASS] check_unpledge_OnlyBorrower(address,uint256)
[PASS] check_selfRedeem_OnlyBorrower(address,uint256,address)
[PASS] check_markForVoluntaryClose_OnlyBorrower(address)
[PASS] check_registerDashboard_OnlyFactory(address,address,address)
[PASS] check_NegativeControl_AliceCanDrainOwnVaultViaSelfRedeem(uint256)
[PASS] check_NegativeControl_BobLiquidatableCanBeDrainedByAnyone(address,address)
12 passed; 0 failed
```

### The invariant, formally

For any reachable state of the Adapter, and for any single external call `f(args)` initiated by `msg.sender = caller`:

> If `caller != pledges[d].borrower` AND `AAVE.healthFactor(pledges[d].borrower) >= 1e18`, then `pledges[d].pledgedShares` cannot decrease.

This is the production safety property. The two negative-control tests verify the invariant does NOT over-constrain — Alice CAN drain her own vault via `selfRedeem`, and Bob (unhealthy + marked) CAN be drained by liquidators. Liquidation still works.

## What's intentionally not built here

- A vaultStETH price-feed adapter for AAVE Main Spoke — that's separate work (the AIP will provision one).
- An off-chain liquidator bot — vaultStETH is freely transferable, so standard AAVE liquidator infrastructure suffices. An optional redemption-priority coordinator (off-chain) can call `markForLiquidation` more reliably than monitoring AAVE events; not required for correctness.
- A fixed-rate / IRS-hedge layer (Aegis-style) — a future Layer-3 product that sits on top of this design without further AAVE governance.

## Documentation

- [`docs/ADR.md`](docs/ADR.md) — Architecture Decision Record.
- [`docs/Implementation-Plan.md`](docs/Implementation-Plan.md) — phased build plan.
- [`../Aegis×Babylon_liquidation-5.md`](../Aegis%C3%97Babylon_liquidation-5.md) — the design narrative that landed this architecture.
- Earlier docs in the same series ([`-1`](../Aegis%C3%97Babylon_liquidation.md) through [`-4`](../Aegis%C3%97Babylon_liquidation-4.md)) walk the evolution of the design and the rejected alternatives.
