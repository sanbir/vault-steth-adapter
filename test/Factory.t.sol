// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard, IStakingVault, IVaultHub} from "./BaseFork.t.sol";
import {PledgeGuard} from "../src/PledgeGuard.sol";
import {Adapter} from "../src/Adapter.sol";

/// @notice Atomic-deployment tests against real Lido V3 VaultFactory on a mainnet fork.
///         These run the FULL flow: a borrower (test EOA) calls our StVaultFactory, which
///         creates a real Lido stVault, a real Dashboard, deploys a PledgeGuard, wires
///         every role, and registers the dashboard with the Adapter.
contract FactoryTest is BaseFork {
    function setUp() public {
        _setUpFork();
    }

    function test_AtomicDeploy_AllArtifactsCreated() public {
        (address dashboard, address stakingVault, address pledgeGuard) =
            _createAndFundVault(borrower, 0);

        // Lido recognises the staking vault.
        assertTrue(lidoFactory.deployedVaults(stakingVault), "Lido knows the staking vault");

        // Sanity: the dashboard reports a sensible immutable wiring back to Lido.
        IDashboard d = IDashboard(dashboard);
        assertEq(address(d.VAULT_HUB()), address(vaultHub), "dashboard points at real VaultHub");
        assertEq(d.STETH(), address(stETH), "dashboard points at real stETH");
        assertEq(d.WSTETH(), address(wstETH), "dashboard points at real wstETH");
        assertEq(address(d.stakingVault()), stakingVault, "dashboard -> stakingVault");

        // Our pledgeGuard was deployed and is bound to this dashboard.
        PledgeGuard pg = PledgeGuard(pledgeGuard);
        assertEq(address(pg.DASHBOARD()), dashboard, "pledgeGuard -> dashboard");
        assertEq(pg.ADAPTER(), address(adapter), "pledgeGuard -> adapter");
        assertEq(pg.owner(), borrower, "pledgeGuard owned by borrower");
    }

    function test_AtomicDeploy_RoleGraphCorrect() public {
        (address dashboard,, address pledgeGuard) = _createAndFundVault(borrower, 0);
        IDashboard d = IDashboard(dashboard);

        // DEFAULT_ADMIN_ROLE → only the PledgeGuard. The Factory revoked itself.
        bytes32 adminRole = d.DEFAULT_ADMIN_ROLE();
        assertTrue(d.hasRole(adminRole, pledgeGuard), "PledgeGuard holds DEFAULT_ADMIN_ROLE");
        assertFalse(d.hasRole(adminRole, address(factory)), "Factory stepped out");

        // MINT_ROLE → only the Adapter.
        assertTrue(d.hasRole(d.MINT_ROLE(), address(adapter)), "Adapter holds MINT_ROLE");
        assertFalse(d.hasRole(d.MINT_ROLE(), borrower), "borrower has no MINT_ROLE");

        // Pledge-affecting roles → PledgeGuard.
        assertTrue(d.hasRole(d.WITHDRAW_ROLE(), pledgeGuard), "WITHDRAW_ROLE on guard");
        assertTrue(
            d.hasRole(d.VOLUNTARY_DISCONNECT_ROLE(), pledgeGuard), "VOLUNTARY_DISCONNECT_ROLE on guard"
        );
        assertTrue(
            d.hasRole(d.VAULT_CONFIGURATION_ROLE(), pledgeGuard), "VAULT_CONFIGURATION_ROLE on guard"
        );
        assertTrue(
            d.hasRole(d.REQUEST_VALIDATOR_EXIT_ROLE(), pledgeGuard),
            "REQUEST_VALIDATOR_EXIT_ROLE on guard"
        );
        assertTrue(
            d.hasRole(d.TRIGGER_VALIDATOR_WITHDRAWAL_ROLE(), pledgeGuard),
            "TRIGGER_VALIDATOR_WITHDRAWAL_ROLE on guard"
        );

        // Safe direct-use roles → borrower.
        assertTrue(d.hasRole(d.FUND_ROLE(), borrower), "FUND_ROLE on borrower");
        assertTrue(d.hasRole(d.BURN_ROLE(), borrower), "BURN_ROLE on borrower");
        assertTrue(d.hasRole(d.REBALANCE_ROLE(), borrower), "REBALANCE_ROLE on borrower");
        assertTrue(
            d.hasRole(d.PAUSE_BEACON_CHAIN_DEPOSITS_ROLE(), borrower),
            "PAUSE_BEACON_CHAIN_DEPOSITS_ROLE on borrower"
        );
        assertTrue(
            d.hasRole(d.RESUME_BEACON_CHAIN_DEPOSITS_ROLE(), borrower),
            "RESUME_BEACON_CHAIN_DEPOSITS_ROLE on borrower"
        );

        // Borrower never received DEFAULT_ADMIN_ROLE.
        assertFalse(d.hasRole(adminRole, borrower), "borrower has no admin");
    }

    function test_AtomicDeploy_AdapterRegistered() public {
        (address dashboard,,) = _createAndFundVault(borrower, 0);

        (address borrowerStored, uint128 pledged, uint8 bucket, bool registered) =
            adapter.pledges(dashboard);
        assertTrue(registered, "dashboard registered with adapter");
        assertEq(borrowerStored, borrower, "borrower recorded");
        assertEq(pledged, 0, "no pledge yet");
        assertEq(bucket, 0, "bucket = general");
    }

    function test_FundingTheVault_IncreasesTotalValue() public {
        (address dashboard,,) = _createAndFundVault(borrower, 5 ether);
        IDashboard d = IDashboard(dashboard);

        // After funding, the dashboard reports nonzero totalValue. (The exact value
        // includes the CONNECT_DEPOSIT, so it's at least 5 ether + small leftover.)
        assertGe(d.totalValue(), 5 ether, "totalValue includes our fund");
    }

    function test_MultipleBorrowers_GetDistinctVaults() public {
        address borrower2 = makeAddr("borrower2");

        (address d1,, address pg1) = _createAndFundVault(borrower, 0);
        (address d2,, address pg2) = _createAndFundVault(borrower2, 0);

        assertNotEq(d1, d2, "distinct dashboards");
        assertNotEq(pg1, pg2, "distinct guards");

        assertEq(PledgeGuard(pg1).owner(), borrower, "pg1 -> borrower");
        assertEq(PledgeGuard(pg2).owner(), borrower2, "pg2 -> borrower2");
    }

    function test_Reverts_InsufficientConnectDeposit() public {
        // Send LESS than CONNECT_DEPOSIT.
        uint256 connectDeposit = vaultHub.CONNECT_DEPOSIT();
        vm.deal(borrower, connectDeposit);

        vm.prank(borrower);
        // Lido's VaultFactory enforces the connect-deposit amount. Sending less reverts.
        vm.expectRevert();
        factory.createBorrowerVault{value: connectDeposit - 1}(
            borrower, nodeOperator, NODE_OPERATOR_FEE_BP, CONFIRM_EXPIRY
        );
    }

    function test_Reverts_ZeroBorrower() public {
        uint256 connectDeposit = vaultHub.CONNECT_DEPOSIT();
        vm.deal(address(this), connectDeposit);

        vm.expectRevert();
        factory.createBorrowerVault{value: connectDeposit}(
            address(0), nodeOperator, NODE_OPERATOR_FEE_BP, CONFIRM_EXPIRY
        );
    }
}
