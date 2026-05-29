// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard} from "./BaseFork.t.sol";
import {PledgeGuard} from "../src/PledgeGuard.sol";
import {Adapter} from "../src/Adapter.sol";

/// @notice Regression suite for the late-mint double-spend.
///
///         BUG (pre-fix, proven on a mainnet fork): because `Adapter.pledge` mints no Lido
///         liability, `Dashboard.withdrawableValue()` was not reduced by a pledge, so
///         `PledgeGuard.withdraw` let a borrower pull the underlying stVault ETH out while
///         the vaultStETH it minted was still outstanding (e.g. supplied to AAVE). That
///         left the vaultStETH unbacked and created AAVE bad debt — a double-spend.
///
///         FIX: `PledgeGuard.withdraw` now enforces a pledge-backing floor — after any
///         withdrawal the vault must still be able to mint the pledged shares
///         (`remainingMintingCapacityShares(0) >= Adapter.pledgedSharesOf(dashboard)`).
///
///         These tests assert the lock now HOLDS: the double-spend withdrawal reverts, a
///         safe partial withdrawal succeeds, and once the pledge is unwound the full
///         balance becomes withdrawable again.
contract DoubleSpendRegression is BaseFork {
    address internal dashboard;
    address internal pledgeGuardAddr;
    PledgeGuard internal pg;

    function setUp() public {
        _setUpFork();
        (dashboard,, pledgeGuardAddr) = _createAndFundVault(borrower, 100 ether);
        pg = PledgeGuard(pledgeGuardAddr);
    }

    /// @notice The exploit attempt now REVERTS: a borrower who has pledged cannot withdraw
    ///         the full underlying ETH, because doing so would unback the pledge.
    function test_DoubleSpend_FullWithdrawWhilePledged_Reverts() public {
        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 2;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        // Pledge created no Lido liability (late-mint) — the property that made the bug possible.
        assertEq(IDashboard(dashboard).liabilityShares(), 0, "no liability minted on pledge");

        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();
        assertGt(withdrawable, 0, "vault reports withdrawable value");

        // Attempting to drain the full withdrawable amount must now revert: it would leave
        // capacity below the pledged shares (the unbacking the fix prevents).
        vm.prank(borrower);
        vm.expectRevert();
        pg.withdraw(recipient, withdrawable);
    }

    /// @notice A SAFE partial withdrawal (small relative to the headroom above the pledge)
    ///         still succeeds — the fix does not over-lock.
    function test_SafePartialWithdrawal_Succeeds() public {
        // Pledge only a small fraction so there is ample headroom to withdraw a bit.
        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 10;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        uint256 recipientBefore = recipient.balance;
        uint256 small = 1 ether; // far below the headroom above a 10%-of-capacity pledge

        vm.prank(borrower);
        pg.withdraw(recipient, small);

        assertEq(recipient.balance, recipientBefore + small, "safe partial withdrawal delivered");

        // Pledge still fully backed: capacity remains >= pledged.
        assertGe(
            IDashboard(dashboard).remainingMintingCapacityShares(0), pledged,
            "pledge still backed after safe withdrawal"
        );
    }

    /// @notice After the borrower unwinds the pledge (burns the vaultStETH via unpledge),
    ///         the full balance becomes withdrawable again — the lock releases correctly.
    function test_Unpledge_ReleasesTheLock() public {
        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 2;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        // Full withdraw blocked while pledged.
        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();
        vm.prank(borrower);
        vm.expectRevert();
        pg.withdraw(recipient, withdrawable);

        // Borrower unwinds: burns the vaultStETH, freeing the pledge.
        vm.prank(borrower);
        adapter.unpledge(dashboard, pledged);
        assertEq(adapter.pledgedSharesOf(dashboard), 0, "pledge cleared");

        // Now the full withdrawable amount is releasable.
        uint256 recipientBefore = recipient.balance;
        uint256 withdrawableNow = IDashboard(dashboard).withdrawableValue();
        vm.prank(borrower);
        pg.withdraw(recipient, withdrawableNow);
        assertEq(recipient.balance, recipientBefore + withdrawableNow, "full balance released");
    }

    /// @notice Redemption is now always honorable: after a (blocked) double-spend attempt,
    ///         the vault retains capacity, so selfRedeem succeeds and delivers wstETH.
    function test_RedemptionRemainsHonorable() public {
        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 4;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        // Try (and fail) to drain everything.
        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();
        vm.prank(borrower);
        vm.expectRevert();
        pg.withdraw(recipient, withdrawable);

        // The vaultStETH is still fully backed: the borrower can redeem it for real wstETH.
        vm.prank(borrower);
        uint256 wst = adapter.selfRedeem(dashboard, pledged, recipient);
        assertGt(wst, 0, "redemption honored - claim was backed");
    }

    /// @notice The pledge-backing floor view reflects the active pledge plus the mint buffer.
    function test_PledgeBackingFloorView() public {
        assertEq(pg.pledgeBackingFloorShares(), 0, "no pledge initially");

        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 3;
        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        assertEq(
            pg.pledgeBackingFloorShares(), pledged + adapter.MINT_BUFFER_SHARES(),
            "floor reflects pledge + mint buffer"
        );
    }

    /// @notice BOUNDARY test for the +2 mint-buffer fix. Withdraw the MAXIMUM the guard
    ///         permits (binary-searched to the exact floor), then assert that a FULL
    ///         single-call redemption of the entire pledge still succeeds. Without the
    ///         `+ MINT_BUFFER_SHARES` term in the floor, the redemption's `mintShares(P+2)`
    ///         would revert by the buffer at this exact boundary.
    function test_BufferFloor_FullRedemptionSucceedsAtMaxWithdrawal() public {
        uint256 capacityBefore = IDashboard(dashboard).remainingMintingCapacityShares(0);
        uint256 pledged = capacityBefore / 2;

        vm.prank(borrower);
        adapter.pledge(dashboard, pledged);

        uint256 withdrawable = IDashboard(dashboard).withdrawableValue();

        // Binary-search the largest withdrawal the guard accepts, using snapshots so each
        // trial doesn't mutate persistent state.
        uint256 lo = 0;
        uint256 hi = withdrawable;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(borrower);
            (bool ok,) = address(pg).call(
                abi.encodeWithSelector(PledgeGuard.withdraw.selector, recipient, mid)
            );
            vm.revertToState(snap);
            if (ok) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        // Perform the maximal permitted withdrawal for real.
        vm.prank(borrower);
        pg.withdraw(recipient, lo);

        // The vault is now at the pledge-backing floor. A FULL single-call redemption of
        // the entire pledge must still succeed (mintShares(pledged + buffer) fits).
        vm.prank(borrower);
        uint256 wst = adapter.selfRedeem(dashboard, pledged, recipient);
        assertGt(wst, 0, "full pledge redeemable at the exact floor (buffer reserved)");
    }
}
