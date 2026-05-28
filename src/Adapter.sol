// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDashboard} from "./interfaces/IDashboard.sol";
import {IStETH, IWstETH} from "./interfaces/ILido.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {VaultStETH} from "./VaultStETH.sol";

/// @title Adapter (production-hardened) — vaultStETH issuance + invariant-protected redemption
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
///           6.  At redemption, ONE OF the following must hold:
///                 a. `redeem(...)`: only drains dashboards whose borrower has
///                    `healthFactor < 1e18` on AAVE Main Spoke (liquidation queue) OR
///                    whose borrower explicitly opted for voluntary close (voluntary queue).
///                 b. `selfRedeem(dashboard, ...)`: caller MUST be `borrower[dashboard]`.
///                    Bypasses queues; lets a borrower wind down their own position.
///
/// @notice Production invariant (formally verified by Halmos in test/HalmosInvariants.t.sol):
///         `pledges[d].pledgedShares` can only decrease in a transaction whose direct
///         caller (`msg.sender` of the entry function) is one of:
///           (1) the borrower of `d` (via `unpledge`, `selfRedeem`, or `redeem` against
///               a self-marked voluntary or self-liquidating vault), OR
///           (2) any caller acting on a `d` whose borrower has `healthFactor < 1e18`
///               (verified on AAVE at the moment of selection — recovered borrowers are
///               demoted in-flight), OR
///           (3) any caller acting on a `d` whose `bucket == 1` (voluntary close, set
///               by the borrower themselves).
///         There is NO code path through which a healthy borrower's vault can have its
///         `pledgedShares` reduced by a non-borrower.
contract Adapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWstETH;

    // ============================================================================
    //                                  Constants
    // ============================================================================

    /// @notice AAVE's healthFactor threshold below which a borrower is liquidatable. AAVE
    ///         uses 1e18 (= 1.0) as the boundary; HF < 1e18 means under-collateralized.
    uint256 public constant HF_LIQUIDATION_THRESHOLD = 1e18;

    /// @notice Mint buffer in stETH-shares. Lido rounding requires a 2-wei buffer on
    ///         shares→wstETH roundtrips so the recipient receives the exact requested amount.
    uint256 public constant MINT_BUFFER_SHARES = 2;

    // ============================================================================
    //                                  Immutables
    // ============================================================================

    VaultStETH public immutable VAULT_STETH;
    IStETH    public immutable STETH;
    IWstETH   public immutable WSTETH;
    address   public immutable FACTORY;
    IAavePool public immutable AAVE_POOL;

    // ============================================================================
    //                                   Storage
    // ============================================================================

    /// @notice Per-dashboard pledge state.
    /// @dev `borrower` is set on `registerDashboard`; `pledgedShares` accrues on `pledge`
    ///      and decreases ONLY through invariant-protected paths.
    ///      `bucket`: 0 = unmarked (default, can only be drained via `selfRedeem`),
    ///                1 = voluntary close (borrower opt-in, drainable by anyone via `redeem`),
    ///                2 = liquidation (HF < 1e18 confirmed at marking time AND re-confirmed
    ///                                 at selection time).
    struct Pledge {
        address borrower;
        uint128 pledgedShares;
        uint8   bucket;
        bool    registered;
    }

    mapping(address dashboard => Pledge) public pledges;

    /// @notice FIFO ring buffers for the two drainable queues. A dashboard is in at most
    ///         one queue at a time; the `bucket` field is authoritative.
    address[] public liquidationQueue;
    uint256 public liquidationHead;

    address[] public voluntaryQueue;
    uint256 public voluntaryHead;

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
    event SelfRedeemed(
        address indexed dashboard,
        address indexed borrower,
        address indexed recipient,
        uint256 sharesBurnt,
        uint256 wstEthDelivered
    );
    event MarkedForLiquidation(address indexed dashboard, address indexed marker, uint256 healthFactor);
    event MarkedForVoluntaryClose(address indexed dashboard, address indexed borrower);
    event DemotedFromLiquidation(address indexed dashboard, uint256 healthFactor);

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
    error NoEligibleDashboard();
    error AlreadyMarked();
    error BorrowerHealthy(uint256 healthFactor);
    error PledgeStillActive();
    error ZeroShares();

    // ============================================================================
    //                                  Constructor
    // ============================================================================

    constructor(address stEth_, address wstEth_, address factory_, address aavePool_) {
        if (
            stEth_ == address(0) || wstEth_ == address(0) || factory_ == address(0)
                || aavePool_ == address(0)
        ) {
            revert ZeroAddress();
        }
        STETH = IStETH(stEth_);
        WSTETH = IWstETH(wstEth_);
        FACTORY = factory_;
        AAVE_POOL = IAavePool(aavePool_);

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
    /// @dev    Caller MUST be the registered borrower for the dashboard.
    function pledge(address dashboard, uint256 shares) external nonReentrant {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();
        if (shares == 0) revert ZeroShares();

        uint256 capacity = IDashboard(dashboard).remainingMintingCapacityShares(0);
        if (shares > capacity) revert InsufficientMintCapacity();

        p.pledgedShares += uint128(shares);

        VAULT_STETH.mint(msg.sender, shares);

        emit Pledged(dashboard, msg.sender, shares);
    }

    /// @notice Reduce the pledge on `dashboard` by `shares` and burn vaultStETH from caller.
    /// @dev    Caller MUST be the registered borrower. Dashboard MUST NOT be in liquidation.
    function unpledge(address dashboard, uint256 shares) external nonReentrant {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();
        if (p.bucket == 2) revert PledgeStillActive();
        if (shares == 0) revert ZeroShares();
        if (shares > p.pledgedShares) revert InsufficientPledgedShares();

        p.pledgedShares -= uint128(shares);

        VAULT_STETH.burn(msg.sender, shares);

        emit Unpledged(dashboard, msg.sender, shares);
    }

    // ============================================================================
    //                            Priority queue management
    // ============================================================================

    /// @notice Mark a dashboard for liquidation. Permissionless, but ONLY succeeds if the
    ///         borrower's AAVE healthFactor is strictly below 1e18.
    /// @dev    This is the FIRST half of the invariant: only legitimately-liquidating
    ///         borrowers ever enter the liquidation queue. The SECOND half is the re-check
    ///         in `_selectMarkedDashboard` — a borrower whose HF recovered between marking
    ///         and selection is demoted instead of drained.
    function markForLiquidation(address dashboard) external {
        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (p.bucket == 2) revert AlreadyMarked();

        uint256 hf = _healthFactor(p.borrower);
        if (hf >= HF_LIQUIDATION_THRESHOLD) revert BorrowerHealthy(hf);

        p.bucket = 2;
        liquidationQueue.push(dashboard);

        emit MarkedForLiquidation(dashboard, msg.sender, hf);
    }

    /// @notice Borrower opt-in: mark the vault for voluntary close.
    /// @dev    Only the borrower of the dashboard can call. Sets bucket = 1; bucket may
    ///         still be upgraded to 2 (liquidation) if the borrower later goes underwater.
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
    ///         calling `Dashboard.mintShares` on the next eligible dashboard.
    /// @dev    "Eligible" means in the liquidation queue with HF < 1e18 currently, OR in
    ///         the voluntary queue. Unmarked dashboards are NEVER drained by this path.
    function redeem(uint256 shares, address recipient)
        external
        nonReentrant
        returns (uint256 wstEthAmount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        address dashboard = _selectMarkedDashboard(shares);
        Pledge storage p = pledges[dashboard];

        p.pledgedShares -= uint128(shares);

        wstEthAmount = _drainDashboard(dashboard, shares, recipient);

        emit RedeemedFromDashboard(dashboard, recipient, shares, wstEthAmount);
    }

    /// @notice Borrower-only redemption against a specific dashboard. Bypasses the queues.
    ///         Lets a borrower wind down their own position even when no global liquidation
    ///         or voluntary marking is in effect.
    /// @dev    Caller MUST be `borrower[dashboard]`. We do not require `bucket != 2` —
    ///         the borrower can still self-redeem from their liquidating vault (though in
    ///         practice the liquidator would race them).
    function selfRedeem(address dashboard, uint256 shares, address recipient)
        external
        nonReentrant
        returns (uint256 wstEthAmount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        Pledge storage p = pledges[dashboard];
        if (!p.registered) revert NotRegistered();
        if (msg.sender != p.borrower) revert NotBorrower();
        if (shares > p.pledgedShares) revert InsufficientPledgedShares();

        p.pledgedShares -= uint128(shares);

        wstEthAmount = _drainDashboard(dashboard, shares, recipient);

        emit SelfRedeemed(dashboard, msg.sender, recipient, shares, wstEthAmount);
    }

    // ============================================================================
    //                          Permissionless queue maintenance
    // ============================================================================

    /// @notice Walk up to `maxIterations` heads of the liquidation queue, demoting any
    ///         whose borrower has recovered (HF >= 1e18 on AAVE). Permissionless.
    /// @dev    This exists so that demotions persist even when a subsequent `redeem` call
    ///         would revert (Solidity reverts roll back state changes). In practice the
    ///         Keeper or liquidator bot calls this to keep the queue clean.
    ///         Returns the number of dashboards demoted.
    function cleanupLiquidationQueue(uint256 maxIterations) external returns (uint256 demoted) {
        uint256 walked = 0;
        while (walked < maxIterations && liquidationHead < liquidationQueue.length) {
            address d = liquidationQueue[liquidationHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 2) {
                uint256 hf = _healthFactor(p.borrower);
                if (hf >= HF_LIQUIDATION_THRESHOLD) {
                    p.bucket = 0;
                    emit DemotedFromLiquidation(d, hf);
                    ++demoted;
                } else {
                    // Head is still valid - stop walking (queue order preserved).
                    return demoted;
                }
            }
            unchecked { ++liquidationHead; }
            ++walked;
        }
    }

    // ============================================================================
    //                              Internal helpers
    // ============================================================================

    /// @dev Pick the next eligible dashboard:
    ///        1. Liquidation queue — but re-verify HF < 1e18 at this moment. Demote any
    ///           head whose borrower has recovered.
    ///        2. Voluntary queue — borrower opted in; no HF check needed.
    ///        3. If both are exhausted: revert.
    ///      A dashboard with insufficient `pledgedShares` is skipped (advances head pointer).
    function _selectMarkedDashboard(uint256 requestedShares) internal returns (address) {
        // 1. Liquidation queue with HF re-verification.
        while (liquidationHead < liquidationQueue.length) {
            address d = liquidationQueue[liquidationHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 2 && p.pledgedShares >= requestedShares) {
                uint256 hf = _healthFactor(p.borrower);
                if (hf < HF_LIQUIDATION_THRESHOLD) {
                    return d;
                }
                // Borrower recovered between marking and selection. Demote and continue.
                p.bucket = 0;
                emit DemotedFromLiquidation(d, hf);
            }
            unchecked { ++liquidationHead; }
        }
        // 2. Voluntary queue.
        while (voluntaryHead < voluntaryQueue.length) {
            address d = voluntaryQueue[voluntaryHead];
            Pledge storage p = pledges[d];
            if (p.bucket == 1 && p.pledgedShares >= requestedShares) {
                return d;
            }
            unchecked { ++voluntaryHead; }
        }
        revert NoEligibleDashboard();
    }

    /// @dev Common drain logic: mint stETH on the chosen dashboard, wrap to wstETH, forward.
    function _drainDashboard(address dashboard, uint256 shares, address recipient)
        internal
        returns (uint256 wstEthAmount)
    {
        VAULT_STETH.burn(msg.sender, shares);

        uint256 sharesWithBuffer = shares + MINT_BUFFER_SHARES;
        IDashboard(dashboard).mintShares(address(this), sharesWithBuffer);

        uint256 stEthReceived = STETH.balanceOf(address(this));
        uint256 wstEthMinted = WSTETH.wrap(stEthReceived);

        wstEthAmount = WSTETH.getWstETHByStETH(STETH.getPooledEthByShares(shares));
        if (wstEthAmount > wstEthMinted) {
            wstEthAmount = wstEthMinted;
        }

        WSTETH.safeTransfer(recipient, wstEthAmount);
    }

    /// @dev Read borrower's healthFactor from AAVE. Reverts on AAVE failure (intentional —
    ///      a non-reachable AAVE means we cannot safely authorize liquidation drains).
    function _healthFactor(address borrower) internal view returns (uint256) {
        (,,,,, uint256 hf) = AAVE_POOL.getUserAccountData(borrower);
        return hf;
    }

    // ============================================================================
    //                                  Views
    // ============================================================================

    function queueLengths()
        external
        view
        returns (uint256 liquidationLen, uint256 voluntaryLen)
    {
        liquidationLen = liquidationQueue.length - liquidationHead;
        voluntaryLen = voluntaryQueue.length - voluntaryHead;
    }

    /// @notice Read-only walker. Returns address(0) if nothing is currently drainable via
    ///         `redeem`. Does NOT mutate state — but note that the actual `redeem` call
    ///         will re-verify HF and may demote borrowers, so the returned address is a
    ///         "best guess" rather than a guaranteed selection.
    function nextDashboard() external view returns (address) {
        uint256 i = liquidationHead;
        while (i < liquidationQueue.length) {
            address d = liquidationQueue[i];
            Pledge storage p = pledges[d];
            if (p.bucket == 2 && p.pledgedShares > 0) {
                (,,,,, uint256 hf) = AAVE_POOL.getUserAccountData(p.borrower);
                if (hf < HF_LIQUIDATION_THRESHOLD) return d;
            }
            unchecked { ++i; }
        }
        i = voluntaryHead;
        while (i < voluntaryQueue.length) {
            address d = voluntaryQueue[i];
            Pledge storage p = pledges[d];
            if (p.bucket == 1 && p.pledgedShares > 0) return d;
            unchecked { ++i; }
        }
        return address(0);
    }
}
