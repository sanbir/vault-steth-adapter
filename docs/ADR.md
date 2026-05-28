# ADR — vaultStETH on AAVE Main Spoke (No Custom Spoke)

**Status:** Accepted
**Date:** 2026-05-28
**Author:** P2P Research (alexander.biryukov@p2p.org)
**Supersedes:** the Path A custom-Spoke design implemented in [`stvaults-liquidation-manager`](../../stvaults-liquidation-manager) + [`stvaults-spoke`](../../stvaults-spoke). Those repos remain for historical reference. This is the production design.

---

## Context

We need an Ethereum-side product that lets institutional borrowers borrow stablecoins against Lido stVaults on AAVE v4. The full design space and tradeoffs were explored across five preceding documents in [`/lido/Aegis×Babylon_liquidation*`](../../). This ADR records the final selected design and rationale.

We have three viable architectures:

1. **Path A** — Custom AAVE v4 Spoke that overrides `liquidationCall` and `_processUserAccountData` to manage per-vault state. Late-mint, hard per-vault isolation. ~9–12 month build, $800k–$1.5M audit budget, requires AAVE governance to approve a custom Spoke listing. Already partly implemented in `stvaults-liquidation-manager` + `stvaults-spoke`.

2. **Path B (Babylon-shape)** — Standard AAVE v4 Spoke for lending + custom Swap Spoke for liquidation settlement, transfer-restricted vaultStETH ERC-20. ~6 month build, $500k audit, two AIPs. Babylon needs this pattern because BTC settlement is slow; we don't have that constraint.

3. **Path C (this ADR)** — Standard AAVE Main Spoke listing of a freely-transferable vaultStETH ERC-20, plus an Adapter that atomically mints wstETH on redemption. Per-vault isolation enforced by the Adapter's redemption queue rather than by AAVE-level structure. ~3 month build, $300–400k audit, one AIP (asset listing).

## Decision

**Path C.** Build vaultStETH as a freely-transferable ERC-20 with an Adapter that handles minting (against pledged Lido stVaults) and redemption (calls `Lido.mintShares` from a pledged vault to deliver wstETH). List vaultStETH on AAVE Main Spoke as a regular collateral asset. Use only standard AAVE v4 mechanisms — no custom Spokes.

## Rationale

### Why not Path A (the current implementation)

- **Custom Spokes are expensive to ship.** The Spoke contract is the most security-critical surface in the system; risk reviewers (Chaos Labs / LlamaRisk) require deep code review on top of parameter calibration. Audit budget for a custom Spoke is ~$800k–$1.5M; for an asset listing it's ~$300–400k.
- **Custom Spokes require deeper AAVE governance buy-in.** A Spoke registration is a much larger ask than an asset listing — the former requires Chaos Labs / LlamaRisk to sign off on novel code paths, the latter only on risk parameters for an off-the-shelf asset.
- **Per-vault isolation, the main differentiator of Path A, has a recoverable alternative.** The Adapter's redemption queue (Section: Redemption Queue below) enforces "your vault drains for your liquidation" in the cases that matter, without needing AAVE to know about the binding.
- **Path A's custom liquidator bot is a permanent operational dependency.** Path C reuses the existing AAVE liquidator ecosystem; no bot infrastructure required from us at launch.

### Why not Path B (the Babylon-shape with a Swap Spoke)

- **Babylon needs the Swap Spoke because Bitcoin settlement is slow** (hours of ZK proof + fraud-proof window). The Swap Spoke escrows vaultBTC during the multi-hour redemption and pays liquidators WBTC immediately from working capital, with arbitrageurs settling later.
- **We do not have this constraint.** Lido `mintShares` is one Ethereum transaction. A liquidator can seize vaultStETH and redeem for wstETH in the same block. The Swap Spoke pattern collapses to a no-op for us.
- **Maintaining a Swap Spoke we don't need is pure overhead.** Extra contract, extra AIP, extra working-capital pool to fund, extra arbitrageur class to coordinate, all to solve a problem that doesn't exist for Ethereum-native collateral.

### Why Path C is structurally sound

- The Adapter is the moral equivalent of Babylon's Swap Spoke for our chain-symmetric case. It does the same job (transform seized collateral into a usable asset) but does it atomically rather than asynchronously.
- vaultStETH is structurally identical to any other Lido LST (cbETH, rETH, stETH itself wrapped as wstETH) from AAVE's perspective. AAVE has well-established risk-review processes for LST listings.
- The redemption queue is a well-understood pattern (Lombard uses an analogous queue for LBTC; Lido's withdrawal queue follows similar logic).
- The single AAVE AIP we file is a wstETH-shaped listing. Risk parameters can mirror wstETH's initially and converge as track record accumulates.

## Consequences

### Positive

- **~70% reduction in audit surface.** Drop the entire custom Spoke (`StVaultSpoke`), custom oracle (`CapacityOracle`), custom liquidation engine (`liquidateStVault`), and custom liquidator bot (`stvaults-liquidator`). Add an ERC-20 and a redemption queue.
- **~3× faster time-to-mainnet.** ~3 months vs ~9–12 months for Path A.
- **~2–4× cheaper audit.** ~$300–400k vs ~$800k–$1.5M.
- **One AAVE AIP instead of one (heavy Spoke listing) or two (Babylon-shape).**
- **Standard AAVE liquidator ecosystem covers liquidation.** No P2P-run bot infrastructure required.
- **Atomic liquidation.** Liquidator gets wstETH in the same block they call `liquidationCall`. No two-phase settlement, no working capital float.
- **Path A and Path B contracts remain in their respective repositories as historical artifacts.** No deletion required, but no further development of them either.

### Negative

- **Per-vault isolation is policy-enforced, not structural.** Babylon's two-Spoke design enforces vault binding at the AAVE / Bitcoin-script layer. Ours enforces it via the Adapter's HF-gated redemption queue. The protection lives in our contract rather than in AAVE's. Acceptable per stakeholder confirmation (see decision context in `Aegis×Babylon_liquidation-5.md`). **Update (production hardening):** the policy is now strict on-chain — see "Production Hardening" section below.
- **vaultStETH is yield-static, not yield-bearing.** Validator yield accrues to the vault owner (the borrower), not to vaultStETH holders. Different economic model from wstETH (which IS yield-bearing). This must be clearly disclosed in the AAVE risk review and in user-facing docs.
- **vaultStETH price feed needs a custom adapter.** The natural price feed is `1 vaultStETH ≈ 1 stETH at issuance`, but as time passes the issuing vault accumulates yield that's not reflected in vaultStETH price. We need either: (a) a yield-distribution mechanism that periodically rebases vaultStETH supply, OR (b) a price feed that values vaultStETH at issue rate minus expected redemption-time difference. Default plan: (b) with conservative haircut.
- **Path A's per-borrower NodeOp / Dashboard sales pitch becomes harder.** Borrowers still own their stVault and pick their NodeOp, but at the AAVE level they look like generic LST holders. Marketing implication: lean on "your vault, your NodeOp, your yield" rather than "AAVE-level isolation."

### Neutral

- **The vault-side custodial pattern (Custodian + PledgeGuard) is unchanged.** Same Lido Dashboard role-locking mechanic. Just locks roles to a different counterparty (the Adapter instead of the custom Spoke).
- **Code style and audit conventions stay aligned with `auto-rebalancer-safe-modules`.** Mainnet-fork tests, no `vm.mockCall`, standard Foundry conventions.

## Alternatives considered

| Alternative | Verdict |
| --- | --- |
| Path A — custom Spoke (the current implementation) | Works, but expensive and slow to ship. Kept as fallback if institutional buyers reject Path C's policy-level isolation. |
| Path B — Babylon-shape with Swap Spoke + transfer-restricted token | Unnecessary for Ethereum-native collateral. Adds Spoke complexity to solve a problem we don't have. |
| Plain wstETH on AAVE Main Spoke (already exists) | No differentiation. We'd just be supplying wstETH; nothing P2P-specific about the product. |
| Pooled p2pStETH as a yield-bearing LST | Loses the late-mint property (which is structurally preserved in Path C). Converges on cbETH/rETH economically. Different product. |
| Building elsewhere (Morpho, Spark, Euler) | Different ecosystem, less institutional traction for stETH-collateralised borrowing. AAVE is the right venue. |

## Decision authority

Architecture decision approved by the project's product owner via the conversation thread that produced `Aegis×Babylon_liquidation-5.md`. Stakeholder confirmation that "per-vault isolation enforced by Adapter policy, not by the AAVE layer" is an acceptable trade is recorded there.

## Production Hardening (Update 2026-05-28)

### Problem revisited

The initial Path C implementation accepted a known weakness: **a healthy borrower's vault could be drained by external callers** when the Adapter's general FIFO queue was the only routing rule. Concretely: if Alice and Bob both pledged, Alice was queue-head, and Bob got liquidated on AAVE, a naive liquidator could call `Adapter.redeem` without `markForLiquidation(bobDashboard)` first — and the Adapter would drain Alice's vault even though Alice was healthy.

Stakeholder feedback escalated this from "acceptable policy-level tradeoff" to "must be structurally prevented before mainnet." This update implements that hardening.

### What changed

1. **General FIFO queue removed from the external redemption path.** `redeem` ONLY drains dashboards that are in the liquidation queue OR the voluntary queue. Unmarked dashboards are never drained by `redeem`.

2. **`markForLiquidation` is now HF-gated.** It calls `AAVE_POOL.getUserAccountData(borrower)` and reverts unless `healthFactor < 1e18`. A healthy borrower cannot be marked. Permissionless to call, but only succeeds for legitimately-liquidating borrowers.

3. **`_selectMarkedDashboard` re-verifies HF at selection time.** Between marking and redemption, a borrower may recover (AAVE deposit, price rebound). The selector reads HF again and demotes recovered borrowers in-flight. Demotion is also exposed via the public `cleanupLiquidationQueue(maxIterations)` function so it can persist even when redeem reverts.

4. **`selfRedeem(dashboard, shares, recipient)` added.** Lets a borrower drain their OWN vault without needing to be marked, replacing the general-FIFO path's "any pledged vault is drainable by its borrower" property.

5. **Constructor takes an `IAavePool` address.** This is the source of healthFactor reads. Production deployment points at AAVE v4 Main Spoke; tests use a deployed `MockAavePool`.

### Formal verification

The production invariant — **"a healthy stVault is never drained by an external call"** — is now formally proven by Halmos symbolic execution in [`test/HalmosInvariants.t.sol`](../test/HalmosInvariants.t.sol). 12/12 checks pass, covering every reachable calldata combination on the Adapter's full external surface (68 paths for the main invariant alone).

```
[PASS] check_HealthyAliceNeverDrainedByExternalCall       (68 paths)
[PASS] check_HealthyAliceUntouchedEvenWhenBobLiquidating  (78 paths)
[PASS] check_HealthyAliceUntouchedEvenWhenBobVoluntary    (77 paths)
... 9 more focused checks ...
```

This shifts the "per-vault isolation is policy-enforced" caveat from a soft assurance to a mathematically-verified property of the production code.

### Negative consequences of hardening

- **Borrowers must `selfRedeem` rather than `redeem` to drain their own vault.** Two functions instead of one. Minor UX friction; the frontend hides it.
- **Liquidator bots must call `markForLiquidation` before `redeem`.** This was already required in the old design as a queue-priority signal; now it's required for correctness. Standard practice in the Aegis-style liquidator pattern.
- **Cleanup of recovered borrowers requires explicit calls.** `cleanupLiquidationQueue` is permissionless; a Keeper bot or any participant calls it periodically. Without cleanup, recovered borrowers' dashboards sit in the queue but are skipped at selection (correctness preserved; only operational tidiness).

## References

- [Aegis×Babylon_liquidation-5.md](../../Aegis%C3%97Babylon_liquidation-5.md) — the final architecture summary that triggered the original decision.
- [Aegis-User-interactions.md](../../Aegis-User-interactions.md) — comparison of the user-facing interaction surface between Aegis and this design.
- [About-AAVE-v4.md](../../../aave/About-AAVE-v4.md) — the AAVE v4 architecture this design plugs into.
- [Halmos](https://github.com/a16z/halmos) — symbolic execution tool used for the formal-verification suite.
- [stvaults-liquidation-manager](../../stvaults-liquidation-manager) — Path A implementation, kept for reference.
- [auto-rebalancer-safe-modules](../../../auto-rebalancer-safe-modules) — reference for test style and conventions.
