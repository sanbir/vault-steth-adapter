// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal stETH stand-in for Halmos symbolic tests (real Lido stETH on the
///         fork is used by the forge fork suite). Implements the small surface the
///         Adapter touches: `balanceOf`, `getPooledEthByShares`, `approve` (via ERC20),
///         and a `mintTo` hook for the MockDashboard.
contract MockStETH is ERC20 {
    constructor() ERC20("Mock stETH", "stETH") {}

    /// @notice Called by MockDashboard.mintShares to credit balance.
    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice 1:1 identity for symbolic-test purposes (real stETH is rebasing).
    function getPooledEthByShares(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    /// @notice Submit ETH for stETH (used by some test setup paths). Mints 1:1.
    function submit(address) external payable returns (uint256) {
        _mint(msg.sender, msg.value);
        return msg.value;
    }
}
