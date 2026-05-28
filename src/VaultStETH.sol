// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VaultStETH
/// @notice Freely-transferable ERC-20 representing a claim on mintable stETH from a pool of
///         pledged Lido stVaults. Mint and burn are restricted to the Adapter; all other
///         ERC-20 semantics (transfer, approve, allowance) are standard and unrestricted.
/// @dev Total supply equals the sum of pledged-but-not-yet-redeemed mint capacity across
///      all participating vaults, measured in stETH shares. 1 vaultStETH represents the
///      right to mint 1 stETH share via `Adapter.redeem` from some vault chosen by the
///      Adapter's priority queue (see Adapter.sol for the rules).
contract VaultStETH is ERC20 {
    /// @notice The only address allowed to mint and burn vaultStETH.
    address public immutable ADAPTER;

    error OnlyAdapter();
    error ZeroAddress();

    modifier onlyAdapter() {
        if (msg.sender != ADAPTER) revert OnlyAdapter();
        _;
    }

    constructor(address adapter_) ERC20("Vault stETH", "vaultStETH") {
        if (adapter_ == address(0)) revert ZeroAddress();
        ADAPTER = adapter_;
    }

    /// @notice Mint vaultStETH. Callable only by the Adapter, during user pledging.
    /// @param to       Recipient of the newly minted vaultStETH.
    /// @param amount   Shares-denominated quantity (matches stETH shares accounting).
    function mint(address to, uint256 amount) external onlyAdapter {
        _mint(to, amount);
    }

    /// @notice Burn vaultStETH. Callable only by the Adapter, during user redemption.
    /// @param from     Holder whose tokens are burned. The Adapter is responsible for
    ///                 verifying caller intent (typically `from == tx caller`).
    /// @param amount   Shares-denominated quantity to burn.
    function burn(address from, uint256 amount) external onlyAdapter {
        _burn(from, amount);
    }
}
