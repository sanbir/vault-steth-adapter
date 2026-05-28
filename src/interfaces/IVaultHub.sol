// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal interface for the Lido V3 VaultHub.
/// @dev Verified against the deployed contract at 0x1d201BE093d847f6446530Efb0E8Fb426d176709.
interface IVaultHub {
    struct VaultConnection {
        address owner;
        uint96 shareLimit;
        uint96 vaultIndex;
        uint48 disconnectInitiatedTs;
        uint16 reserveRatioBP;
        uint16 forcedRebalanceThresholdBP;
        uint16 infraFeeBP;
        uint16 liquidityFeeBP;
        uint16 reservationFeeBP;
        bool beaconChainDepositsPauseIntent;
    }

    struct Report {
        uint104 totalValue;
        int104 inOutDelta;
        uint48 timestamp;
    }

    function CONNECT_DEPOSIT() external view returns (uint256);
    function REPORT_FRESHNESS_DELTA() external view returns (uint256);
    function vaultConnection(address vault) external view returns (VaultConnection memory);
    function totalValue(address vault) external view returns (uint256);
    function liabilityShares(address vault) external view returns (uint256);
    function isReportFresh(address vault) external view returns (bool);
}
