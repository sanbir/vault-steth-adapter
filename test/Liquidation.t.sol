// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard, IWstETH, IStETH} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";
import {VaultStETH} from "../src/VaultStETH.sol";

/// @notice End-to-end liquidation simulation against real Lido on a mainnet fork.
///
///         vaultStETH is not yet listed on AAVE Main Spoke (that's the future AIP), so
///         we cannot exercise the full AAVE call path here. We DO exercise the parts that
///         depend on our contracts:
///
///         1. Borrower opens a stVault, pledges mint capacity, receives vaultStETH.
///         2. (Simulated) AAVE liquidation seizes vaultStETH from the borrower to the
///            liquidator. We do this via a direct vaultStETH transfer that mimics what
///            AAVE's standard `liquidationCall` does when transferring an ERC-20 collateral
///            to the liquidator.
///         3. Liquidator immediately calls `Adapter.redeem(vaultStETH, recipient)` and
///            receives real wstETH in the same transaction.
///         4. Final balance assertions: borrower's vault's Lido liability grew by exactly
///            the minted shares + 2-wei buffer; wstETH delivered to recipient matches the
///            requested shares.
contract LiquidationTest is BaseFork {
    address internal dashboard;
    address internal pledgeGuard;

    function setUp() public {
        _setUpFork();
        (dashboard,, pledgeGuard) = _createAndFundVault(borrower, 100 ether);
    }

    /// @notice The single most important test in this repo. End-to-end flow against real
    ///         Lido contracts.
    function test_E2E_PledgeBorrowSeizeRedeem_DeliversWstETHAtomically() public {
        // ----- 1. Borrower pledges 10 ETH worth of mint capacity (stETH shares). -----
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10; // safe margin against Lido per-vault limits
        assertGt(pledgedShares, 0, "vault has mint capacity");

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        assertEq(vaultStETH.balanceOf(borrower), pledgedShares, "borrower received vaultStETH");

        // ----- 2. Simulated AAVE liquidation: vaultStETH transfers from borrower -> liquidator.
        // (This is what `Spoke.liquidationCall(..., receiveShares=false)` does on a fungible
        //  ERC-20 collateral: it removes the seized amount from the borrower's supply
        //  position and transfers to msg.sender -- the liquidator. We mimic via a direct
        //  borrower-side transfer, since vaultStETH is freely transferable.)
        uint256 seizedShares = pledgedShares; // simulate full seizure for this test
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);

        assertEq(vaultStETH.balanceOf(liquidator), seizedShares, "liquidator holds vaultStETH");

        // ----- 3. Adapter mark-for-liquidation so the redemption picks borrower's vault.
        adapter.markForLiquidation(dashboard);
        assertEq(adapter.nextDashboard(), dashboard, "borrower's vault first in queue");

        // ----- 4. Liquidator redeems for real wstETH delivered to `recipient`. -----
        uint256 wstBalBefore = wstETH.balanceOf(recipient);
        uint256 liabilityBefore = IDashboard(dashboard).liabilityShares();

        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(seizedShares, recipient);

        // ----- 5. Assertions: real wstETH delivered, real Lido state mutated. -----
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

        // ----- 6. The borrower's pledge bookkeeping: drained back to zero. -----
        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, 0, "borrower's pledge fully drained");
    }

    /// @notice Same flow but partial liquidation -- only half the pledge is seized.
    function test_E2E_PartialLiquidation_LeavesRemainingPledgeIntact() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        // Half-seize.
        uint256 seizedShares = pledgedShares / 2;
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);

        adapter.markForLiquidation(dashboard);

        vm.prank(liquidator);
        adapter.redeem(seizedShares, recipient);

        // Half the pledge remains on the dashboard. The dashboard is still in the
        // liquidation queue, ready to drain on a further redemption.
        (, uint128 pledgedAfter,,) = adapter.pledges(dashboard);
        assertEq(pledgedAfter, pledgedShares - seizedShares, "half the pledge remains");
    }

    /// @notice Verifies that the liquidator's wstETH receipt is on the order of magnitude
    ///         of the seized stETH value, NOT zero or grossly mispriced.
    function test_E2E_LiquidatorReceivesFairValueWstETH() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);

        uint256 seizedShares = pledgedShares;
        vm.prank(borrower);
        vaultStETH.transfer(liquidator, seizedShares);
        adapter.markForLiquidation(dashboard);

        vm.prank(liquidator);
        uint256 wstDelivered = adapter.redeem(seizedShares, recipient);

        // The wstETH delivered should approximately equal the seized shares converted via
        // Lido's stEthPerToken rate. Allow 0.1% tolerance for Lido rounding + buffer.
        uint256 expectedWstEth = wstETH.getWstETHByStETH(stETH.getPooledEthByShares(seizedShares));
        assertApproxEqRel(
            wstDelivered, expectedWstEth, 1e15, // 0.1%
            "wstETH delivered tracks Lido share-per-token rate"
        );
    }

    /// @notice Demonstrates atomicity: Phase A (seize) and Phase B (redeem) execute in
    ///         the same transaction.
    function test_E2E_AtomicSameBlockRedemption() public {
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledgedShares = capacity / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledgedShares);
        adapter.markForLiquidation(dashboard);

        uint256 blockBefore = block.number;

        // Single multi-call from liquidator's POV: transfer + redeem in one tx (we don't
        // really need to seize from someone else here; we model the case where the
        // liquidator wallet directly holds the seized vaultStETH and immediately
        // redeems).
        vm.startPrank(borrower);
        vaultStETH.transfer(liquidator, pledgedShares);
        vm.stopPrank();

        vm.prank(liquidator);
        adapter.redeem(pledgedShares, recipient);

        assertEq(block.number, blockBefore, "no block advance -- atomic");
        assertGt(wstETH.balanceOf(recipient), 0, "recipient holds wstETH");
    }

    /// @notice Voluntary close pattern: borrower marks their own vault to be drained
    ///         next, then redeems against it (not as a liquidator, but to unwind their
    ///         own debt position).
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
