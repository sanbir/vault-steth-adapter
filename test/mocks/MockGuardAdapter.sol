// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal Adapter stand-in exposing the two views PledgeGuard reads:
///         `pledgedSharesOf` (symbolic, settable) and `MINT_BUFFER_SHARES` (= 2, matching
///         the real Adapter constant). Used by the Halmos guard-logic proof.
contract MockGuardAdapter {
    uint256 internal pledged;

    function setPledged(uint256 p) external { pledged = p; }
    function pledgedSharesOf(address) external view returns (uint256) { return pledged; }
    function MINT_BUFFER_SHARES() external pure returns (uint256) { return 2; }
}
