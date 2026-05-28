// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDashboard} from "./interfaces/IDashboard.sol";
import {IStETH, IWstETH} from "./interfaces/ILido.sol";
import {VaultStETH} from "./VaultStETH.sol";

/// @title Adapter — vaultStETH issuance + redemption queue
///
/// @notice The Adapter is the only address allowed to mint and burn vaultStETH. It holds
///         MINT_ROLE on the Lido Dashboard of every pledged vault, and uses that role to
///         mint stETH on the redemption path.
///
///         Lifecycle (per vault):
///           1.  Factory creates a Lido stVault + Dashboard + PledgeGuard.
///           2.  Factory grants MINT_ROLE on the Dashboard to this Adapter and registers
///               the vault's Dashboard via `registerDashboard(dashboard, borrower)`.
///           3.  Borrower deposits ETH into their stVault (via Dashboard.fund).
///           4.  Borrower calls `pledge(dashboard, shares)` here → this Adapter records
///               `shares` of pledged mint capacity for that dashboard and mints `shares`
///               of vaultStETH to the borrower.
///           5.  Borrower supplies the freshly-minted vaultStETH to AAVE Main Spoke as
///               collateral.
///           6.  At redemption (liquidation, voluntary close, or third-party redeem), the
///               Adapter selects a dashboard from its priority queue, calls
///               `IDashboard.mintShares(recipient, amount + 2 wei buffer)` on it, wraps
///               the resulting stETH to wstETH, and delivers wstETH to the recipient.
///
///         Redemption queue priorities:
///           a. `liquidationQueue`  — dashboards whose owner has been flagged as in active
///                                    liquidation on AAVE. Drains FIRST.
///           b. `voluntaryQueue`    — dashboards whose owner explicitly marked for close.
///           c. `generalFifo`       — every active pledge, drained oldest-first only when
///                                    a/b are empty.
///
///         The Adapter does NOT custody any user assets except:
///           - The MINT_ROLE it holds transiently on each pledged dashboard.
///           - stETH minted during redemption is immediately wrapped to wstETH and forwarded.
contract Adapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWstETH;

    // ============================================================================
    //                                  Immutables
    // ============================================================================

    VaultStETH public immutable VAULT_STETH;
    IStETH    public immutable STETH;
    IWstETH   public immutable WSTETH;
    address   public immutable FACTORY;

    // ============================================================================
    //                                   Storage
    // ============================================================================

    /// @notice Per-dashboard pledge state.
    /// @dev `borrower` is set on `registerDashboard`; `pledgedShares` accrues on `pledge`
    ///      and decreases on redemption from this dashboard. `bucket` records which
    ///      priority queue this dashboard is currently in: 0 = none/general, 1 = voluntary,
    ///      2 = liquidation.
    struct Pledge {
        address borrower;
        uint128 pledgedShares;
        uint8   bucket;           // 0 = general, 1 = voluntary, 2 = liquidation
        bool    registered;
    }

    mapping(address dashboard => Pledge) public pledges;

    /// @notice FIFO ring buffers for the three priority queues.
    /// @dev We keep these as plain arrays + head pointers. A dashboard can appear in at
    ///      most one queue at any time; the `bucket` field on the Pledge struct says which.
    address[] public liquidationQueue;
    uint256 public liquidationHead;

    address[] public voluntaryQueue;
    uint256 public voluntaryHead;

    address[] public generalFifo;
    uint256 public generalHead;

    /// @notice Mint buffer in stETH-shares. Lido rounding requires a 2-wei buffer on
    ///         shares→wstETH roundtrips so the recipient receives the exact requested
    ///         amount.
    uint256 public constant MINT_BUFFER_SHARES = 2;

    // ============================================================================
    //                                    Events
    // ============================================================================

    event DashboardRegistered(address indexed dashboard, address indexed borrower);
    event Pledged(address indexed dashboard, address indexed borrower, uint256 shares);
    event Unpledged(address indexed dashboard, address indexed borrower, uint256 shares);
    event RedeemedFromDashboard(
        address indexed dashboard,
        address indexed recipient,
        uint256 sharesBurnt,
        uint256 wstEthDelivered
    );
    event MarkedForLiquidation(address indexed dashboard, address indexed marker);
    event MarkedForVoluntaryClose(address indexed dashboard, address indexed borrower);

    // ============================================================================
    //                                    Errors
    // ============================================================================

    error ZeroAddress();
    error OnlyFactory();
    error NotRegistered();
    error AlreadyRegistered();
    error NotBorrower();
    error InsufficientPledgedShares();
    error InsufficientMintCapacity();
    error QueueEmpty();
    error NotInLiquidation();
    error AlreadyMarked();
    error PledgeStillActive();

    // ============================================================================
    //                                  Constructor
    // ============================================================================

    constructor(address stEth_, address wstEth_, address factory_) {
        if (stEth_ == address(0) || wstEth_ == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        STETH = IStETH(stEth_);
        WSTETH = IWstETH(wstEth_);
        FACTORY = factory_;

        // Deploy the vaultStETH ERC-20 with this Adapter as the only minter/burner.
        VAULT_STETH = new VaultStETH(address(this));

        // Approve the wstETH wrapper to spend our stETH at maximum.
        IERC20(stEth_).forceApprove(wstEth_, type(uint256).max);
    }

    // ============================================================================
    //                            Factory-gated registration
    // ============================================================================

    /// @notice Register a freshly-deployed Dashboard. Called by the Factory atomically with
    ///         the Dashboard's role wiring.
    /// @dev    The Factory has granted `MINT_ROLE` on this Dashboard to this Adapter as part
    ///         of the deployment. We do not check it here — that's the Factory's job.
    function registerDashboard(address dashboard, address borrower) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (dashboard == address(0) || borrower == address(0)) revert ZeroAddress();
        if (pledges[dashboard].registered) revert AlreadyRegistered();

        pledges[dashboard] = Pledge({
            borrower: borrower,
            pledgedShares: 0,
            bucket: 0,
            registered: true
        });

        emit DashboardRegistered(dashboard, borrower);
    }

    // ============================================================================
    //                                Pledge lifecycle
    // ============================================================================

    /// @notice Pledge `shares` of mint capacity from `dashboard` and mint vaultStETH to caller.
    /// @dev    Caller MUST be the registered borrower for the dashboard. `shares` MUST be
    ///         within the dashboard's `remainingMintingCapacityShares(0)`.
    function pledge(address dashboard, uint256 shares) external nonReentrant {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();

        // Capacity check against Lido's current state.
        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        if (shares > capacity) revert InsufficientMintCapacity();

        // Update pledge state.
        p.pledgedShares += uint128(shares);

        // If this is the first pledge for this dashboard, push it to the general FIFO.
        if (p.pledgedShares == shares && p.bucket == 0) {
            generalFifo.push(dashboard);
        }

        // Mint vaultStETH to the borrower (caller).
        VAULT_STETH.mint(msg.sender, shares);

        emit Pledged(dashboard, msg.sender, shares);
    }

    /// @notice Reduce the pledge on `dashboard` by `shares` and burn the corresponding
    ///         vaultStETH from the caller.
    /// @dev    Caller MUST be the registered borrower. The pledge must be sufficient. The
    ///         dashboard must not currently be in the liquidation queue. The caller must
    ///         hold and approve the full `shares` of vaultStETH.
    function unpledge(address dashboard, uint256 shares) external nonReentrant {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();
        if (p.bucket == 2) revert PledgeStillActive();   // can't unpledge while liquidated
        if (shares > p.pledgedShares) revert InsufficientPledgedShares();

        p.pledgedShares -= uint128(shares);

        // Burn vaultStETH from caller. Will revert if caller's balance is insufficient.
        VAULT_STETH.burn(msg.sender, shares);

        emit Unpledged(dashboard, msg.sender, shares);
    }

    // ============================================================================
    //                            Priority queue management
    // ============================================================================

    /// @notice Mark a dashboard's borrower as in active liquidation. Permissionless.
    /// @dev    For testing / launch, the caller is trusted to verify the on-chain
    ///         condition (typically: Spoke.getUserAccountData(borrower).healthFactor < 1e18).
    ///         Production deployments should add a verification step here against the
    ///         AAVE Spoke. We accept best-effort marking at launch because the redemption
    ///         path itself enforces the mint succeeds — bad marks just rearrange queue
    ///         order, not balances.
    function markForLiquidation(address dashboard) external {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (p.bucket == 2) revert AlreadyMarked();

        p.bucket = 2;
        liquidationQueue.push(dashboard);

        emit MarkedForLiquidation(dashboard, msg.sender);
    }

    /// @notice Borrower opt-in: mark the vault for voluntary close, moving it to the
    ///         voluntary-close queue. Useful when winding down a position.
    function markForVoluntaryClose(address dashboard) external {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();
        if (p.bucket == 1 || p.bucket == 2) revert AlreadyMarked();

        p.bucket = 1;
        voluntaryQueue.push(dashboard);

        emit MarkedForVoluntaryClose(dashboard, msg.sender);
    }

    // ============================================================================
    //                                  Redemption
    // ============================================================================

    /// @notice Burn `shares` of vaultStETH from caller and mint wstETH to `recipient` by
    ///         calling `Dashboard.mintShares` on the next vault in priority order.
    /// @dev    The caller MUST hold `shares` of vaultStETH (we burn from `msg.sender`).
    ///         Redemption may fail if the selected dashboard's vault no longer has the
    ///         capacity to mint — in that case the call reverts and the caller can retry
    ///         (a subsequent governance / operator action would update the queue).
    /// @return wstEthAmount   The amount of wstETH delivered to `recipient` (= `shares` − 2 wei buffer).
    function redeem(uint256 shares, address recipient)
        external
        nonReentrant
        returns (uint256 wstEthAmount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (shares == 0) revert InsufficientPledgedShares();

        // Pick the next dashboard.
        address dashboard = _selectDashboard(shares);
        Pledge storage p = pledges[dashboard];

        // Decrement pledged shares on this dashboard.
        p.pledgedShares -= uint128(shares);

        // Burn vaultStETH from caller. Reverts on insufficient balance.
        VAULT_STETH.burn(msg.sender, shares);

        // Mint stETH from the dashboard to ourselves, with a 2-wei buffer.
        uint256 sharesWithBuffer = shares + MINT_BUFFER_SHARES;
        IDashboard(dashboard).mintShares(address(this), sharesWithBuffer);

        // Wrap stETH → wstETH. wrap() returns wstETH amount; we forward exactly that.
        // We wrap the FULL stETH balance we just received (the precise amount in stETH
        // terms is `STETH.getPooledEthByShares(sharesWithBuffer)`).
        uint256 stEthReceived = STETH.balanceOf(address(this));
        uint256 wstEthMinted = WSTETH.wrap(stEthReceived);

        // Compute the EXACT wstETH amount that corresponds to `shares` (NOT including
        // the buffer). That's what the caller paid for. We deliver this exact amount; any
        // 1-2 wei residual stays in the Adapter as dust.
        wstEthAmount = WSTETH.getWstETHByStETH(STETH.getPooledEthByShares(shares));

        // Some Lido rounding paths can deliver a tiny bit less wstETH than the perfect
        // computed value. Cap at what we actually have.
        if (wstEthAmount > wstEthMinted) {
            wstEthAmount = wstEthMinted;
        }

        WSTETH.safeTransfer(recipient, wstEthAmount);

        emit RedeemedFromDashboard(dashboard, recipient, shares, wstEthAmount);
    }

    /// @notice Internal queue walker. Returns the head of the highest-priority non-empty queue.
    /// @dev    A dashboard at the head whose `pledgedShares < requestedShares` is skipped
    ///         and removed from its queue; we move on to the next entry. This bounds the
    ///         work the caller does per redemption (worst case = total queue size).
    function _selectDashboard(uint256 requestedShares) internal returns (address) {
        // 1) Liquidation queue.
        while (liquidationHead < liquidationQueue.length) {
            address d = liquidationQueue[liquidationHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 2 && p.pledgedShares >= requestedShares) {
                return d;
            }
            // Skip / pop the head.
            unchecked { ++liquidationHead; }
        }
        // 2) Voluntary close queue.
        while (voluntaryHead < voluntaryQueue.length) {
            address d = voluntaryQueue[voluntaryHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 1 && p.pledgedShares >= requestedShares) {
                return d;
            }
            unchecked { ++voluntaryHead; }
        }
        // 3) General FIFO.
        while (generalHead < generalFifo.length) {
            address d = generalFifo[generalHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 0 && p.pledgedShares >= requestedShares) {
                return d;
            }
            unchecked { ++generalHead; }
        }
        revert QueueEmpty();
    }

    // ============================================================================
    //                                  Views
    // ============================================================================

    function queueLengths()
        external
        view
        returns (uint256 liquidationLen, uint256 voluntaryLen, uint256 generalLen)
    {
        liquidationLen = liquidationQueue.length - liquidationHead;
        voluntaryLen = voluntaryQueue.length - voluntaryHead;
        generalLen = generalFifo.length - generalHead;
    }

    function nextDashboard() external view returns (address) {
        // Read-only walker: doesn't mutate head pointers. Returns address(0) if nothing
        // is currently redeemable.
        uint256 i = liquidationHead;
        while (i < liquidationQueue.length) {
            address d = liquidationQueue[i];
            Pledge storage p = pledges[d];
            if (p.bucket == 2 && p.pledgedShares > 0) return d;
            unchecked { ++i; }
        }
        i = voluntaryHead;
        while (i < voluntaryQueue.length) {
            address d = voluntaryQueue[i];
            Pledge storage p = pledges[d];
            if (p.bucket == 1 && p.pledgedShares > 0) return d;
            unchecked { ++i; }
        }
        i = generalHead;
        while (i < generalFifo.length) {
            address d = generalFifo[i];
            Pledge storage p = pledges[d];
            if (p.bucket == 0 && p.pledgedShares > 0) return d;
            unchecked { ++i; }
        }
        return address(0);
    }
}
