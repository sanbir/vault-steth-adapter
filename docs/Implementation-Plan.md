# Implementation Plan — vaultStETH on AAVE Main Spoke

**Date:** 2026-05-28
**Status:** In progress
**Owning ADR:** [`ADR.md`](ADR.md)

---

## Scope

Ship four production-grade Solidity contracts that, together with a single AAVE asset-listing AIP, deliver stVault-backed borrowing on AAVE v4 Main Spoke.

| Contract | Lines (est.) | Purpose |
| --- | --- | --- |
| `VaultStETH` | ~80 | Freely-transferable ERC-20. Minted/burned only by the Adapter. |
| `Adapter` | ~350 | Holds `MINT_ROLE` on pledged Lido Dashboards. Issues vaultStETH against pledges. Burns vaultStETH and mints wstETH from a pledged vault on redemption, ordered by a priority queue. |
| `PledgeGuard` | ~200 | Per-borrower wrapper that holds Dashboard admin roles while the vault is pledged. Stops borrowers from undermining their own pledge. |
| `StVaultFactory` | ~120 | Atomic deployment: creates Lido stVault via the canonical factory, deploys a PledgeGuard, wires Dashboard role graph. |

Plus interfaces (`IDashboard`, `ILidoVaultFactory`, `IWstETH`, etc.) and shared utilities (`Addresses.sol`).

## Out of scope

- AAVE Main Spoke modifications (we don't make any).
- A custom liquidator bot (standard AAVE liquidators cover the flow).
- A vaultStETH price-feed adapter contract — separate piece of work, the AAVE asset-listing AIP will wire one in. Spec'd in the ADR §Consequences but built later.
- Aegis-style fixed-rate UX layer — a future Layer-3 product that sits on top of this.
- Off-chain redemption-priority coordinator — useful for orchestrating multi-vault liquidations, but not required for correctness. Tagged as Phase 2.

## High-level architecture

```
                            ┌─────────────────────────────────┐
                            │     StVaultFactory              │
                            │  atomic: vault + guard + roles  │
                            └──────────────┬──────────────────┘
                                           │
                              creates user's Lido stVault
                              + Dashboard (admin = PledgeGuard)
                                           │
                                           ▼
                         ┌──────────────────────────────────────┐
                         │       Borrower's Lido Dashboard      │
                         │  admin roles locked to PledgeGuard   │
                         │  MINT_ROLE granted to Adapter        │
                         │  FUND/BURN/REBALANCE direct to user  │
                         └──────────────┬───────────────────────┘
                                        │
                                        │  pledge mint capacity
                                        ▼
                            ┌──────────────────────────┐
                            │         Adapter          │
                            │  - per-vault pledge log  │
                            │  - redemption queue      │
                            │  - mints vaultStETH      │
                            │  - mints wstETH on redeem│
                            └──────────┬───────────────┘
                                       │
                                       │  mint
                                       ▼
                            ┌──────────────────────────┐
                            │       vaultStETH         │
                            │  freely transferable     │
                            │  ERC-20 (no allowlist)   │
                            └──────────┬───────────────┘
                                       │
                                       │  supply as collateral
                                       ▼
                            ┌──────────────────────────┐
                            │   AAVE v4 Main Spoke     │
                            │  standard listing, no    │
                            │  custom code             │
                            └──────────────────────────┘
```

## Phases

### Phase 1 — Core contracts (Week 1–2)

**Deliverables:**
- `src/Addresses.sol` — verified mainnet addresses (Lido V3 + AAVE v4 + Chainlink).
- `src/interfaces/IDashboard.sol`, `IStakingVault.sol`, `IVaultHub.sol`, `ILidoVaultFactory.sol`, `IWstETH.sol`, `IStETH.sol`.
- `src/VaultStETH.sol` — `ERC20` extending OpenZeppelin's base. Constructor sets adapter; `mint` / `burn` restricted to the adapter.
- `src/PledgeGuard.sol` — Ownable2Step, holds Dashboard admin + pledge-reducing roles, filters borrower actions. Slim version of the existing `stvaults-liquidation-manager/src/core/PledgeGuard.sol` (drop the SPOKE pointer; no longer needed).
- `src/Adapter.sol`:
  - `pledge(dashboard, shares)` — mints vaultStETH to caller; records pledge.
  - `unpledge(dashboard, shares)` — burns vaultStETH from caller; reduces pledge. Only when not in queue.
  - `redeem(amount, recipient)` — burns vaultStETH from caller; selects vault per queue; calls `dashboard.mintShares(recipient, amount + 2 wei)`; wraps to wstETH if needed.
  - `markForLiquidation(borrower, spoke)` — permissionless flag-set when borrower's HF < 1 on Aave Main Spoke; verified on-chain by reading `Spoke.getUserAccountData(borrower).healthFactor`. Pushes the borrower's vault to the head of the redemption queue.
  - Internal queue: three sub-queues (liquidation, voluntary-close, FIFO general). FIFO drain order.
- `src/StVaultFactory.sol` — atomic deployment. Closely mirrors the existing factory; adapted for the new Adapter shape.

**Acceptance criteria:**
- `forge build` clean.
- All Solidity has natspec.
- No `vm.mockCall` anywhere — must work against real Lido contracts on a mainnet fork.

### Phase 2 — Integration tests (Week 2–3)

**Deliverables:**
- `test/BaseFork.t.sol` — shared scaffolding. Forks mainnet at a fixed block, exposes labeled addresses and helpers.
- `test/Deployment.t.sol` — Phase-1 contracts deploy cleanly with right immutables.
- `test/VaultStETH.t.sol` — ERC-20 mechanics. Mint/burn restricted to adapter; transfers, allowances, total supply invariants.
- `test/Factory.t.sol` — atomic vault creation. Verifies Lido factory was actually called, role graph is correct, Dashboard admin sits on PledgeGuard.
- `test/PledgeGuard.t.sol` — lifecycle and pass-through filtering. Borrower CAN fund/burn/rebalance. Borrower CANNOT withdraw past unencumbered, disconnect, transfer ownership, etc.
- `test/Adapter.t.sol` — pledge → mint vaultStETH; unpledge; redeem against real Lido vault; redemption queue priorities (liquidation > voluntary-close > FIFO).
- `test/Redemption.t.sol` — end-to-end: pledge a real stVault on a fork → mint vaultStETH → burn for wstETH → assert real stETH minted from real Lido vault, real wstETH delivered.

**Acceptance criteria:**
- ≥ 25 tests passing on mainnet fork.
- No `vm.mockCall`.
- All Lido / AAVE addresses verified on-fork (`getCode` returns non-empty).
- Test run completes in < 60 seconds with a reasonable RPC.

### Phase 3 — AAVE-side integration tests (Week 3–4)

**Deliverables:**
- `test/AaveIntegration.t.sol` — verify vaultStETH would behave correctly on AAVE Main Spoke:
  - vaultStETH transfers normally (no allowlist).
  - Standard AAVE `liquidationCall` semantics: the seized vaultStETH is freely transferable to the liquidator.
  - Simulated liquidation flow: liquidator receives vaultStETH, immediately calls `Adapter.redeem`, gets wstETH within the same block.

Since vaultStETH isn't yet listed on AAVE mainnet (will be only after our AIP passes), this phase uses a "minimal Aave-mimic" supply/borrow/seize scaffolding that exercises the same calldata patterns and assertions. The full AAVE Main Spoke fork test is gated on the AIP execution.

**Acceptance criteria:**
- Liquidation simulation passes: liquidator ends the block holding wstETH equivalent to the seized vaultStETH (within Lido's 2-wei mint buffer).
- Redemption queue prioritisation provably picks the liquidated borrower's vault before any other.

### Phase 4 — Documentation + handoff (Week 4)

**Deliverables:**
- `README.md` — quick start, build/test instructions.
- Updated `ADR.md` and `Implementation-Plan.md` (this doc) with any deltas surfaced during build.
- `docs/use-cases/` — runbooks for: deploying a vault, pledging, supplying on Aave, voluntary close, liquidation walkthrough.

## Risk register

| Risk | Mitigation |
| --- | --- |
| Lido V3 mainnet contracts evolve and break our interface assumptions | Run integration tests against the latest mainnet block in CI; surface ABI changes immediately. |
| AAVE risk review demands a yield-bearing vaultStETH (rebasing or auto-compounding) | Yield-bearing variant adds complexity to redemption math. If required by risk review, ship a wrapped variant similar to wstETH-of-vaultStETH. Acceptable scope expansion. |
| Borrower-side attack: borrower transfers vaultStETH out of Aave, then voluntary-closes their vault, leaving Aave with a vaultStETH claim that has no backing | Adapter's `unpledge` must check that the corresponding vaultStETH balance was returned to the original pledger. Since vaultStETH is freely transferable, the borrower can't unilaterally unpledge while their vaultStETH is supplied on Aave — they'd need to first withdraw from Aave (which is debt-collateralization-gated). |
| Adversarial redemption: a vaultStETH holder drains a non-liquidated borrower's vault out of FIFO order | Redemption queue priorities: liquidated > voluntary-close > FIFO. A third-party redeemer can only access the FIFO tail. Markets the vault holder closes voluntarily are not consumed by the FIFO tail; only borrowers who explicitly mark themselves for voluntary-close enter that bucket. |
| Lido `mintShares` reverts due to quarantine or other state | Adapter falls through to next vault in the queue; if queue is exhausted, the redemption reverts and the liquidator can retry later. No funds at risk — vaultStETH is not burned until the mint succeeds. |
| Standard AAVE liquidator bots don't know about vaultStETH at launch | We'll seed liquidation with our own bot (forked from `stvaults-liquidator`, much simpler) for the first 30–60 days; remove once third-party liquidators integrate. |

## Reproducibility

Tests run against a real mainnet fork. To reproduce locally:

```bash
git clone <this repo>
cd vault-steth-adapter
forge install
export MAINNET_RPC_URL=<your RPC>
forge test -vv
```

No environment-specific setup beyond an Ethereum mainnet RPC URL.

## Tracked work

- [ ] Phase 1: contracts written, `forge build` clean.
- [ ] Phase 2: integration tests against Lido mainnet fork.
- [ ] Phase 3: simulated AAVE liquidation tests.
- [ ] Phase 4: docs + handoff.
- [ ] **Out of plan:** AAVE AIP drafting, price-feed adapter, security audit kickoff. Tracked separately.
