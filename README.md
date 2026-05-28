# vault-steth-adapter

**Standard-Spoke-only stVault collateral for AAVE v4.**

Borrowers can pledge mint capacity from their per-borrower Lido stVault, receive a freely-transferable ERC-20 (`vaultStETH`), supply it as collateral on AAVE Main Spoke, and borrow stablecoins against it. At liquidation, a liquidator receives `vaultStETH` via standard AAVE liquidation logic and atomically redeems it for real wstETH from the borrower's specific vault in the same transaction.

**Key property:** zero custom AAVE Spokes. A single asset-listing AIP is the entire AAVE governance ask. The custom logic lives entirely on our side (one ERC-20, one Adapter, one PledgeGuard pattern, one atomic Factory) and uses standard `IDashboard.mintShares` against real Lido vaults.

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
| [`src/Adapter.sol`](src/Adapter.sol) | Issues `vaultStETH` against pledged Lido stVaults. On `redeem`, burns `vaultStETH` and mints real wstETH from a pledged vault picked by a priority queue (liquidation → voluntary close → FIFO). |
| [`src/PledgeGuard.sol`](src/PledgeGuard.sol) | Per-borrower wrapper that holds Dashboard admin + pledge-affecting roles. Borrower retains only safe direct-use roles. Blocks validator exit, voluntary disconnect, and dashboard ownership transfer. |
| [`src/StVaultFactory.sol`](src/StVaultFactory.sol) | Atomic deployment: real Lido `createVaultWithDashboard`, fresh `PledgeGuard`, full role-graph wiring, `Adapter.registerDashboard`. One transaction, no half-state. |
| [`src/Addresses.sol`](src/Addresses.sol) | Verified mainnet addresses for Lido V3 + AAVE v4. |

## Build & test

Requirements: Foundry (`forge`), `solc 0.8.25` (installed automatically). For fork tests, an Ethereum mainnet RPC.

```bash
# Build
forge build

# Unit tests (no fork)
forge test --match-path 'test/VaultStETH.t.sol'

# Full suite (mainnet fork — needs RPC)
export MAINNET_RPC_URL=https://your-rpc-url
forge test
```

A public RPC (`https://ethereum-rpc.publicnode.com`) is used as a fallback if `MAINNET_RPC_URL` is not set.

## Test coverage

All test files; every fork test exercises real Lido V3 contracts on a mainnet fork. **No `vm.mockCall`.** Test count and coverage:

| File | Tests | Type | Highlights |
| --- | --- | --- | --- |
| [`test/VaultStETH.t.sol`](test/VaultStETH.t.sol) | 13 | unit | Adapter-only mint/burn; freely-transferable semantics; ERC-20 standard behaviors; fuzz roundtrip |
| [`test/Factory.t.sol`](test/Factory.t.sol) | 7 | fork | Atomic deployment; full Dashboard role graph; multiple borrowers; revert paths |
| [`test/PledgeGuard.t.sol`](test/PledgeGuard.t.sol) | 14 | fork | Withdraw bounded by `withdrawableValue`; pledge-undermining actions blocked; Ownable2Step |
| [`test/Adapter.t.sol`](test/Adapter.t.sol) | 17 | fork | Pledge/unpledge; redeem via real `Lido.mintShares` + `wstETH.wrap`; queue priority (liquidation > voluntary > FIFO) |
| [`test/Liquidation.t.sol`](test/Liquidation.t.sol) | 5 | fork | End-to-end: pledge → seize → redeem → real wstETH out; atomic same-block; partial liquidation; fair-value receipt |
| **Total** | **56** | | All passing |

Full suite runs in ~17 seconds on a typical RPC.

## What's intentionally not built here

- A vaultStETH price-feed adapter for AAVE Main Spoke — that's separate work (the AIP will provision one).
- An off-chain liquidator bot — vaultStETH is freely transferable, so standard AAVE liquidator infrastructure suffices. An optional redemption-priority coordinator (off-chain) can call `markForLiquidation` more reliably than monitoring AAVE events; not required for correctness.
- A fixed-rate / IRS-hedge layer (Aegis-style) — a future Layer-3 product that sits on top of this design without further AAVE governance.

## Documentation

- [`docs/ADR.md`](docs/ADR.md) — Architecture Decision Record.
- [`docs/Implementation-Plan.md`](docs/Implementation-Plan.md) — phased build plan.
- [`../Aegis×Babylon_liquidation-5.md`](../Aegis%C3%97Babylon_liquidation-5.md) — the design narrative that landed this architecture.
- Earlier docs in the same series ([`-1`](../Aegis%C3%97Babylon_liquidation.md) through [`-4`](../Aegis%C3%97Babylon_liquidation-4.md)) walk the evolution of the design and the rejected alternatives.
