// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title IAavePool
/// @notice Minimal interface to the AAVE Main Spoke (v4) / Pool (v3) for reading a
///         borrower's healthFactor. Both v3 and v4 expose this exact signature.
/// @dev Only `getUserAccountData` is used. The Adapter calls this view to gate state
///      changes that depend on a borrower being in active liquidation on AAVE.
interface IAavePool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
