// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";

/// @notice Tests for `selfRedeem` - the borrower-controlled drain path that bypasses the
///         queues. This is what lets a healthy borrower wind down their own position.
contract SelfRedeemTest is BaseFork {
    address internal dashboard;
    address internal otherDashboard;
    address internal other;

    function setUp() public {
        _setUpFork();
        other = makeAddr("other");
        (dashboard,,) = _createAndFundVault(borrower, 100 ether);
        (otherDashboard,,) = _createAndFundVault(other, 100 ether);
    }

    // ============================================================================
    //                                   Happy path
    // ============================================================================

    function test_SelfRedeem_BorrowerDrainsOwnVault() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        uint256 wstBefore = wstETH.balanceOf(recipient);
        uint256 liabilityBefore = IDashboard(dashboard).liabilityShares();

        vm.prank(borrower);
        uint256 wstDelivered = adapter.selfRedeem(dashboard, shares, recipient);

        assertGt(wstDelivered, 0, "wstETH delivered");
        assertEq(
            wstETH.balanceOf(recipient), wstBefore + wstDelivered, "recipient received wstETH"
        );

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, 0, "pledge fully drained");

        uint256 liabilityAfter = IDashboard(dashboard).liabilityShares();
        assertApproxEqAbs(
            liabilityAfter - liabilityBefore, shares + 2, 1,
            "Lido vault liability grew by shares + buffer"
        );
    }

    function test_SelfRedeem_PartialDrain() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        vm.prank(borrower);
        adapter.selfRedeem(dashboard, shares / 2, recipient);

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, shares - shares / 2, "half remains");
    }

    function test_SelfRedeem_WorksWhenAllQueuesEmpty() public {
        // The whole point: no marking, no liquidation - borrower still can drain.
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        (uint256 liq, uint256 vol) = adapter.queueLengths();
        assertEq(liq, 0); assertEq(vol, 0, "no queues active");

        vm.prank(borrower);
        adapter.selfRedeem(dashboard, shares, recipient);

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, 0, "drained");
    }

    // ============================================================================
    //                                  Authorization
    // ============================================================================

    function test_SelfRedeem_RevertsForNonBorrower() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        // Borrower hands the vaultStETH to someone else.
        vm.prank(borrower);
        vaultStETH.transfer(unauthorised, shares);

        // The someone else cannot drain borrower's vault, even if they hold vaultStETH.
        vm.prank(unauthorised);
        vm.expectRevert(Adapter.NotBorrower.selector);
        adapter.selfRedeem(dashboard, shares, recipient);
    }

    function test_SelfRedeem_CannotDrainAnotherBorrowersVault() public {
        // borrower pledges into dashboard; other pledges into otherDashboard.
        uint256 capA = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 capB = IDashboard(otherDashboard).remainingMintingCapacityShares(0);

        vm.prank(borrower);
        adapter.pledge(dashboard, capA / 10);
        vm.prank(other);
        adapter.pledge(otherDashboard, capB / 10);

        // borrower has vaultStETH; tries to selfRedeem against OTHER's dashboard.
        vm.prank(borrower);
        vm.expectRevert(Adapter.NotBorrower.selector);
        adapter.selfRedeem(otherDashboard, capA / 10, recipient);
    }

    function test_SelfRedeem_RevertsForUnregisteredDashboard() public {
        vm.prank(borrower);
        vm.expectRevert(Adapter.NotRegistered.selector);
        adapter.selfRedeem(unauthorised, 1 ether, recipient);
    }

    function test_SelfRedeem_RevertsForZeroShares() public {
        vm.prank(borrower);
        vm.expectRevert(Adapter.ZeroShares.selector);
        adapter.selfRedeem(dashboard, 0, recipient);
    }

    function test_SelfRedeem_RevertsForZeroRecipient() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        vm.prank(borrower);
        adapter.pledge(dashboard, cap / 10);

        vm.prank(borrower);
        vm.expectRevert(Adapter.ZeroAddress.selector);
        adapter.selfRedeem(dashboard, cap / 10, address(0));
    }

    function test_SelfRedeem_RevertsBeyondPledge() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        vm.prank(borrower);
        vm.expectRevert(Adapter.InsufficientPledgedShares.selector);
        adapter.selfRedeem(dashboard, shares + 1, recipient);
    }

    // ============================================================================
    //                          Interaction with liquidation
    // ============================================================================

    /// @notice A self-redeeming borrower can still drain their OWN vault even if it has
    ///         been marked for liquidation. (In practice the liquidator races them, but
    ///         the code permits this so the borrower has a partial-cure path.)
    function test_SelfRedeem_WorksEvenIfOwnVaultIsLiquidating() public {
        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = cap / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        // Borrower drains their own vault first.
        vm.prank(borrower);
        adapter.selfRedeem(dashboard, shares / 2, recipient);

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, shares - shares / 2, "borrower drained half despite liquidation");
    }
}
