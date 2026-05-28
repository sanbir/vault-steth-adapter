// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title Addresses
/// @notice Ethereum mainnet addresses verified against the Lido V3 + AAVE v4 deployments.
/// @dev See `stvaults-liquidation-manager/src/Addresses.sol` for the verification log
///      (block ~24,927,461). These are the same addresses; reused here for consistency.
library Addresses {
    // -------- Lido V3 --------
    address internal constant LIDO_LOCATOR  = 0xC1d0b3DE6792Bf6b4b37EccdcC24e45978Cfd2Eb;
    address internal constant STETH         = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH        = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant VAULT_HUB     = 0x1d201BE093d847f6446530Efb0E8Fb426d176709;
    address internal constant VAULT_FACTORY = 0x02Ca7772FF14a9F6c1a08aF385aA96bb1b34175A;
    address internal constant LAZY_ORACLE   = 0x5DB427080200c235F2Ae8Cd17A7be87921f7AD6c;

    // -------- AAVE v4 (asset-listing target only; we don't deploy anything here) --------
    address internal constant AAVE_V4_MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;

    // -------- AAVE v3 Pool (used as healthFactor source until v4 Main Spoke is live) --------
    /// @dev v3 Pool exposes the same `getUserAccountData(address) returns (..., healthFactor)`
    ///      signature as v4 Main Spoke. The Adapter reads only `healthFactor`, so it works
    ///      against either deployment.
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // -------- Chainlink --------
    address internal constant CHAINLINK_ETH_USD   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_STETH_ETH = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
}
