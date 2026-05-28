// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard, IWstETH, IStETH} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";
import {VaultStETH} from "../src/VaultStETH.sol";

/// @notice End-to-end Adapter tests on a mainnet fork:
///         - Pledge issues vaultStETH 1:1 with reserved shares.
///         - Unpledge burns vaultStETH and reduces pledge.
///         - Redeem against real Lido vault produces real wstETH.
///         - Redemption queue priorities respected (liquidation > voluntary > FIFO).
contract AdapterTest is BaseFork {
    address internal dashboard;
    address internal pledgeGuard;

    function setUp() public {
        _setUpFork();
        // 100 ether of funded capacity (plus the 1 ether CONNECT_DEPOSIT separately).
        (dashboard,, pledgeGuard) = _createAndFundVault(borrower, 100 ether);
    }

    // ============================================================================
    //                                   Pledge
    // ============================================================================

    function test_Pledge_MintsVaultStETHOneToOne() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        assertGt(capacity, 0, "vault has mint capacity");

        // Pledge half the available capacity to be safe.
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

    // ============================================================================
    //                                  Unpledge
    // ============================================================================

    function test_Unpledge_BurnsVaultStETH() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 shares = capacity / 2;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        uint256 supplyAfterPledge = vaultStETH.totalSupply();

        // Unpledge half of what was pledged.
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

        // Anyone marks the vault for liquidation.
        adapter.markForLiquidation(dashboard);

        vm.prank(borrower);
        vm.expectRevert(Adapter.PledgeStillActive.selector);
        adapter.unpledge(dashboard, shares / 2);
    }

    // ============================================================================
    //                                  Redemption
    // ============================================================================

    function test_Redeem_DeliversRealWstEthFromRealLidoVault() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        // Use a modest share count so Lido's mint doesn't bump into vault limits.
        uint256 shares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, shares);

        // Liquidator buys/seizes vaultStETH. We simulate by directly transferring.
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, shares);

        uint256 liabilityBefore = IDashboard(dashboard).liabilityShares();
        uint256 wstBalBefore = wstETH.balanceOf(recipient);
        uint256 supplyBefore = vaultStETH.totalSupply();

        // Liquidator redeems for wstETH delivered to `recipient`.
        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(shares, recipient);

        assertGt(wstDelivered, 0, "wstETH delivered");
        assertEq(
            wstETH.balanceOf(recipient), wstBalBefore + wstDelivered, "recipient holds new wstETH"
        );
        assertEq(vaultStETH.balanceOf(liquidator), 0, "liquidator burned vaultStETH");
        assertEq(vaultStETH.totalSupply(), supplyBefore - shares, "supply reduced by shares");

        // The Lido vault's liability grew by approximately the minted shares + 2-wei buffer.
        uint256 liabilityAfter = IDashboard(dashboard).liabilityShares();
        uint256 minted = liabilityAfter - liabilityBefore;
        assertApproxEqAbs(minted, shares + 2, 1, "Lido minted ~= shares + 2 wei");
    }

    function test_Redeem_RevertsWhenAdapterQueueEmpty() public {
        vm.prank(liquidator);
        vm.expectRevert(Adapter.QueueEmpty.selector);
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

    // ============================================================================
    //                            Queue priorities
    // ============================================================================

    function test_QueuePriority_LiquidationBeforeGeneral() public {
        // Create a second vault for a second borrower; pledge from both.
        address borrower2 = makeAddr("borrower2");
        (address dashboard2,,) = _createAndFundVault(borrower2, 100 ether);

        uint256 cap1 = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 cap2 = IDashboard(dashboard2).remainingMintingCapacityShares(0);

        // Pledge from both.
        vm.prank(borrower);
        adapter.pledge(dashboard, cap1 / 4);

        vm.prank(borrower2);
        adapter.pledge(dashboard2, cap2 / 4);

        // Mark borrower2's vault for liquidation. It should drain FIRST regardless of FIFO.
        adapter.markForLiquidation(dashboard2);

        // nextDashboard() preview should return dashboard2.
        assertEq(adapter.nextDashboard(), dashboard2, "liquidated dashboard at head");

        // Redeem: should drain dashboard2, not dashboard.
        vm.prank(borrower2);  // borrower2 still holds vaultStETH; lets them redeem.
        adapter.redeem(cap2 / 8, recipient);

        (, uint128 pledgedAfter1,,) = adapter.pledges(dashboard);
        (, uint128 pledgedAfter2,,) = adapter.pledges(dashboard2);
        assertEq(pledgedAfter1, cap1 / 4, "dashboard1 untouched");
        assertEq(pledgedAfter2, cap2 / 4 - cap2 / 8, "dashboard2 drained");
    }

    function test_QueuePriority_VoluntaryBeforeGeneral() public {
        address borrower2 = makeAddr("borrower2");
        (address dashboard2,,) = _createAndFundVault(borrower2, 100 ether);

        uint256 cap1 = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 cap2 = IDashboard(dashboard2).remainingMintingCapacityShares(0);

        vm.prank(borrower);
        adapter.pledge(dashboard, cap1 / 4);

        vm.prank(borrower2);
        adapter.pledge(dashboard2, cap2 / 4);

        // borrower2 voluntarily marks their vault for close.
        vm.prank(borrower2);
        adapter.markForVoluntaryClose(dashboard2);

        // nextDashboard() should return dashboard2 (voluntary before general).
        assertEq(adapter.nextDashboard(), dashboard2, "voluntary head");

        vm.prank(borrower2);
        adapter.redeem(cap2 / 8, recipient);

        (, uint128 pledgedAfter1,,) = adapter.pledges(dashboard);
        (, uint128 pledgedAfter2,,) = adapter.pledges(dashboard2);
        assertEq(pledgedAfter1, cap1 / 4, "dashboard1 untouched");
        assertEq(pledgedAfter2, cap2 / 4 - cap2 / 8, "dashboard2 drained");
    }

    function test_QueuePriority_LiquidationBeatsVoluntary() public {
        address borrower2 = makeAddr("borrower2");
        address borrower3 = makeAddr("borrower3");
        (address dashboard2,,) = _createAndFundVault(borrower2, 100 ether);
        (address dashboard3,,) = _createAndFundVault(borrower3, 100 ether);

        uint256 cap1 = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 cap2 = IDashboard(dashboard2).remainingMintingCapacityShares(0);
        uint256 cap3 = IDashboard(dashboard3).remainingMintingCapacityShares(0);

        vm.prank(borrower);
        adapter.pledge(dashboard, cap1 / 4);
        vm.prank(borrower2);
        adapter.pledge(dashboard2, cap2 / 4);
        vm.prank(borrower3);
        adapter.pledge(dashboard3, cap3 / 4);

        // dashboard2 voluntary, dashboard3 liquidation.
        vm.prank(borrower2);
        adapter.markForVoluntaryClose(dashboard2);
        adapter.markForLiquidation(dashboard3);

        assertEq(adapter.nextDashboard(), dashboard3, "liquidation beats voluntary");
    }

    function test_QueueLengths_AdvanceCorrectly() public {
        (uint256 liq0, uint256 vol0, uint256 gen0) = adapter.queueLengths();
        assertEq(liq0, 0); assertEq(vol0, 0); assertEq(gen0, 0);

        uint256 cap = IDashboard(dashboard).remainingMintingCapacityShares(0);
        vm.prank(borrower);
        adapter.pledge(dashboard, cap / 4);

        (uint256 liq1, uint256 vol1, uint256 gen1) = adapter.queueLengths();
        assertEq(liq1, 0); assertEq(vol1, 0); assertEq(gen1, 1, "general grew");

        adapter.markForLiquidation(dashboard);
        (uint256 liq2, uint256 vol2, ) = adapter.queueLengths();
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

    function test_MarkForLiquidation_IsPermissionless() public {
        // Anyone can mark for liquidation (production hardens this with HF verification).
        vm.prank(unauthorised);
        adapter.markForLiquidation(dashboard);

        (,, uint8 bucket,) = adapter.pledges(dashboard);
        assertEq(bucket, 2, "bucket = liquidation");
    }

    function test_MarkForLiquidation_TwiceReverts() public {
        adapter.markForLiquidation(dashboard);
        vm.expectRevert(Adapter.AlreadyMarked.selector);
        adapter.markForLiquidation(dashboard);
    }
}
