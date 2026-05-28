// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard} from "./BaseFork.t.sol";
import {PledgeGuard} from "../src/PledgeGuard.sol";

/// @notice PledgeGuard semantics on a mainnet fork. We exercise:
///         - Owner-gated pass-throughs (withdraw, beacon-deposit pause/resume).
///         - Explicit blocks (validator exit, voluntary disconnect, ownership transfer).
///         - Withdraw is bounded by the dashboard's actual withdrawableValue.
///         - Non-owners cannot drive the guard.
contract PledgeGuardTest is BaseFork {
    address internal dashboard;
    address internal pledgeGuardAddr;
    PledgeGuard internal pg;

    function setUp() public {
        _setUpFork();
        (dashboard,, pledgeGuardAddr) = _createAndFundVault(borrower, 0);
        pg = PledgeGuard(pledgeGuardAddr);
    }

    // ============================================================================
    //                              Pass-through actions
    // ============================================================================

    function test_BorrowerCanPauseAndResumeBeaconDeposits() public {
        // Borrower holds PAUSE/RESUME roles DIRECTLY on the dashboard (granted by the
        // Factory). They can pause / resume without going through the guard.
        vm.prank(borrower);
        IDashboard(dashboard).pauseBeaconChainDeposits();

        vm.prank(borrower);
        IDashboard(dashboard).resumeBeaconChainDeposits();
        // Done; no revert expected.
    }

    function test_GuardPauseForwarder_OnlyOwnerCanInvoke() public {
        // Non-owners cannot drive the guard's forwarder.
        vm.prank(unauthorised);
        vm.expectRevert();
        pg.pauseBeaconChainDeposits();
    }

    function test_BorrowerCanWithdrawUpToWithdrawable() public {
        // Fund the vault first so there's withdrawable ETH.
        vm.deal(borrower, 10 ether);
        vm.prank(borrower);
        IDashboard(dashboard).fund{value: 10 ether}();

        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();
        assertGt(withdrawable, 0, "vault has withdrawable funds");

        uint256 toTake = withdrawable / 2;
        uint256 recipientBalBefore = recipient.balance;

        vm.prank(borrower);
        pg.withdraw(recipient, toTake);

        assertEq(recipient.balance, recipientBalBefore + toTake, "recipient received funds");
    }

    function test_Withdraw_RevertsIfExceedsWithdrawable() public {
        // Fund the vault.
        vm.deal(borrower, 5 ether);
        vm.prank(borrower);
        IDashboard(dashboard).fund{value: 5 ether}();

        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();

        vm.prank(borrower);
        vm.expectRevert(PledgeGuard.ExceedsWithdrawable.selector);
        pg.withdraw(recipient, withdrawable + 1 ether);
    }

    function test_Withdraw_RevertsForNonOwner() public {
        vm.prank(unauthorised);
        vm.expectRevert();
        pg.withdraw(unauthorised, 1 ether);
    }

    // ============================================================================
    //                              Blocked actions
    // ============================================================================
    // These DO exist as functions on the guard for clarity, but all of them revert.
    // The borrower must NOT have a path to:
    //   - request validator exit while pledged
    //   - voluntarily disconnect from VaultHub
    //   - transfer dashboard ownership away

    function test_RequestValidatorExit_AlwaysReverts() public {
        bytes memory pubkeys = hex"01020304";
        vm.prank(borrower);
        vm.expectRevert(PledgeGuard.PledgeStillActive.selector);
        pg.requestValidatorExit(pubkeys);
    }

    function test_VoluntaryDisconnect_AlwaysReverts() public {
        vm.prank(borrower);
        vm.expectRevert(PledgeGuard.PledgeStillActive.selector);
        pg.voluntaryDisconnect();
    }

    function test_TransferVaultOwnership_AlwaysReverts() public {
        vm.prank(borrower);
        vm.expectRevert(PledgeGuard.PledgeStillActive.selector);
        pg.transferVaultOwnership(unauthorised);
    }

    // ============================================================================
    //                              Borrower-direct dashboard actions
    // ============================================================================

    function test_BorrowerCanFundDashboardDirectly() public {
        // The FUND_ROLE is on the borrower, NOT on the guard. So funding goes directly.
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        IDashboard(dashboard).fund{value: 1 ether}();
        assertGe(IDashboard(dashboard).totalValue(), 1 ether, "fund applied");
    }

    function test_BorrowerCannotCallDashboardWithdrawDirectly() public {
        // The WITHDRAW_ROLE is on the GUARD only. Borrower hitting Dashboard.withdraw
        // directly must revert.
        vm.deal(borrower, 2 ether);
        vm.prank(borrower);
        IDashboard(dashboard).fund{value: 2 ether}();

        vm.prank(borrower);
        vm.expectRevert();
        IDashboard(dashboard).withdraw(borrower, 1 ether);
    }

    function test_BorrowerCannotRequestValidatorExitDirectly() public {
        bytes memory pubkeys = hex"01020304";
        vm.prank(borrower);
        vm.expectRevert();
        IDashboard(dashboard).requestValidatorExit(pubkeys);
    }

    function test_BorrowerCannotDisconnectDirectly() public {
        vm.prank(borrower);
        vm.expectRevert();
        IDashboard(dashboard).voluntaryDisconnect();
    }

    // ============================================================================
    //                              Ownership transfer
    // ============================================================================

    function test_Ownable2Step_BorrowerCanInitiateOwnerTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(borrower);
        pg.transferOwnership(newOwner);

        // Two-step: pending owner set, but borrower still owns.
        assertEq(pg.pendingOwner(), newOwner, "pending owner set");
        assertEq(pg.owner(), borrower, "owner unchanged before accept");

        // New owner accepts.
        vm.prank(newOwner);
        pg.acceptOwnership();

        assertEq(pg.owner(), newOwner, "new owner");
        assertEq(pg.pendingOwner(), address(0), "pending cleared");
    }

    function test_OwnershipTransfer_OnlyByCurrentOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(unauthorised);
        vm.expectRevert();
        pg.transferOwnership(newOwner);
    }
}
