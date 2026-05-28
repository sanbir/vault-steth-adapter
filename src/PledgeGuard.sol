// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

/// @title PledgeGuard
/// @notice Per-borrower wrapper that holds Dashboard admin + pledge-reducing roles while
///         the vault is in active use as AAVE collateral. Borrowers retain only the safe
///         direct-use roles (FUND, BURN, REBALANCE, beacon-pause-resume). Operations that
///         would undermine the pledge (WITHDRAW past unencumbered, VOLUNTARY_DISCONNECT,
///         transferring vault ownership, etc.) must go through this contract, which the
///         borrower owns but which blocks pledge-undermining actions.
/// @dev    Compared to the Path A version in `stvaults-liquidation-manager`, this Guard
///         has no Spoke pointer — there is no custom Spoke in this design. The
///         "is the pledge active?" check is delegated to the Adapter.
contract PledgeGuard is Ownable2Step {
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

    /// @notice Withdraw ETH from the stVault to `recipient`. Bounded by the dashboard's
    ///         current `withdrawableValue` (Lido's own check that doesn't violate locked
    ///         collateral). NO ADDITIONAL check is applied here — the existence of a
    ///         pledge is reflected in `withdrawableValue` itself (locked ETH cannot be
    ///         withdrawn).
    /// @dev    `withdrawableValue` returns the ether amount the dashboard can withdraw
    ///         right now given current Lido state. The borrower can drain this amount
    ///         safely; it cannot ever include collateral backing an active pledge.
    function withdraw(address recipient, uint256 amount) external onlyOwner {
        uint256 withdrawable = DASHBOARD.withdrawableValue();
        if (amount > withdrawable) revert ExceedsWithdrawable();
        DASHBOARD.withdraw(recipient, amount);
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
    //                              Blocked actions
    // ============================================================================
    // These functions exist as explicit reverts so that a borrower attempting them
    // through the Guard receives a clear error rather than a low-level revert from the
    // dashboard. The dashboard itself ALSO blocks them via role gating since the
    // borrower does not hold the corresponding role on the dashboard. This contract
    // does hold the role; we deliberately do NOT expose it as a callable forwarding
    // function while a pledge is active.

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
