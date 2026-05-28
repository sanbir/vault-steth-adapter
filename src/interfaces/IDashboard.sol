// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IVaultHub} from "./IVaultHub.sol";
import {IStakingVault} from "./IStakingVault.sol";

/// @notice Minimal interface for the Lido V3 Dashboard contract.
/// @dev Matches `lido/core/contracts/0.8.25/vaults/dashboard/Dashboard.sol`.
interface IDashboard {
    // ---------- role ids ----------
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function FUND_ROLE() external view returns (bytes32);
    function WITHDRAW_ROLE() external view returns (bytes32);
    function MINT_ROLE() external view returns (bytes32);
    function BURN_ROLE() external view returns (bytes32);
    function REBALANCE_ROLE() external view returns (bytes32);
    function REQUEST_VALIDATOR_EXIT_ROLE() external view returns (bytes32);
    function TRIGGER_VALIDATOR_WITHDRAWAL_ROLE() external view returns (bytes32);
    function VOLUNTARY_DISCONNECT_ROLE() external view returns (bytes32);
    function VAULT_CONFIGURATION_ROLE() external view returns (bytes32);
    function PAUSE_BEACON_CHAIN_DEPOSITS_ROLE() external view returns (bytes32);
    function RESUME_BEACON_CHAIN_DEPOSITS_ROLE() external view returns (bytes32);
    function NODE_OPERATOR_MANAGER_ROLE() external view returns (bytes32);

    // ---------- AccessControl ----------
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;

    // ---------- views ----------
    function STETH() external view returns (address);
    function WSTETH() external view returns (address);
    function VAULT_HUB() external view returns (IVaultHub);
    function stakingVault() external view returns (IStakingVault);
    function vaultConnection() external view returns (IVaultHub.VaultConnection memory);
    function liabilityShares() external view returns (uint256);
    function totalValue() external view returns (uint256);
    function locked() external view returns (uint256);
    function maxLockableValue() external view returns (uint256);
    function totalMintingCapacityShares() external view returns (uint256);
    function remainingMintingCapacityShares(uint256 _etherToFund) external view returns (uint256);
    function withdrawableValue() external view returns (uint256);

    // ---------- actions ----------
    function fund() external payable;
    function withdraw(address _recipient, uint256 _ether) external;
    function mintShares(address _recipient, uint256 _amountOfShares) external payable;
    function mintStETH(address _recipient, uint256 _amountOfStETH) external payable;
    function mintWstETH(address _recipient, uint256 _amountOfWstETH) external payable;
    function burnShares(uint256 _amountOfShares) external;
    function burnStETH(uint256 _amountOfStETH) external;
    function burnWstETH(uint256 _amountOfWstETH) external;
    function rebalanceVaultWithShares(uint256 _shares) external;
    function rebalanceVaultWithEther(uint256 _ether) external payable;
    function requestValidatorExit(bytes calldata _pubkeys) external;
    function voluntaryDisconnect() external;
    function transferVaultOwnership(address _newOwner) external;
    function pauseBeaconChainDeposits() external;
    function resumeBeaconChainDeposits() external;
}

/// @notice The Lido VaultFactory creates a stVault and its Dashboard atomically.
/// @dev Interface matches the DEPLOYED mainnet contract at 0x02Ca7772FF14a9F6c1a08aF385aA96bb1b34175A.
///      Note: the deployed `RoleAssignment` struct order is `(account, role)`, NOT `(role, account)`
///      as in current Lido `master` source. Selector 0x5b0aa953 confirms this order.
interface ILidoVaultFactory {
    struct RoleAssignment {
        address account;
        bytes32 role;
    }

    function createVaultWithDashboard(
        address _defaultAdmin,
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        RoleAssignment[] calldata _roleAssignments
    ) external payable returns (address vault, address dashboard);

    function deployedVaults(address vault) external view returns (bool);
}
