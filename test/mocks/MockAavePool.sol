// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAavePool} from "../../src/interfaces/IAavePool.sol";

/// @title MockAavePool
/// @notice A deployable mock of the AAVE Pool's `getUserAccountData` view used by tests
///         and Halmos symbolic execution. NOT `vm.mockCall` — this is a real contract.
///
///         Tests deploy this and set per-borrower `healthFactor` directly via `setHealthFactor`.
///         Default healthFactor for any unset user is `type(uint256).max` (perfectly healthy)
///         so unset users cannot be marked for liquidation by mistake.
contract MockAavePool is IAavePool {
    mapping(address => uint256) internal hf;

    /// @notice For Halmos / unit tests. Sets the borrower's healthFactor to `value`.
    /// @dev    Halmos treats `value` as a symbolic uint256; unit tests use concrete values
    ///         such as `0.5e18` (unhealthy) or `2e18` (healthy).
    function setHealthFactor(address user, uint256 value) external {
        hf[user] = value;
    }

    /// @inheritdoc IAavePool
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
        )
    {
        // We only care about healthFactor. Default to max (perfectly healthy) when unset
        // so that random / unconfigured addresses cannot be marked for liquidation by
        // accident.
        healthFactor = hf[user];
        if (healthFactor == 0) healthFactor = type(uint256).max;

        // The other fields are left at zero — the Adapter does not read them.
        totalCollateralBase = 0;
        totalDebtBase = 0;
        availableBorrowsBase = 0;
        currentLiquidationThreshold = 0;
        ltv = 0;
    }
}
