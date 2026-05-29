// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

/// @notice Minimal view into the Adapter used to read how much mint capacity is pledged
///         against this guard's dashboard. Declared here to avoid importing the full
///         Adapter (no dependency cycle, smaller surface).
interface IAdapterPledges {
    function pledgedSharesOf(address dashboard) external view returns (uint256);
    function MINT_BUFFER_SHARES() external view returns (uint256);
}

/// @title PledgeGuard
/// @notice Per-borrower wrapper that holds Dashboard admin + pledge-reducing roles while
///         the vault is in active use as AAVE collateral. Borrowers retain only the safe
///         direct-use roles (FUND, BURN, REBALANCE, beacon-pause-resume). Operations that
///         would undermine the pledge (WITHDRAW past the pledge-backing floor,
///         VOLUNTARY_DISCONNECT, transferring vault ownership, etc.) must go through this
///         contract, which the borrower owns but which blocks pledge-undermining actions.
/// @dev    The pledge in this design is LATE-MINT: `Adapter.pledge` does NOT mint a Lido
///         liability, so `Dashboard.liabilityShares` stays 0 and `Dashboard.withdrawableValue()`
///         is NOT reduced by the pledge. Therefore `withdrawableValue` alone does NOT lock
///         the underlying ETH. This guard enforces the lock explicitly: after any withdraw,
///         the vault must still be able to mint the pledged shares
///         (`remainingMintingCapacityShares(0) >= Adapter.pledgedSharesOf(dashboard)`).
///         Without this check a borrower could borrow against vaultStETH on AAVE AND
///         withdraw the underlying ETH from the same collateral (a double-spend that leaves
///         the outstanding vaultStETH unbacked).
contract PledgeGuard is Ownable2Step, ReentrancyGuard {
    // -------- immutables --------
    IDashboard public immutable DASHBOARD;
    address public immutable ADAPTER;

    bytes32 public immutable WITHDRAW_ROLE;
    bytes32 public immutable VOLUNTARY_DISCONNECT_ROLE;
    bytes32 public immutable REQUEST_VALIDATOR_EXIT_ROLE;
    bytes32 public immutable TRIGGER_VALIDATOR_WITHDRAWAL_ROLE;
    bytes32 public immutable VAULT_CONFIGURATION_ROLE;

    // -------- events --------
    event GuardWithdrew(address indexed recipient, uint256 amount);

    // -------- errors --------
    error ZeroAddress();
    error PledgeStillActive();
    error ExceedsWithdrawable();
    error WouldUnbackPledge(uint256 capacityAfter, uint256 requiredFloor);

    constructor(address dashboard_, address adapter_, address owner_) Ownable(owner_) {
        if (dashboard_ == address(0) || adapter_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        DASHBOARD = IDashboard(dashboard_);
        ADAPTER = adapter_;

        WITHDRAW_ROLE = IDashboard(dashboard_).WITHDRAW_ROLE();
        VOLUNTARY_DISCONNECT_ROLE = IDashboard(dashboard_).VOLUNTARY_DISCONNECT_ROLE();
        REQUEST_VALIDATOR_EXIT_ROLE = IDashboard(dashboard_).REQUEST_VALIDATOR_EXIT_ROLE();
        TRIGGER_VALIDATOR_WITHDRAWAL_ROLE =
            IDashboard(dashboard_).TRIGGER_VALIDATOR_WITHDRAWAL_ROLE();
        VAULT_CONFIGURATION_ROLE = IDashboard(dashboard_).VAULT_CONFIGURATION_ROLE();
    }

    // ============================================================================
    //                          Filtered pass-through actions
    // ============================================================================

    /// @notice Withdraw ETH from the stVault to `recipient`, bounded by BOTH:
    ///         (1) the dashboard's `withdrawableValue` (Lido's own solvency limit), AND
    ///         (2) the pledge-backing floor — after the withdrawal the vault MUST still be
    ///             able to mint the pledged shares PLUS the redemption mint buffer, i.e.
    ///             `remainingMintingCapacityShares(0) >= pledged + Adapter.MINT_BUFFER_SHARES()`.
    /// @dev    Check (2) is the fix for the late-mint double-spend: because pledging mints
    ///         no Lido liability, `withdrawableValue` does not reflect the pledge, so the
    ///         guard must consult the Adapter's pledge directly. We use a POST-withdraw
    ///         capacity check (delegating the capacity math to Lido itself) and revert the
    ///         whole call if it would unback the pledge. `nonReentrant` guards the external
    ///         ETH send to `recipient`.
    ///
    ///         The `+ MINT_BUFFER_SHARES` term: redemption (`Adapter._drainDashboard`) mints
    ///         `shares + MINT_BUFFER_SHARES` of Lido liability to absorb share<->wstETH
    ///         rounding. Reserving only `pledged` would let a full single-call redemption
    ///         revert by the buffer at the exact floor; reserving `pledged + buffer`
    ///         guarantees the entire pledge is always redeemable in one call.
    function withdraw(address recipient, uint256 amount) external onlyOwner nonReentrant {
        uint256 withdrawable = DASHBOARD.withdrawableValue();
        if (amount > withdrawable) revert ExceedsWithdrawable();

        DASHBOARD.withdraw(recipient, amount);

        // Pledge-backing invariant: the vault must still be able to mint the pledged shares
        // plus the redemption buffer.
        uint256 pledged = IAdapterPledges(ADAPTER).pledgedSharesOf(address(DASHBOARD));
        if (pledged != 0) {
            uint256 floor = pledged + IAdapterPledges(ADAPTER).MINT_BUFFER_SHARES();
            uint256 capacityAfter = DASHBOARD.remainingMintingCapacityShares(0);
            if (capacityAfter < floor) revert WouldUnbackPledge(capacityAfter, floor);
        }

        emit GuardWithdrew(recipient, amount);
    }

    /// @notice Forward `pauseBeaconChainDeposits` to the dashboard.
    function pauseBeaconChainDeposits() external onlyOwner {
        DASHBOARD.pauseBeaconChainDeposits();
    }

    /// @notice Forward `resumeBeaconChainDeposits` to the dashboard.
    function resumeBeaconChainDeposits() external onlyOwner {
        DASHBOARD.resumeBeaconChainDeposits();
    }

    // ============================================================================
    //                                    Views
    // ============================================================================

    /// @notice The pledge-backing floor, in stETH shares: the vault's
    ///         `remainingMintingCapacityShares(0)` (a shares quantity) must stay at or above
    ///         this value for a withdrawal to succeed. Equals `pledged + MINT_BUFFER_SHARES`
    ///         when a pledge is active (the buffer mirrors the redemption mint), or 0 when no
    ///         pledge is active (full `withdrawableValue` is releasable). A frontend reduces
    ///         the withdrawal amount until the post-withdraw `remainingMintingCapacityShares(0)`
    ///         would still be >= this floor.
    function pledgeBackingFloorShares() external view returns (uint256) {
        uint256 pledged = IAdapterPledges(ADAPTER).pledgedSharesOf(address(DASHBOARD));
        if (pledged == 0) return 0;
        return pledged + IAdapterPledges(ADAPTER).MINT_BUFFER_SHARES();
    }

    // ============================================================================
    //                              Blocked actions
    // ============================================================================
    // These functions exist as explicit reverts so that a borrower attempting them
    // through the Guard receives a clear error rather than a low-level revert from the
    // dashboard. The dashboard itself ALSO blocks them via role gating since the
    // borrower does not hold the corresponding role. This contract holds the role; we
    // deliberately do NOT expose it as a callable forwarding function while a pledge is
    // active.

    function requestValidatorExit(bytes calldata /* pubkeys */) external view onlyOwner {
        revert PledgeStillActive();
    }

    function voluntaryDisconnect() external view onlyOwner {
        revert PledgeStillActive();
    }

    function transferVaultOwnership(address /* newOwner */) external view onlyOwner {
        revert PledgeStillActive();
    }
}
