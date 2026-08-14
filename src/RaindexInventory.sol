// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IRaindexV6} from "raindex-interface-0.1.2/src/interface/IRaindexV6.sol";
import {
    OrderConfigV4,
    OrderV4,
    TaskV2,
    QuoteV2
} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";

/// @title RaindexInventory
/// @notice Holds a single pool of capital in Raindex vaults and lets more than
/// one authorised consumer draw on it, without any of them owning the orders or
/// vaults directly.
///
/// The contract plays two separate roles, gated by two separate roles:
///
/// 1. **Order/vault owner** (`DEFAULT_ADMIN_ROLE`). Because this contract is the
///    `msg.sender` to Raindex, it is the canonical owner of every order and
///    vault placed through it (Raindex forbids delegated order management). The
///    admin manages those orders/vaults *through* this contract using the exact
///    same `IRaindexV6` signatures it would call on Raindex directly, so
///    existing Raindex tooling works by pointing at this address. `Multicall` is
///    inherited so a Raindex CLI `multicall([addOrder4, ...])` lands here
///    unchanged (delegatecall to self preserves `msg.sender`, so the admin gate
///    still applies).
///
/// 2. **Inventory operator** (`OPERATOR_ROLE`). Any address holding this role may
///    move funds in and out of the owned vaults via [`deposit4`] / [`withdraw4`].
///    Funds always flow to / from the *caller*: a withdraw pulls the token out of
///    the vault into this contract and forwards it to `msg.sender`; a deposit
///    pulls the token from `msg.sender` into this contract and deposits it into
///    the vault. The contract is therefore agnostic about *why* an operator
///    needs the funds — the operator's own logic handles whatever it settles
///    against. Several operators can share the same vaults: drawing on a vault
///    that can't cover the request reverts atomically, so concurrent draws are
///    safe (the loser's transaction simply reverts).
///
/// The trust boundary is `OPERATOR_ROLE`: an operator can withdraw a vault's
/// balance to itself, so the role is only ever granted to audited contracts and
/// stays admin-grantable/revocable. [`pause`] is the kill switch — it fails all
/// operator (and admin) fund movement closed while leaving order management
/// available, so the admin can cancel orders during an incident.
contract RaindexInventory is AccessControl, Pausable, ReentrancyGuard, Multicall {
    using LibDecimalFloat for Float;

    /// @notice Role allowed to [`deposit4`] / [`withdraw4`] against the owned
    /// vaults. Its admin is `DEFAULT_ADMIN_ROLE`.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice The deployed Raindex (OrderBook) this contract owns orders in.
    IRaindexV6 public immutable RAINDEX;

    /// @notice A [`withdraw4`] settled: `amount` raw units of `token` left
    /// `vaultId` and were forwarded to the caller.
    /// @param operator The caller (admin or operator) the funds were sent to.
    /// @param token The token withdrawn.
    /// @param vaultId The Raindex vault drawn on.
    /// @param amount The raw token amount actually received and forwarded —
    /// the measured balance delta, not the request.
    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    /// @notice A [`deposit4`] settled: `amount` raw units of `token` were
    /// pulled from the caller and deposited into `vaultId`.
    /// @param operator The caller (admin or operator) the funds were pulled from.
    /// @param token The token deposited.
    /// @param vaultId The Raindex vault credited.
    /// @param amount The raw token amount charged to the caller (the Float
    /// converted at token decimals, rounded up when lossy).
    event OperatorDeposit(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    /// @notice A constructor argument that must be nonzero was zero.
    error ZeroAddress();

    /// @notice A [`withdraw4`] could not be covered in full by the vault, so
    /// the whole call reverted rather than short-filling the caller.
    /// @param token The token requested.
    /// @param requested The raw amount the target Float floors to at the
    /// token's decimals.
    /// @param received The raw amount the vault actually delivered (the
    /// measured balance delta).
    error InsufficientVaultLiquidity(address token, uint256 requested, uint256 received);

    /// @dev Passes for `DEFAULT_ADMIN_ROLE` or `OPERATOR_ROLE`. Admins can move
    /// funds for management; operators for whatever they settle against.
    modifier onlyAdminOrOperator() {
        _onlyAdminOrOperator();
        _;
    }

    function _onlyAdminOrOperator() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, OPERATOR_ROLE);
        }
    }

    /// @param admin_ Granted `DEFAULT_ADMIN_ROLE`: owns order management, role
    /// grants, pause and rescue. MUST be nonzero.
    /// @param raindex_ The deployed Raindex (OrderBook) this contract owns its
    /// orders and vaults in. MUST be nonzero. Immutable thereafter.
    constructor(address admin_, IRaindexV6 raindex_) {
        if (admin_ == address(0) || address(raindex_) == address(0)) revert ZeroAddress();
        RAINDEX = raindex_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // ---------------------------------------------------------------------
    // Inventory movement (admin or operator; funds to / from msg.sender)
    // ---------------------------------------------------------------------

    /// @notice Withdraw up to `targetAmount` of `token` from `vaultId` and
    /// forward everything received to the caller. Reverts if the vault could not
    /// cover the request (e.g. a concurrent Raindex clear drained it first), so a
    /// caller settling atomically never receives a short fill.
    /// @dev Drop-in `IRaindexV6.withdraw4` signature. The amount actually
    /// withdrawn is measured by balance delta (Raindex withdraws `min(target,
    /// vault balance)`), then forwarded to `msg.sender`. `targetAmount` is
    /// floored to the token's decimals before being handed to Raindex, so the
    /// vault is debited by exactly what leaves it; a target below one raw unit
    /// is a no-op.
    /// @param token The token to withdraw.
    /// @param vaultId The Raindex vault to draw on.
    /// @param targetAmount The amount to withdraw as a Raindex decimal Float.
    /// @param tasks Forwarded verbatim to Raindex to run after the withdraw.
    // The balance-delta reads around `RAINDEX.withdraw4` are how we measure the
    // actually-withdrawn amount; the function is `nonReentrant` so the external
    // call cannot re-enter.
    //slither-disable-next-line reentrancy-balance
    function withdraw4(address token, bytes32 vaultId, Float targetAmount, TaskV2[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        // Floor the target to the token's precision and hand Raindex THAT
        // float, not the caller's raw `targetAmount`. Raindex debits the vault
        // by the float it is given but can only transfer whole raw units, so a
        // sub-precision `targetAmount` would have it debit more than it moves —
        // the remainder burned from the shared pool with no revert (the floored
        // `requested` never trips the liquidity check). Passing the floored
        // float keeps Raindex's debit equal to what actually leaves the vault.
        uint8 decimals = IERC20Metadata(token).decimals();
        // Floor to token precision: the discarded `exact` bool is deliberate.
        //slither-disable-next-line unused-return
        (uint256 requested,) = targetAmount.toFixedDecimalLossy(decimals);

        // A target below one raw unit floors to zero: nothing can be withdrawn.
        // Return without touching Raindex — a zero-float withdraw would either
        // revert or, worse, burn the sub-unit remainder from the vault. Nothing
        // moves, nothing is lost.
        if (requested == 0) return;

        // Re-pack the floored raw amount; exact for any real balance.
        //slither-disable-next-line unused-return
        (Float flooredTarget,) = LibDecimalFloat.fromFixedDecimalLossyPacked(requested, decimals);
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        RAINDEX.withdraw4(token, vaultId, flooredTarget, tasks);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        // `requested >= 1` here, so a short vault always trips this and a
        // covered draw always yields `received >= requested >= 1`.
        if (received < requested) revert InsufficientVaultLiquidity(token, requested, received);
        SafeERC20.safeTransfer(IERC20(token), msg.sender, received);
        emit OperatorWithdraw(msg.sender, token, vaultId, received);
    }

    /// @notice Pull `depositAmount` of `token` from the caller and deposit it
    /// into `vaultId`. The caller must have approved this contract for `token`.
    /// @dev Drop-in `IRaindexV6.deposit4` signature. Raindex's `pullTokens`
    /// converts the `Float` to raw units and **rounds a lossy truncation UP**
    /// (it pulls `toFixedDecimal(depositAmount)` and adds 1 when the conversion
    /// wasn't exact). We must pull that same rounded-UP amount from the caller,
    /// otherwise for a sub-precision Float the extra unit Raindex takes from us
    /// would come out of this contract's own balance (the shared pool) — or the
    /// deposit would revert. So we round up here to match, byte-for-byte, what
    /// Raindex will pull from us.
    /// @param token The token to deposit. The caller must have approved this
    /// contract for the (rounded-up) raw amount.
    /// @param vaultId The Raindex vault to credit.
    /// @param depositAmount The amount to deposit as a Raindex decimal Float.
    /// @param tasks Forwarded verbatim to Raindex to run after the deposit.
    function deposit4(address token, bytes32 vaultId, Float depositAmount, TaskV2[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        (uint256 amount, bool exact) = depositAmount.toFixedDecimalLossy(IERC20Metadata(token).decimals());
        if (!exact) amount += 1; // mirror Raindex pullTokens' round-up
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        _ensureRaindexApproval(token, amount);
        RAINDEX.deposit4(token, vaultId, depositAmount, tasks);
        emit OperatorDeposit(msg.sender, token, vaultId, amount);
    }

    // ---------------------------------------------------------------------
    // Raindex order management (admin only, drop-in IRaindexV6 sigs)
    // ---------------------------------------------------------------------
    // Identical signatures to IRaindexV6 so existing Raindex tooling works by
    // pointing at this address. Orders/vaults are owned by this contract's
    // address — tooling queries by that owner.

    /// @notice Add an order to Raindex, owned by this contract. Drop-in
    /// `IRaindexV6.addOrder4` signature; NOT pause-gated (order management is
    /// the incident-response surface).
    /// @param config Forwarded verbatim to Raindex.
    /// @param tasks Forwarded verbatim to Raindex.
    /// @return True if the order was newly added, as reported by Raindex.
    function addOrder4(OrderConfigV4 calldata config, TaskV2[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.addOrder4(config, tasks);
    }

    /// @notice Remove one of this contract's orders from Raindex. Drop-in
    /// `IRaindexV6.removeOrder3` signature; NOT pause-gated so the admin can
    /// cancel orders mid-incident.
    /// @param order Forwarded verbatim to Raindex.
    /// @param tasks Forwarded verbatim to Raindex.
    /// @return True if the order existed and was removed, as reported by Raindex.
    function removeOrder3(OrderV4 calldata order, TaskV2[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.removeOrder3(order, tasks);
    }

    /// @notice Run tasks on Raindex as this contract. Drop-in
    /// `IRaindexV6.entask2` signature; NOT pause-gated.
    /// @param tasks Forwarded verbatim to Raindex.
    function entask2(TaskV2[] calldata tasks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RAINDEX.entask2(tasks);
    }

    // Views: forward so tooling can read through this address (owner = this).

    /// @notice Read a vault balance through this contract. Forwards verbatim
    /// to `IRaindexV6.vaultBalance2`.
    /// @param owner_ The vault owner to query (typically this contract).
    /// @param token The vault's token.
    /// @param vaultId The vault to query.
    /// @return The vault balance as a Raindex decimal Float.
    function vaultBalance2(address owner_, address token, bytes32 vaultId) external view returns (Float) {
        return RAINDEX.vaultBalance2(owner_, token, vaultId);
    }

    /// @notice Whether an order hash exists on Raindex. Forwards verbatim to
    /// `IRaindexV6.orderExists`.
    /// @param orderHash The order hash to query.
    /// @return True if the order exists.
    function orderExists(bytes32 orderHash) external view returns (bool) {
        return RAINDEX.orderExists(orderHash);
    }

    /// @notice Quote an order through this contract. Forwards verbatim to
    /// `IRaindexV6.quote2`.
    /// @param quoteConfig Forwarded verbatim to Raindex.
    /// @return exists Whether the quoted order exists.
    /// @return outputMax The maximum output as a Raindex decimal Float.
    /// @return ioRatio The input:output ratio as a Raindex decimal Float.
    function quote2(QuoteV2 calldata quoteConfig) external view returns (bool exists, Float outputMax, Float ioRatio) {
        //slither-disable-next-line unused-return
        return RAINDEX.quote2(quoteConfig);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Kill switch — fails [`deposit4`] / [`withdraw4`] closed. Order
    /// management is left available so the admin can cancel orders during an
    /// incident.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Lift the kill switch: [`deposit4`] / [`withdraw4`] work again.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Sweep stray balances / dust to the caller (admin). The contract
    /// never holds funds at rest — vault capital lives in Raindex — so
    /// anything here is a donation or mistake. Not pause-gated.
    /// @param token The token to sweep.
    /// @param amount The raw amount to sweep to the caller.
    function rescue(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _ensureRaindexApproval(address token, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), address(RAINDEX)) < amount) {
            SafeERC20.forceApprove(IERC20(token), address(RAINDEX), type(uint256).max);
        }
    }
}
