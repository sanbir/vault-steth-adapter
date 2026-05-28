// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal Dashboard mock used ONLY by Halmos symbolic tests. Real Lido
///         Dashboard is exercised by the forge fork tests; Halmos cannot fork so it
///         consumes this deterministic stand-in.
///
///         `mintShares` interaction with our MockStETH:
///         - On `mintShares(to, amount)`, the mock records the new minted amount
///           and credits `to`'s balance on the configured stETH contract.
contract MockDashboard {
    address public immutable STETH_MOCK;
    uint256 public liabilityShares;
    uint256 public mintCapacity = type(uint128).max;

    constructor(address stEthMock_) {
        STETH_MOCK = stEthMock_;
    }

    /// @notice Mirror of `IDashboard.remainingMintingCapacityShares(uint256)`.
    function remainingMintingCapacityShares(uint256) external view returns (uint256) {
        return mintCapacity;
    }

    /// @notice Mirror of `IDashboard.mintShares(address, uint256)`. Credits stETH balance
    ///         to `to` via the mock stETH contract.
    function mintShares(address to, uint256 amount) external {
        liabilityShares += amount;
        (bool ok,) = STETH_MOCK.call(abi.encodeWithSignature("mintTo(address,uint256)", to, amount));
        require(ok, "MockDashboard: stETH credit failed");
    }

    /// @notice For test setup only.
    function setMintCapacity(uint256 newCapacity) external {
        mintCapacity = newCapacity;
    }
}
