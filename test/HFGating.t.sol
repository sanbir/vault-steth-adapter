// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseFork, IDashboard} from "./BaseFork.t.sol";
import {Adapter} from "../src/Adapter.sol";

/// @notice Tests dedicated to the production invariant: a healthy borrower's vault can
///         never be drained by an external call, no matter who holds vaultStETH.
contract HFGatingTest is BaseFork {
    address internal aliceDashboard;
    address internal bobDashboard;
    address internal carolDashboard;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal attacker;

    function setUp() public {
        _setUpFork();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        attacker = makeAddr("attacker");

        (aliceDashboard,,) = _createAndFundVault(alice, 100 ether);
        (bobDashboard,,) = _createAndFundVault(bob, 100 ether);
        (carolDashboard,,) = _createAndFundVault(carol, 100 ether);
    }

    // ============================================================================
    //                        Core invariant: healthy => never drained
    // ============================================================================

    /// @notice The original attack: Bob is in liquidation, attacker holds vaultStETH from
    ///         the secondary market, attempts to drain Alice (queue-head FIFO under the
    ///         OLD design). Under the new design, redeem reverts unless something marked.
    function test_Invariant_HealthyAliceNeverDrainedWhenBobIsLiquidating() public {
        uint256 capA = IDashboard(aliceDashboard).remainingMintingCapacityShares(0);
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);

        vm.prank(alice);
        adapter.pledge(aliceDashboard, capA / 10);
        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);

        // Attacker somehow has Bob's vaultStETH (secondary market / seized).
        vm.prank(bob);
        vaultStETH.transfer(attacker, capB / 10);

        // Bob's HF on AAVE drops. Alice stays healthy.
        _makeUnhealthy(bob);
        // Alice's HF unset = default healthy (type(uint256).max).

        // Attacker marks Bob (legitimately - Bob IS in liquidation).
        adapter.markForLiquidation(bobDashboard);

        (, uint128 alicePledgedBefore,,) = adapter.pledges(aliceDashboard);
        (, uint128 bobPledgedBefore,,) = adapter.pledges(bobDashboard);

        // Attacker redeems. Bob is queue-head, Alice never even considered.
        vm.prank(attacker);
        adapter.redeem(capB / 10, recipient);

        (, uint128 alicePledgedAfter,,) = adapter.pledges(aliceDashboard);
        (, uint128 bobPledgedAfter,,) = adapter.pledges(bobDashboard);

        assertEq(alicePledgedAfter, alicePledgedBefore, "Alice (healthy) untouched");
        assertEq(
            bobPledgedAfter, bobPledgedBefore - uint128(capB / 10), "Bob (unhealthy) drained"
        );
    }

    /// @notice Attacker tries to drain Alice when NOBODY is in liquidation. Should revert.
    function test_Invariant_RedeemRevertsWhenAllBorrowersHealthy() public {
        uint256 capA = IDashboard(aliceDashboard).remainingMintingCapacityShares(0);
        vm.prank(alice);
        adapter.pledge(aliceDashboard, capA / 10);

        vm.prank(alice);
        vaultStETH.transfer(attacker, capA / 10);

        // Nobody marked, nobody unhealthy.
        vm.prank(attacker);
        vm.expectRevert(Adapter.NoEligibleDashboard.selector);
        adapter.redeem(capA / 10, recipient);
    }

    /// @notice An attacker cannot mark a healthy borrower's dashboard for liquidation.
    function test_Invariant_CannotMarkHealthyDashboardForLiquidation() public {
        // Alice is default-healthy.
        vm.expectRevert(
            abi.encodeWithSelector(Adapter.BorrowerHealthy.selector, type(uint256).max)
        );
        adapter.markForLiquidation(aliceDashboard);
    }

    /// @notice Marking succeeds only when HF is strictly less than 1e18.
    function test_Invariant_MarkBoundaryBehavior() public {
        _setHF(alice, 1e18);
        vm.expectRevert(abi.encodeWithSelector(Adapter.BorrowerHealthy.selector, 1e18));
        adapter.markForLiquidation(aliceDashboard);

        _setHF(alice, 1e18 - 1);
        adapter.markForLiquidation(aliceDashboard);
        (,, uint8 bucket,) = adapter.pledges(aliceDashboard);
        assertEq(bucket, 2, "marked at hf=1e18-1");
    }

    // ============================================================================
    //                        Re-verification at selection time
    // ============================================================================

    /// @notice Borrower's HF recovers between marking and redemption. After cleanup, the
    ///         dashboard is demoted; subsequent redemption finds no eligible dashboard.
    function test_Invariant_RecoveredBorrowerDemotedAtSelection() public {
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);
        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);

        vm.prank(bob);
        vaultStETH.transfer(attacker, capB / 10);

        _makeUnhealthy(bob);
        adapter.markForLiquidation(bobDashboard);

        // Bob recovers between marking and redemption (e.g., AAVE deposit).
        _makeHealthy(bob);

        // Permissionless cleanup persists the demotion.
        uint256 demoted = adapter.cleanupLiquidationQueue(10);
        assertEq(demoted, 1, "one borrower demoted");

        // After cleanup, Bob's dashboard has been DEMOTED.
        (,, uint8 bucket,) = adapter.pledges(bobDashboard);
        assertEq(bucket, 0, "Bob demoted by cleanup");

        // Subsequent redemption finds no eligible dashboard.
        vm.prank(attacker);
        vm.expectRevert(Adapter.NoEligibleDashboard.selector);
        adapter.redeem(capB / 10, recipient);
    }

    /// @notice Same scenario, but using redeem directly. Demotion is rolled back when
    ///         redeem reverts (this is expected Solidity behavior); production code
    ///         relies on `cleanupLiquidationQueue` to persist demotions.
    function test_Invariant_RedeemRevertsWithoutPersistingDemotion() public {
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);
        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);

        vm.prank(bob);
        vaultStETH.transfer(attacker, capB / 10);

        _makeUnhealthy(bob);
        adapter.markForLiquidation(bobDashboard);
        _makeHealthy(bob);

        // redeem reverts; the inline demotion is rolled back along with the revert.
        vm.prank(attacker);
        vm.expectRevert(Adapter.NoEligibleDashboard.selector);
        adapter.redeem(capB / 10, recipient);

        (,, uint8 bucket,) = adapter.pledges(bobDashboard);
        assertEq(bucket, 2, "still marked - cleanup must be called separately");
    }

    /// @notice Recovery-then-relapse: a borrower can be re-marked after demotion.
    function test_Invariant_RemarkAfterDemotion() public {
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);
        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);

        _makeUnhealthy(bob);
        adapter.markForLiquidation(bobDashboard);

        _makeHealthy(bob);
        // Cleanup demotes Bob.
        adapter.cleanupLiquidationQueue(10);

        // Bob relapses.
        _makeUnhealthy(bob);
        adapter.markForLiquidation(bobDashboard);
        (,, uint8 bucket,) = adapter.pledges(bobDashboard);
        assertEq(bucket, 2, "re-marked after relapse");
    }

    // ============================================================================
    //                        Voluntary close path
    // ============================================================================

    /// @notice Voluntary close lets anyone redeem, but only because the borrower opted in.
    ///         The drained vault is always the borrower's own.
    function test_Invariant_VoluntaryDoesNotDrainOtherHealthyVaults() public {
        uint256 capA = IDashboard(aliceDashboard).remainingMintingCapacityShares(0);
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);

        vm.prank(alice);
        adapter.pledge(aliceDashboard, capA / 10);
        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);

        // Bob opts for voluntary close. Alice is healthy.
        vm.prank(bob);
        adapter.markForVoluntaryClose(bobDashboard);

        // Some random vaultStETH holder (attacker) redeems.
        vm.prank(bob);
        vaultStETH.transfer(attacker, capB / 10);

        vm.prank(attacker);
        adapter.redeem(capB / 10, recipient);

        (, uint128 alicePledgedAfter,,) = adapter.pledges(aliceDashboard);
        (, uint128 bobPledgedAfter,,) = adapter.pledges(bobDashboard);
        assertEq(alicePledgedAfter, uint128(capA / 10), "Alice untouched");
        assertEq(bobPledgedAfter, 0, "Bob's voluntary pledge fully drained");
    }

    // ============================================================================
    //                        Cross-borrower routing
    // ============================================================================

    /// @notice When MULTIPLE borrowers are liquidating, the queue drains FIFO among them,
    ///         not whichever the caller wishes. Healthy borrowers are untouched.
    function test_Invariant_MultipleLiquidatingBorrowersDrainFifo() public {
        uint256 capB = IDashboard(bobDashboard).remainingMintingCapacityShares(0);
        uint256 capC = IDashboard(carolDashboard).remainingMintingCapacityShares(0);

        vm.prank(bob);
        adapter.pledge(bobDashboard, capB / 10);
        vm.prank(carol);
        adapter.pledge(carolDashboard, capC / 10);

        _makeUnhealthy(bob);
        adapter.markForLiquidation(bobDashboard);

        _makeUnhealthy(carol);
        adapter.markForLiquidation(carolDashboard);

        assertEq(adapter.nextDashboard(), bobDashboard, "Bob (first marked) at head");

        // Drain a portion. We get vaultStETH from Bob to do the redeem.
        vm.prank(bob);
        vaultStETH.transfer(attacker, capB / 10);

        vm.prank(attacker);
        adapter.redeem(capB / 10, recipient);

        // After full drain of Bob, Carol moves to head.
        assertEq(adapter.nextDashboard(), carolDashboard, "Carol at head after Bob drained");
    }
}
