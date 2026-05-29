// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

import {PledgeGuard} from "../src/PledgeGuard.sol";
import {MockGuardDashboard} from "./mocks/MockGuardDashboard.sol";
import {MockGuardAdapter} from "./mocks/MockGuardAdapter.sol";

/// @title HalmosGuardTest
/// @notice Formal proof of the pledge-backing floor that fixes the late-mint double-spend.
///
///         Property: for ANY withdrawal amount and ANY (capacity, pledged, withdrawable)
///         state, IF `PledgeGuard.withdraw` succeeds, THEN either no pledge is active OR the
///         post-withdraw mint capacity is at least `pledged + MINT_BUFFER_SHARES`. I.e. a
///         successful withdrawal can never leave the outstanding pledge unbacked.
///
///         Halmos drives the Lido-side capacity / withdrawableValue and the Adapter-side
///         pledged amount symbolically (real Lido semantics are covered by the fork tests
///         in DoubleSpend.t.sol; here we prove the GUARD's branch logic over all inputs).
///
///         Run: halmos --contract HalmosGuardTest --no-status
contract HalmosGuardTest is SymTest, Test {
    MockGuardDashboard internal dash;
    MockGuardAdapter internal adp;
    PledgeGuard internal pg;

    function setUp() public {
        dash = new MockGuardDashboard();
        adp = new MockGuardAdapter();
        // owner == this so the test can call the onlyOwner withdraw.
        pg = new PledgeGuard(address(dash), address(adp), address(this));
    }

    /// @notice THE floor invariant. Succeeds (withdraw returns) ==> pledge stays backed.
    function check_WithdrawNeverLeavesPledgeUnbacked(uint256 amount, address recipient) public {
        uint256 cap = svm.createUint256("cap");
        uint256 wv = svm.createUint256("wv");
        uint256 pledged = svm.createUint256("pledged");
        // pledgedShares is a uint128 in the real Adapter; bound to avoid spurious
        // overflow counterexamples in the assertion arithmetic.
        vm.assume(pledged <= type(uint128).max);

        dash.setCapacity(cap);
        dash.setWithdrawableValue(wv);
        adp.setPledged(pledged);

        (bool ok,) = address(pg).call(
            abi.encodeWithSelector(PledgeGuard.withdraw.selector, recipient, amount)
        );

        if (ok) {
            // The mock's withdraw is a no-op, so capacityAfter == cap. A successful
            // withdraw must therefore have satisfied the floor.
            assert(pledged == 0 || cap >= pledged + 2);
        }
    }

    /// @notice A withdrawal that would breach the floor MUST revert (no false-pass).
    function check_WithdrawRevertsWhenFloorBreached(uint256 amount, address recipient) public {
        uint256 cap = svm.createUint256("cap");
        uint256 pledged = svm.createUint256("pledged");
        vm.assume(pledged != 0 && pledged <= type(uint128).max);
        // State that breaches the floor: capacity strictly below pledged + buffer.
        vm.assume(cap < pledged + 2);

        dash.setCapacity(cap);
        dash.setWithdrawableValue(type(uint256).max); // never the binding constraint

        adp.setPledged(pledged);

        (bool ok,) = address(pg).call(
            abi.encodeWithSelector(PledgeGuard.withdraw.selector, recipient, amount)
        );

        assert(!ok); // must revert: it would unback the pledge
    }
}
