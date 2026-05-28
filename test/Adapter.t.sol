// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard, IWstETH, IStETH} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";
import {VaultStETH} from "../src/VaultStETH.sol";

/// @notice End-to-end Adapter tests on a mainnet fork. Verifies pledge / unpledge /
///         markings / queue priority / view helpers under the new HF-gated semantics.
///         Redemption-against-marked-vault behavior is covered in HFGating and Liquidation
///         suites; self-redemption is covered in SelfRedeem.
contract AdapterTest is BaseFork {
    address internal dashboard;
    address internal pledgeGuard;

    function setUp() public {
        _setUpFork();
        (dashboard,, pledgeGuard) = _createAndFundVault(borrower, 100 ether);
    }

    // ============================================================================
    //                                   Pledge
    // ============================================================================

    function test_Pledge_MintsVaultStETHOneToOne() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        assertGt(capacity, 0, "vault has mint capacity");

        uint256 shares = capacity / 2;

        uint256 supplyBefore = vaultStETH.totalSupply();

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        assertEq(vaultStETH.balanceOf(borrower), shares, "borrower received vaultStETH");
        assertEq(vaultStETH.totalSupply(), supplyBefore + shares, "supply grew");

        (, uint128 pledgedShares,, ) = adapter.pledges(dashboard);
        assertEq(pledgedShares, shares, "pledge recorded");
    }

    function test_Pledge_RevertsForUnregisteredDashboard() public {
        vm.prank(borrower);
        vm.expectRevert(Adapter.NotRegistered.selector);
        adapter.pledge(unauthorised, 1 ether);
    }

    function test_Pledge_RevertsForNonBorrower() public {
        vm.prank(unauthorised);
        vm.expectRevert(Adapter.NotBorrower.selector);
        adapter.pledge(dashboard, 1 ether);
    }

    function test_Pledge_RevertsForExcessiveShares() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);

        vm.prank(borrower);
        vm.expectRevert(Adapter.InsufficientMintCapacity.selector);
        adapter.pledge(dashboard, capacity + 1 ether);
    }

    function test_Pledge_RevertsForZeroShares() public {
        vm.prank(borrower);
        vm.expectRevert(Adapter.ZeroShares.selector);
        adapter.pledge(dashboard, 0);
    }

    // ============================================================================
    //                                  Unpledge
    // ============================================================================

    function test_Unpledge_BurnsVaultStETH() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = capacity / 2;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        uint256 supplyAfterPledge = vaultStETH.totalSupply();

        uint256 toUnpledge = shares / 2;
        vm.prank(borrower);
        adapter.unpledge(dashboard, toUnpledge);

        assertEq(
            vaultStETH.balanceOf(borrower), shares - toUnpledge, "borrower balance reduced"
        );
        assertEq(vaultStETH.totalSupply(), supplyAfterPledge - toUnpledge, "supply reduced");

        (, uint128 pledgedShares,, ) = adapter.pledges(dashboard);
        assertEq(pledgedShares, shares - toUnpledge, "pledge reduced");
    }

    function test_Unpledge_RevertsBeyondPledge() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = capacity / 4;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        vm.prank(borrower);
        vm.expectRevert(Adapter.InsufficientPledgedShares.selector);
        adapter.unpledge(dashboard, shares + 1 ether);
    }

    function test_Unpledge_BlockedDuringLiquidation() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = capacity / 4;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        // Make borrower unhealthy, then mark for liquidation.
        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        vm.prank(borrower);
        vm.expectRevert(Adapter.PledgeStillActive.selector);
        adapter.unpledge(dashboard, shares / 2);
    }

    function test_Unpledge_RevertsForNonBorrower() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        vm.prank(borrower);
        adapter.pledge(dashboard, capacity / 4);

        vm.prank(unauthorised);
        vm.expectRevert(Adapter.NotBorrower.selector);
        adapter.unpledge(dashboard, 1 ether);
    }

    // ============================================================================
    //                           Redemption against marked vault
    // ============================================================================

    function test_Redeem_DeliversRealWstEthFromRealLidoVault_WhenBorrowerUnhealthy() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        // Liquidator buys/seizes vaultStETH (simulated by transfer).
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, shares);

        // Borrower's HF drops below 1 on AAVE.
        _makeUnhealthy(borrower);

        // Liquidator marks (anyone can; HF must be < 1e18).
        vm.prank(liquidator);
        adapter.markForLiquidation(dashboard);

        uint256 liabilityBefore = IDashboard(dashboard).liabilityShares();
        uint256 wstBalBefore = wstETH.balanceOf(recipient);
        uint256 supplyBefore = vaultStETH.totalSupply();

        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(shares, recipient);

        assertGt(wstDelivered, 0, "wstETH delivered");
        assertEq(
            wstETH.balanceOf(recipient), wstBalBefore + wstDelivered, "recipient holds new wstETH"
        );
        assertEq(vaultStETH.balanceOf(liquidator), 0, "liquidator burned vaultStETH");
        assertEq(vaultStETH.totalSupply(), supplyBefore - shares, "supply reduced by shares");

        uint256 liabilityAfter = IDashboard(dashboard).liabilityShares();
        uint256 minted = liabilityAfter - liabilityBefore;
        assertApproxEqAbs(minted, shares + 2, 1, "Lido minted ~= shares + 2 wei");
    }

    function test_Redeem_RevertsWhenNothingMarked() public {
        // Borrower pledges but nobody marks; healthy borrower => no eligible dashboards.
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        vm.prank(borrower);
        adapter.pledge(dashboard, capacity / 4);

        vm.prank(borrower);
        vaultStETH.transfer(liquidator, capacity / 4);

        vm.prank(liquidator);
        vm.expectRevert(Adapter.NoEligibleDashboard.selector);
        adapter.redeem(capacity / 8, recipient);
    }

    function test_Redeem_RevertsWhenAdapterQueueEmpty() public {
        // No pledges anywhere.
        vm.prank(liquidator);
        vm.expectRevert(Adapter.NoEligibleDashboard.selector);
        adapter.redeem(1 ether, recipient);
    }

    function test_Redeem_RevertsForZeroRecipient() public {
        uint256 shares = 1 ether;
        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        vm.prank(borrower);
        vm.expectRevert(Adapter.ZeroAddress.selector);
        adapter.redeem(shares, address(0));
    }

    function test_Redeem_RevertsForZeroShares() public {
        vm.prank(borrower);
        vm.expectRevert(Adapter.ZeroShares.selector);
        adapter.redeem(0, recipient);
    }

    // ============================================================================
    //                            Queue priorities
    // ============================================================================

    function test_QueuePriority_LiquidationBeforeVoluntary() public {
        // Create a second vault for a second borrower; pledge from both.
        address borrower2 = makeAddr("borrower2");
        (address dashboard2,,) = _createAndFundVault(borrower2, 100 ether);

        uint256 cap1 = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 cap2 = IDashboard(dashboard2).remainingMintingCapacityShares(0);

        vm.prank(borrower);
        adapter.pledge(dashboard, cap1 / 4);

        vm.prank(borrower2);
        adapter.pledge(dashboard2, cap2 / 4);

        // borrower marks themselves voluntary; borrower2 goes unhealthy and gets marked
        // for liquidation. Liquidation should beat voluntary.
        vm.prank(borrower);
        adapter.markForVoluntaryClose(dashboard);

        _makeUnhealthy(borrower2);
        adapter.markForLiquidation(dashboard2);

        assertEq(adapter.nextDashboard(), dashboard2, "liquidation beats voluntary");
    }

    function test_QueueLengths_AdvanceCorrectly() public {
        (uint256 liq0, uint256 vol0) = adapter.queueLengths();
        assertEq(liq0, 0); assertEq(vol0, 0);

        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        vm.prank(borrower);
        adapter.pledge(dashboard, cap / 4);

        // After pledge: no entries in any queue (general FIFO removed).
        (uint256 liq1, uint256 vol1) = adapter.queueLengths();
        assertEq(liq1, 0); assertEq(vol1, 0, "no queue entries before marking");

        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        (uint256 liq2, uint256 vol2) = adapter.queueLengths();
        assertEq(liq2, 1, "liquidation grew"); assertEq(vol2, 0);
    }

    // ============================================================================
    //                            Marking restrictions
    // ============================================================================

    function test_MarkForVoluntaryClose_OnlyBorrower() public {
        vm.prank(unauthorised);
        vm.expectRevert(Adapter.NotBorrower.selector);
        adapter.markForVoluntaryClose(dashboard);
    }

    function test_MarkForLiquidation_RevertsWhenBorrowerHealthy() public {
        // borrower is healthy by default (mock HF = max).
        vm.prank(unauthorised);
        vm.expectRevert(
            abi.encodeWithSelector(Adapter.BorrowerHealthy.selector, type(uint256).max)
        );
        adapter.markForLiquidation(dashboard);
    }

    function test_MarkForLiquidation_RevertsAtExactlyOne() public {
        _setHF(borrower, 1e18); // exactly at threshold (NOT below)
        vm.expectRevert(abi.encodeWithSelector(Adapter.BorrowerHealthy.selector, 1e18));
        adapter.markForLiquidation(dashboard);
    }

    function test_MarkForLiquidation_SucceedsJustBelowThreshold() public {
        _setHF(borrower, 1e18 - 1);
        adapter.markForLiquidation(dashboard);
        (,, uint8 bucket,) = adapter.pledges(dashboard);
        assertEq(bucket, 2, "marked for liquidation");
    }

    function test_MarkForLiquidation_TwiceReverts() public {
        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);
        vm.expectRevert(Adapter.AlreadyMarked.selector);
        adapter.markForLiquidation(dashboard);
    }
}
