// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {VaultStETH} from "../src/VaultStETH.sol";

/// @notice Unit tests for the VaultStETH ERC-20 token contract itself.
///         These do not need a mainnet fork — they exercise the access-controlled mint/burn
///         and freely-transferable ERC-20 semantics.
contract VaultStETHTest is Test {
    VaultStETH internal token;
    address internal adapter = makeAddr("adapter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(adapter);
        token = new VaultStETH(adapter);
    }

    // ============================================================================
    //                                    Metadata
    // ============================================================================

    function test_Metadata() public view {
        assertEq(token.name(), "Vault stETH", "name");
        assertEq(token.symbol(), "vaultStETH", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(token.ADAPTER(), adapter, "ADAPTER immutable");
        assertEq(token.totalSupply(), 0, "supply starts at 0");
    }

    function test_RevertsOnZeroAdapter() public {
        vm.expectRevert(VaultStETH.ZeroAddress.selector);
        new VaultStETH(address(0));
    }

    // ============================================================================
    //                                  Mint access
    // ============================================================================

    function test_MintByAdapter() public {
        vm.prank(adapter);
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether, "alice balance");
        assertEq(token.totalSupply(), 100 ether, "total supply");
    }

    function test_MintReverts_NotAdapter() public {
        vm.expectRevert(VaultStETH.OnlyAdapter.selector);
        vm.prank(alice);
        token.mint(alice, 1 ether);
    }

    function test_MintReverts_UnauthorisedZero() public {
        // Even the zero address can't mint — only the adapter.
        vm.expectRevert(VaultStETH.OnlyAdapter.selector);
        token.mint(alice, 1 ether);
    }

    // ============================================================================
    //                                  Burn access
    // ============================================================================

    function test_BurnByAdapter() public {
        vm.startPrank(adapter);
        token.mint(alice, 100 ether);
        token.burn(alice, 40 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 60 ether, "balance after burn");
        assertEq(token.totalSupply(), 60 ether, "total supply after burn");
    }

    function test_BurnReverts_NotAdapter() public {
        vm.prank(adapter);
        token.mint(alice, 100 ether);

        vm.expectRevert(VaultStETH.OnlyAdapter.selector);
        vm.prank(alice);
        token.burn(alice, 1 ether);
    }

    function test_BurnReverts_InsufficientBalance() public {
        vm.prank(adapter);
        token.mint(alice, 5 ether);

        // OZ ERC-20 reverts with ERC20InsufficientBalance.
        vm.expectRevert();
        vm.prank(adapter);
        token.burn(alice, 10 ether);
    }

    // ============================================================================
    //                              Free transfer semantics
    // ============================================================================
    // vaultStETH is INTENTIONALLY freely transferable. This is the key architectural
    // distinction from Babylon's vaultBTC, which IS transfer-restricted. We exercise
    // every standard ERC-20 path to demonstrate the absence of restrictions.

    function test_Transfer_AnyHolderToAnyRecipient() public {
        vm.prank(adapter);
        token.mint(alice, 100 ether);

        // alice → bob, no restrictions.
        vm.prank(alice);
        bool ok = token.transfer(bob, 30 ether);
        assertTrue(ok, "transfer returns true");
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.balanceOf(bob), 30 ether);
    }

    function test_TransferFrom_WithAllowance() public {
        vm.prank(adapter);
        token.mint(alice, 100 ether);

        vm.prank(alice);
        token.approve(bob, 25 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 25 ether);

        assertEq(token.balanceOf(alice), 75 ether);
        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Transfer_ToZeroAddressReverts() public {
        vm.prank(adapter);
        token.mint(alice, 1 ether);

        // OZ blocks ERC-20 transfers to the zero address.
        vm.expectRevert();
        vm.prank(alice);
        token.transfer(address(0), 1 ether);
    }

    function test_Transfer_ToAdapterAllowed() public {
        // Some redemption flows transfer vaultStETH back to the Adapter; this must work
        // identically to any other recipient (no special-casing).
        vm.prank(adapter);
        token.mint(alice, 1 ether);

        vm.prank(alice);
        token.transfer(adapter, 1 ether);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(adapter), 1 ether);
    }

    function testFuzz_MintBurnRoundtrip(uint128 amount) public {
        vm.prank(adapter);
        token.mint(alice, amount);
        assertEq(token.balanceOf(alice), amount, "mint balance");

        vm.prank(adapter);
        token.burn(alice, amount);
        assertEq(token.balanceOf(alice), 0, "burn balance");
        assertEq(token.totalSupply(), 0, "supply zero");
    }
}
