// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard, IWstETH, IStETH} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";
import {VaultStETH} from "../src/VaultStETH.sol";

/// @notice End-to-end liquidation simulation under HF-gated semantics.
///
///         vaultStETH is not yet listed on AAVE Main Spoke (that's the future AIP), so the
///         on-chain AAVE seizure cannot be exercised here. We use:
///           * direct vaultStETH transfer to model the AAVE -> liquidator transfer
///           * MockAavePool to drive healthFactor
///
///         What's covered end-to-end against real Lido:
///           1. Borrower opens a stVault, pledges mint capacity, receives vaultStETH.
///           2. Borrower's HF on AAVE drops below 1e18.
///           3. Liquidator marks-for-liquidation, then redeems for real wstETH.
///           4. Atomic same-block; partial liquidation; fair-value receipt.
contract LiquidationTest is BaseFork {
    address internal dashboard;
    address internal pledgeGuard;

    function setUp() public {
        _setUpFork();
        (dashboard,, pledgeGuard) = _createAndFundVault(borrower, 100 ether);
    }

    /// @notice Full happy path: borrower pledges, becomes unhealthy, liquidator drains the
    ///         vault, real wstETH delivered.
    function test_E2E_PledgeBorrowSeizeRedeem_DeliversWstETHAtomically() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        assertEq(vaultStETH.balanceOf(borrower), pledgedShares, "borrower received vaultStETH");

        // Simulated AAVE liquidation transfer of vaultStETH.
        uint256 seizedShares = pledgedShares;
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);

        assertEq(vaultStETH.balanceOf(liquidator), seizedShares, "liquidator holds vaultStETH");

        // Borrower goes underwater on AAVE.
        _makeUnhealthy(borrower);

        // Anyone (the liquidator) marks: succeeds because HF < 1e18.
        vm.prank(liquidator);
        adapter.markForLiquidation(dashboard);
        assertEq(adapter.nextDashboard(), dashboard, "borrower's vault first in queue");

        uint256 wstBalBefore = wstETH.balanceOf(recipient);
        uint256 liabilityBefore = IDashboard(dashboard).liabilityShares();

        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(seizedShares, recipient);

        assertGt(wstDelivered, 0, "non-zero wstETH delivered");
        assertEq(
            wstETH.balanceOf(recipient),
            wstBalBefore + wstDelivered,
            "recipient's wstETH grew by exactly the delivered amount"
        );
        assertEq(vaultStETH.balanceOf(liquidator), 0, "liquidator's vaultStETH burnt");

        uint256 liabilityAfter = IDashboard(dashboard).liabilityShares();
        uint256 minted = liabilityAfter - liabilityBefore;
        assertApproxEqAbs(
            minted, seizedShares + 2, 1, "Lido vault's liability grew by shares + 2-wei buffer"
        );

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, 0, "borrower's pledge fully drained");
    }

    function test_E2E_PartialLiquidation_LeavesRemainingPledgeIntact() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        uint256 seizedShares = pledgedShares / 2;
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);

        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        vm.prank(liquidator);
        adapter.redeem(seizedShares, recipient);

        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, pledgedShares - seizedShares, "half the pledge remains");
    }

    function test_E2E_LiquidatorReceivesFairValueWstETH() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        uint256 seizedShares = pledgedShares;
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);
        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(seizedShares, recipient);

        uint256 expectedWstEth = wstETH.getWstETHByStETH(stETH.getPooledEthByShares(seizedShares));
        assertApproxEqRel(
            wstDelivered, expectedWstEth, 1e15,
            "wstETH delivered tracks Lido share-per-token rate"
        );
    }

    function test_E2E_AtomicSameBlockRedemption() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);
        _makeUnhealthy(borrower);
        adapter.markForLiquidation(dashboard);

        uint256 blockBefore = block.number;

        vm.startPrank(borrower);
        vaultStETH.transfer(liquidator, pledgedShares);
        vm.stopPrank();

        vm.prank(liquidator);
        adapter.redeem(pledgedShares, recipient);

        assertEq(block.number, blockBefore, "no block advance -- atomic");
        assertGt(wstETH.balanceOf(recipient), 0, "recipient holds wstETH");
    }

    function test_E2E_VoluntaryClose_BorrowerDrainsTheirOwnVault() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        vm.prank(borrower);
        adapter.markForVoluntaryClose(dashboard);

        uint256 toRedeem = pledgedShares / 2;
        vm.prank(borrower);
        uint256 wstDelivered = adapter.redeem(toRedeem, recipient);

        assertGt(wstDelivered, 0, "borrower received wstETH from voluntary close");
        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, pledgedShares - toRedeem, "pledge reduced");
    }
}
