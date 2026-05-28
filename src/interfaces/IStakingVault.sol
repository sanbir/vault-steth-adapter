// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal interface for Lido V3 StakingVault.
interface IStakingVault {
    function owner() external view returns (address);
    function nodeOperator() external view returns (address);
    function withdrawalCredentials() external view returns (bytes32);
    function availableBalance() external view returns (uint256);
    function stagedBalance() external view returns (uint256);
}
