// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal wstETH stand-in for Halmos symbolic tests. `wrap` pulls `amount` of
///         the configured stETH from the caller and mints the same amount of wstETH 1:1.
///         The real wstETH has a non-1:1 exchange rate; for Halmos we collapse it because
///         the Adapter's invariant is about `pledgedShares` accounting, not rate fidelity.
contract MockWstETH is ERC20 {
    IERC20 public immutable STETH;

    constructor(address stEth_) ERC20("Mock wstETH", "wstETH") {
        STETH = IERC20(stEth_);
    }

    /// @notice Called by the Adapter on the redemption path: pull stETH from caller,
    ///         mint wstETH 1:1 to caller.
    function wrap(uint256 stEthAmount) external returns (uint256) {
        STETH.transferFrom(msg.sender, address(this), stEthAmount);
        _mint(msg.sender, stEthAmount);
        return stEthAmount;
    }

    function getWstETHByStETH(uint256 amount) external pure returns (uint256) {
        return amount; // identity (real wstETH uses share-per-token rate)
    }
}
