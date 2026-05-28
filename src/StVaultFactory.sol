// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IDashboard, ILidoVaultFactory} from "./interfaces/IDashboard.sol";
import {PledgeGuard} from "./PledgeGuard.sol";
import {Adapter} from "./Adapter.sol";

/// @title StVaultFactory
/// @notice Atomic deployment of a Lido stVault tied to our Adapter:
///           1. Calls Lido's VaultFactory.createVaultWithDashboard(...) with this contract
///              as the temporary `_defaultAdmin`.
///           2. Deploys a fresh PledgeGuard owned by the borrower, bound to the Dashboard
///              and the Adapter.
///           3. Configures the Dashboard role graph:
///                - DEFAULT_ADMIN_ROLE                → PledgeGuard
///                - MINT_ROLE                         → Adapter
///                - WITHDRAW / VOLUNTARY_DISCONNECT / VAULT_CONFIGURATION /
///                  REQUEST_VALIDATOR_EXIT / TRIGGER_VALIDATOR_WITHDRAWAL → PledgeGuard
///                - FUND / BURN / REBALANCE / PAUSE_BEACON_CHAIN_DEPOSITS /
///                  RESUME_BEACON_CHAIN_DEPOSITS      → Borrower
///           4. Revokes DEFAULT_ADMIN_ROLE from this Factory (factory steps out).
///           5. Calls `Adapter.registerDashboard(dashboard, borrower)` so subsequent
///              borrower pledges work.
/// @dev    The single atomic transaction means the borrower cannot be exposed to a state
///         where role wiring is half-done. If any step reverts, the whole flow reverts and
///         the dashboard is never used.
contract StVaultFactory {
    // -------- immutables --------
    ILidoVaultFactory public immutable LIDO_FACTORY;
    Adapter public immutable ADAPTER;

    // -------- events --------
    event BorrowerVaultCreated(
        address indexed borrower,
        address indexed dashboard,
        address indexed stakingVault,
        address pledgeGuard
    );

    // -------- errors --------
    error ZeroAddress();

    constructor(address lidoFactory_, address adapter_) {
        if (lidoFactory_ == address(0) || adapter_ == address(0)) revert ZeroAddress();
        LIDO_FACTORY = ILidoVaultFactory(lidoFactory_);
        ADAPTER = Adapter(adapter_);
    }

    /// @notice Create a stVault, deploy its PledgeGuard, wire roles, register the
    ///         dashboard with the Adapter.
    /// @param borrower            Future owner of the PledgeGuard (also the user-facing actor).
    /// @param nodeOperator        Node operator for the StakingVault (immutable on the vault).
    /// @param nodeOperatorFeeBP   Node operator fee, BPS.
    /// @param confirmExpiry       Multi-confirm expiry on the Dashboard.
    /// @dev   Caller must send at least the Lido `CONNECT_DEPOSIT` as `msg.value`
    ///        (1 ether on mainnet at the time of writing).
    function createBorrowerVault(
        address borrower,
        address nodeOperator,
        uint256 nodeOperatorFeeBP,
        uint256 confirmExpiry
    ) external payable returns (address dashboard, address stakingVault, address pledgeGuard) {
        if (borrower == address(0) || nodeOperator == address(0)) revert ZeroAddress();

        // Step 1: Lido factory creates vault + dashboard with this Factory as DEFAULT_ADMIN.
        ILidoVaultFactory.RoleAssignment[] memory emptyRoles =
            new ILidoVaultFactory.RoleAssignment[](0);
        (stakingVault, dashboard) = LIDO_FACTORY.createVaultWithDashboard{value: msg.value}(
            address(this),
            nodeOperator,
            nodeOperator,
            nodeOperatorFeeBP,
            confirmExpiry,
            emptyRoles
        );

        // Step 2: Deploy PledgeGuard bound to this dashboard and owned by borrower.
        pledgeGuard = address(
            new PledgeGuard(dashboard, address(ADAPTER), borrower)
        );

        // Step 3: Configure the Dashboard role graph.
        _configureRoles(dashboard, pledgeGuard, borrower);

        // Step 4: Register the dashboard with the Adapter for later pledging.
        ADAPTER.registerDashboard(dashboard, borrower);

        emit BorrowerVaultCreated(borrower, dashboard, stakingVault, pledgeGuard);
    }

    function _configureRoles(address dashboard, address pledgeGuard, address borrower) internal {
        IDashboard d = IDashboard(dashboard);

        // DEFAULT_ADMIN_ROLE first to the PledgeGuard (it will continue to administer roles).
        bytes32 adminRole = d.DEFAULT_ADMIN_ROLE();
        d.grantRole(adminRole, pledgeGuard);

        // MINT_ROLE to the Adapter — only the Adapter can mint stETH from this vault.
        d.grantRole(d.MINT_ROLE(), address(ADAPTER));

        // Broad pledge-affecting roles to the Guard so the borrower can't reach them
        // directly.
        d.grantRole(d.WITHDRAW_ROLE(), pledgeGuard);
        d.grantRole(d.VOLUNTARY_DISCONNECT_ROLE(), pledgeGuard);
        d.grantRole(d.VAULT_CONFIGURATION_ROLE(), pledgeGuard);
        d.grantRole(d.REQUEST_VALIDATOR_EXIT_ROLE(), pledgeGuard);
        d.grantRole(d.TRIGGER_VALIDATOR_WITHDRAWAL_ROLE(), pledgeGuard);

        // Safe direct-use roles to the borrower.
        d.grantRole(d.FUND_ROLE(), borrower);
        d.grantRole(d.BURN_ROLE(), borrower);
        d.grantRole(d.REBALANCE_ROLE(), borrower);
        d.grantRole(d.PAUSE_BEACON_CHAIN_DEPOSITS_ROLE(), borrower);
        d.grantRole(d.RESUME_BEACON_CHAIN_DEPOSITS_ROLE(), borrower);

        // Step out: revoke DEFAULT_ADMIN_ROLE from this Factory.
        d.revokeRole(adminRole, address(this));
    }
}
