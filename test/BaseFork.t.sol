// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Addresses} from "../src/Addresses.sol";
import {Adapter} from "../src/Adapter.sol";
import {VaultStETH} from "../src/VaultStETH.sol";
import {PledgeGuard} from "../src/PledgeGuard.sol";
import {StVaultFactory} from "../src/StVaultFactory.sol";

import {IDashboard, ILidoVaultFactory} from "../src/interfaces/IDashboard.sol";
import {IVaultHub} from "../src/interfaces/IVaultHub.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {IStETH, IWstETH} from "../src/interfaces/ILido.sol";

import {MockAavePool} from "./mocks/MockAavePool.sol";

/// @notice Shared scaffolding for the vault-steth-adapter fork tests.
///
///         End-to-end strategy (mirrors auto-rebalancer-safe-modules / Path A):
///         - Fork Ethereum mainnet at a recent block (env-controlled, falls back to a
///           pinned block if no fork-block override is supplied).
///         - Deploy our four contracts (Adapter, VaultStETH (auto), PledgeGuard impl is
///           per-vault, StVaultFactory).
///         - Each test goes end-to-end against REAL Lido V3 contracts: real `VaultFactory`
///           deploys real Dashboards + StakingVaults; real `mintShares` issues real stETH;
///           real `wrap` produces real wstETH.
///         - No `vm.mockCall` anywhere.
abstract contract BaseFork is Test {
    // ---- test actors ----
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal arbitrageur = makeAddr("arbitrageur");
    address internal nodeOperator = makeAddr("nodeOperator");
    address internal unauthorised = makeAddr("unauthorised");
    address internal recipient = makeAddr("recipient");

    // ---- our contracts ----
    Adapter internal adapter;
    VaultStETH internal vaultStETH;
    StVaultFactory internal factory;
    MockAavePool internal aavePool;

    // ---- real mainnet contracts ----
    IStETH internal stETH = IStETH(Addresses.STETH);
    IWstETH internal wstETH = IWstETH(Addresses.WSTETH);
    IVaultHub internal vaultHub = IVaultHub(Addresses.VAULT_HUB);
    ILidoVaultFactory internal lidoFactory = ILidoVaultFactory(Addresses.VAULT_FACTORY);

    // ---- helpers ----
    uint256 internal constant CONFIRM_EXPIRY = 30 days;
    uint256 internal constant NODE_OPERATOR_FEE_BP = 1000; // 10%

    function _setUpFork() internal {
        // Use env MAINNET_RPC_URL when set, else fall back to a public endpoint. Pinned
        // block is intentionally a known-stable one; tests are insensitive to head
        // movement because every state read uses live contract calls.
        string memory rpcUrl;
        try vm.envString("MAINNET_RPC_URL") returns (string memory s) {
            rpcUrl = s;
        } catch {
            rpcUrl = "https://ethereum-rpc.publicnode.com";
        }
        vm.createSelectFork(rpcUrl);

        // Label real mainnet addresses for readable traces.
        vm.label(address(stETH), "stETH");
        vm.label(address(wstETH), "wstETH");
        vm.label(address(vaultHub), "VaultHub");
        vm.label(address(lidoFactory), "LidoVaultFactory");
        vm.label(borrower, "borrower");
        vm.label(liquidator, "liquidator");
        vm.label(arbitrageur, "arbitrageur");
        vm.label(nodeOperator, "nodeOperator");
        vm.label(unauthorised, "unauthorised");
        vm.label(recipient, "recipient");

        _deployOurContracts();
    }

    /// @dev Bootstrap order:
    ///        1. Deploy the MockAavePool (real deployed contract, not vm.mockCall).
    ///        2. Predict the address of the StVaultFactory (at deployer's nonce + 2).
    ///        3. Deploy Adapter with predicted factory + AAVE pool addresses.
    ///        4. Deploy StVaultFactory pointing at the Adapter.
    function _deployOurContracts() internal {
        aavePool = new MockAavePool();

        address deployer = address(this);
        uint64 nonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce + 1);

        adapter = new Adapter(
            address(stETH), address(wstETH), predictedFactory, address(aavePool)
        );
        factory = new StVaultFactory(address(lidoFactory), address(adapter));
        require(address(factory) == predictedFactory, "factory address mismatch");

        vaultStETH = adapter.VAULT_STETH();

        vm.label(address(aavePool), "MockAavePool");
        vm.label(address(adapter), "Adapter");
        vm.label(address(factory), "StVaultFactory");
        vm.label(address(vaultStETH), "vaultStETH");
    }

    // ============================================================================
    //                            AAVE health-factor helpers
    // ============================================================================

    /// @notice Make `who` look healthy on AAVE (HF = type(uint256).max).
    function _makeHealthy(address who) internal {
        aavePool.setHealthFactor(who, type(uint256).max);
    }

    /// @notice Make `who` look unhealthy / liquidatable on AAVE (HF = 0.5e18).
    function _makeUnhealthy(address who) internal {
        aavePool.setHealthFactor(who, 0.5e18);
    }

    /// @notice Set `who`'s healthFactor to exactly `hf`.
    function _setHF(address who, uint256 hf) internal {
        aavePool.setHealthFactor(who, hf);
    }

    // ============================================================================
    //                              Vault creation helpers
    // ============================================================================

    /// @notice Create a new stVault owned by `_borrower` and funded with `fundEth` ether of
    ///         beacon-chain deposit capital.
    function _createAndFundVault(address _borrower, uint256 fundEth)
        internal
        returns (address dashboard, address stakingVault, address pledgeGuard)
    {
        uint256 connectDeposit = vaultHub.CONNECT_DEPOSIT();
        vm.deal(_borrower, connectDeposit + fundEth);

        vm.startPrank(_borrower);
        (dashboard, stakingVault, pledgeGuard) = factory.createBorrowerVault{value: connectDeposit}(
            _borrower, nodeOperator, NODE_OPERATOR_FEE_BP, CONFIRM_EXPIRY
        );

        // Fund the vault with `fundEth` to give it beacon-chain capacity.
        if (fundEth > 0) {
            IDashboard(dashboard).fund{value: fundEth}();
        }
        vm.stopPrank();

        vm.label(dashboard, "Dashboard");
        vm.label(stakingVault, "StakingVault");
        vm.label(pledgeGuard, "PledgeGuard");
    }

    /// @notice Helper: pledge `shares` of the dashboard's capacity to the Adapter.
    function _pledge(address _borrower, address dashboard, uint256 shares) internal {
        vm.prank(_borrower);
        adapter.pledge(dashboard, shares);
    }

    /// @notice Helper: drop test stETH at `who`. Some Foundry deal paths don't work cleanly
    ///         with stETH because it's a rebasing token, so we go through the canonical
    ///         `submit()` entry: send the desired ETH and call submit.
    function _stakeForStEth(address who, uint256 ethAmount) internal returns (uint256 stAmount) {
        vm.deal(who, ethAmount);
        vm.prank(who);
        stAmount = stETH.submit{value: ethAmount}(address(0));
    }
}
