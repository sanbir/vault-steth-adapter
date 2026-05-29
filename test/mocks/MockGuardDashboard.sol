// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal Dashboard stand-in for Halmos symbolic tests of `PledgeGuard.withdraw`.
///         Real Lido behavior is exercised by the forge fork tests; Halmos cannot fork, so
///         it drives `remainingMintingCapacityShares` and `withdrawableValue` directly with
///         symbolic values. `withdraw` is a no-op (the property under test is the guard's
///         floor branch logic, not ETH movement).
contract MockGuardDashboard {
    uint256 internal cap;
    uint256 internal wv;

    function setCapacity(uint256 c) external { cap = c; }
    function setWithdrawableValue(uint256 w) external { wv = w; }

    function remainingMintingCapacityShares(uint256) external view returns (uint256) { return cap; }
    function withdrawableValue() external view returns (uint256) { return wv; }
    function withdraw(address, uint256) external {}

    // Role getters read by the PledgeGuard constructor.
    function WITHDRAW_ROLE() external pure returns (bytes32) { return keccak256("WITHDRAW_ROLE"); }
    function VOLUNTARY_DISCONNECT_ROLE() external pure returns (bytes32) {
        return keccak256("VOLUNTARY_DISCONNECT_ROLE");
    }
    function REQUEST_VALIDATOR_EXIT_ROLE() external pure returns (bytes32) {
        return keccak256("REQUEST_VALIDATOR_EXIT_ROLE");
    }
    function TRIGGER_VALIDATOR_WITHDRAWAL_ROLE() external pure returns (bytes32) {
        return keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");
    }
    function VAULT_CONFIGURATION_ROLE() external pure returns (bytes32) {
        return keccak256("VAULT_CONFIGURATION_ROLE");
    }
}
