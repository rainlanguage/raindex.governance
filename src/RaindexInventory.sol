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

import {
    IRaindexV7,
    OrderConfigV4,
    OrderV4,
    TaskV3,
    QuoteV3
} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";

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
///    same `IRaindexV7` signatures it would call on Raindex directly, so
///    existing Raindex tooling works by pointing at this address. `Multicall` is
///    inherited so a Raindex CLI `multicall([addOrder5, ...])` lands here
///    unchanged (delegatecall to self preserves `msg.sender`, so the admin gate
///    still applies).
///
/// 2. **Inventory operator** (`OPERATOR_ROLE`). Any address holding this role may
///    move funds in and out of the owned vaults via [`deposit5`] / [`withdraw5`].
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
/// stays admin-grantable/revocable. [`pause`] is the kill switch: while paused,
/// [`deposit5`] and [`withdraw5`] revert `EnforcedPause` for the admin and every
/// operator (a caller without a role still fails the role check first), so no
/// vault capital moves through this contract. Pause does NOT touch Raindex: the
/// orders this contract owns stay live and keep clearing against its vaults,
/// so incident response must also [`removeOrder4`] each live order. Order
/// management stays available for that reason. [`rescue`] is deliberately
/// *not* pause-gated: it only moves stray balances held by this contract, never
/// vault capital (that lives in Raindex), and must stay available for incident
/// recovery.
contract RaindexInventory is AccessControl, Pausable, ReentrancyGuard, Multicall {
    using LibDecimalFloat for Float;

    /// @notice Role allowed to [`deposit5`] / [`withdraw5`] against the owned
    /// vaults. Its admin is `DEFAULT_ADMIN_ROLE`.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice The deployed Raindex (OrderBook) this contract owns orders in.
    IRaindexV7 public immutable RAINDEX;

    /// @notice A [`withdraw5`] forwarded a nonzero `amount` of `token` to the
    /// caller. `amount` is what this contract received from Raindex for
    /// `vaultId`, which can differ from the vault debit (for example a token
    /// that over-delivers on transfer).
    /// @param operator The caller (admin or operator) the funds were sent to.
    /// @param token The token withdrawn.
    /// @param vaultId The Raindex vault drawn on.
    /// @param amount The raw token amount actually received and forwarded —
    /// the measured balance delta, not the request.
    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    /// @notice A [`deposit5`] settled: `amount` raw units of `token` were
    /// pulled from the caller and credited to `vaultId`. For a lossy Float
    /// `amount` is the rounded-up charge, and the vault is credited exactly it.
    /// @param operator The caller (admin or operator) the funds were pulled from.
    /// @param token The token deposited.
    /// @param vaultId The Raindex vault credited.
    /// @param amount The raw token amount charged to the caller (the Float
    /// converted at token decimals, rounded up when lossy).
    event OperatorDeposit(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    /// @notice A constructor argument that must be nonzero was zero.
    error ZeroAddress();

    /// @notice A [`withdraw5`] could not be covered in full by the vault, so
    /// the whole call reverted rather than short-filling the caller.
    /// @param token The token requested.
    /// @param requested The raw amount the target Float floors to at the
    /// token's decimals.
    /// @param received The raw amount the vault actually delivered (the
    /// measured balance delta).
    error InsufficientVaultLiquidity(address token, uint256 requested, uint256 received);

    /// @notice A [`withdraw5`] target floors to zero raw units at the token's
    /// decimals, so there is nothing to withdraw.
    /// @param token The token requested.
    /// @param vaultId The Raindex vault named.
    error ZeroWithdrawAmount(address token, bytes32 vaultId);

    /// @notice A caller without `DEFAULT_ADMIN_ROLE` passed non-empty `tasks`.
    /// Raindex runs tasks in this contract's state namespace, which is the
    /// namespace of every order it owns, so only the admin may send them.
    error OperatorTasksForbidden();

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

    function _onlyAdminTasks(TaskV3[] calldata tasks) internal view {
        if (tasks.length != 0 && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert OperatorTasksForbidden();
    }

    /// @param admin_ Granted `DEFAULT_ADMIN_ROLE`: owns order management, role
    /// grants, pause and rescue. MUST be nonzero.
    /// @param raindex_ The deployed Raindex (OrderBook) this contract owns its
    /// orders and vaults in. MUST be nonzero. Immutable thereafter.
    constructor(address admin_, IRaindexV7 raindex_) {
        if (admin_ == address(0) || address(raindex_) == address(0)) revert ZeroAddress();
        RAINDEX = raindex_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // ---------------------------------------------------------------------
    // Inventory movement (admin or operator; funds to / from msg.sender)
    // ---------------------------------------------------------------------

    /// @notice Withdraw `targetAmount` of `token`, floored to the token's
    /// decimals, from `vaultId` and forward everything received to the caller. Reverts if the vault could not
    /// cover the request (e.g. a concurrent Raindex clear drained it first), so a
    /// caller settling atomically never receives a short fill.
    /// @dev Drop-in `IRaindexV7.withdraw5` signature. The amount actually
    /// withdrawn is measured by balance delta (Raindex withdraws `min(target,
    /// vault balance)`), then forwarded to `msg.sender`. `targetAmount` is
    /// floored to the token's decimals before being handed to Raindex, so the
    /// vault is debited by exactly what leaves it; a target below one raw unit
    /// reverts `ZeroWithdrawAmount`.
    /// @param token The token to withdraw.
    /// @param vaultId The Raindex vault to draw on.
    /// @param targetAmount The amount to withdraw as a Raindex decimal Float.
    /// @param tasks Forwarded verbatim to Raindex to run after the withdraw.
    /// Admin only: a non-empty array from an operator reverts
    /// `OperatorTasksForbidden`.
    // The balance-delta reads around `RAINDEX.withdraw5` are how we measure the
    // actually-withdrawn amount; the function is `nonReentrant` so the external
    // call cannot re-enter.
    //slither-disable-next-line reentrancy-balance
    function withdraw5(address token, bytes32 vaultId, Float targetAmount, TaskV3[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        _onlyAdminTasks(tasks);
        // Raindex debits the vault by the Float it is given but transfers only
        // whole raw units, so it is handed the target floored to the token's
        // precision: its debit then equals what leaves the vault.
        uint8 decimals = IERC20Metadata(token).decimals();
        // Floor to token precision: the discarded `exact` bool is deliberate.
        //slither-disable-next-line unused-return
        (uint256 requested,) = targetAmount.toFixedDecimalLossy(decimals);

        // A target below one raw unit floors to zero; revert like Raindex does
        // for a zero target.
        if (requested == 0) revert ZeroWithdrawAmount(token, vaultId);

        // Reverts rather than hand Raindex a target that differs from `requested`.
        Float flooredTarget = LibDecimalFloat.fromFixedDecimalLosslessPacked(requested, decimals);
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        RAINDEX.withdraw5(token, vaultId, flooredTarget, tasks);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        // `requested >= 1` here, so a short vault always trips this and a
        // covered draw always yields `received >= requested >= 1`.
        if (received < requested) revert InsufficientVaultLiquidity(token, requested, received);
        SafeERC20.safeTransfer(IERC20(token), msg.sender, received);
        emit OperatorWithdraw(msg.sender, token, vaultId, received);
    }

    /// @notice Pull `depositAmount` of `token` from the caller and deposit it
    /// into `vaultId`. The caller must have approved this contract for `token`.
    /// @dev Drop-in `IRaindexV7.deposit5` signature. A sub-precision
    /// `depositAmount` is rounded UP to the token's decimals: the caller pays
    /// that ceiling, and Raindex is handed the ceiling as an exact Float, so
    /// the vault is credited exactly what the caller paid and Raindex pulls
    /// exactly that amount whatever its own rounding rule is.
    /// @param token The token to deposit. The caller must have approved this
    /// contract for the (rounded-up) raw amount.
    /// @param vaultId The Raindex vault to credit.
    /// @param depositAmount The amount to deposit as a Raindex decimal Float.
    /// @param tasks Forwarded verbatim to Raindex to run after the deposit.
    /// Admin only: a non-empty array from an operator reverts
    /// `OperatorTasksForbidden`.
    function deposit5(address token, bytes32 vaultId, Float depositAmount, TaskV3[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        _onlyAdminTasks(tasks);
        uint8 decimals = IERC20Metadata(token).decimals();
        (uint256 amount, bool exact) = depositAmount.toFixedDecimalLossy(decimals);
        if (!exact) amount += 1; // charge the ceiling, never less than asked
        // Lossless, so Raindex credits and pulls exactly `amount` (reverts
        // otherwise).
        Float charged = LibDecimalFloat.fromFixedDecimalLosslessPacked(amount, decimals);
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        // Exact allowance: Raindex can never pull stray balances from here.
        SafeERC20.forceApprove(IERC20(token), address(RAINDEX), amount);
        RAINDEX.deposit5(token, vaultId, charged, tasks);
        emit OperatorDeposit(msg.sender, token, vaultId, amount);
    }

    // ---------------------------------------------------------------------
    // Raindex order management (admin only, drop-in IRaindexV7 sigs)
    // ---------------------------------------------------------------------
    // Identical signatures to IRaindexV7 so existing Raindex tooling works by
    // pointing at this address. Orders/vaults are owned by this contract's
    // address — tooling queries by that owner.

    /// @notice Add an order to Raindex, owned by this contract. Drop-in
    /// `IRaindexV7.addOrder5` signature; NOT pause-gated (order management is
    /// the incident-response surface).
    /// @param config Forwarded verbatim to Raindex.
    /// @param tasks Forwarded verbatim to Raindex.
    /// @return True if the order was newly added, as reported by Raindex.
    function addOrder5(OrderConfigV4 calldata config, TaskV3[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.addOrder5(config, tasks);
    }

    /// @notice Remove one of this contract's orders from Raindex. Drop-in
    /// `IRaindexV7.removeOrder4` signature; NOT pause-gated so the admin can
    /// cancel orders mid-incident.
    /// @param order Forwarded verbatim to Raindex.
    /// @param tasks Forwarded verbatim to Raindex.
    /// @return True if the order existed and was removed, as reported by Raindex.
    function removeOrder4(OrderV4 calldata order, TaskV3[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.removeOrder4(order, tasks);
    }

    /// @notice Run tasks on Raindex as this contract. Drop-in
    /// `IRaindexV7.entask3` signature; NOT pause-gated.
    /// @param tasks Forwarded verbatim to Raindex.
    function entask3(TaskV3[] calldata tasks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RAINDEX.entask3(tasks);
    }

    // Views: forward so tooling can read through this address (owner = this).

    /// @notice Read a vault balance through this contract. Forwards verbatim
    /// to `IRaindexV7.vaultBalance2`.
    /// @param owner_ The vault owner to query (typically this contract).
    /// @param token The vault's token.
    /// @param vaultId The vault to query.
    /// @return The vault balance as a Raindex decimal Float.
    function vaultBalance2(address owner_, address token, bytes32 vaultId) external view returns (Float) {
        return RAINDEX.vaultBalance2(owner_, token, vaultId);
    }

    /// @notice Whether an order hash exists on Raindex. Forwards verbatim to
    /// `IRaindexV7.orderExists`.
    /// @param orderHash The order hash to query.
    /// @return True if the order exists.
    function orderExists(bytes32 orderHash) external view returns (bool) {
        return RAINDEX.orderExists(orderHash);
    }

    /// @notice Quote an order through this contract via `IRaindexV7.quote3`.
    /// Raindex evaluates the quote with THIS contract as the counterparty, not
    /// the original caller, so counterparty-dependent orders can quote
    /// differently than a direct Raindex call.
    /// @param quoteConfig Forwarded verbatim to Raindex.
    /// @return exists Whether the quoted order exists.
    /// @return outputMax The maximum output as a Raindex decimal Float.
    /// @return ioRatio The input:output ratio as a Raindex decimal Float.
    function quote3(QuoteV3 calldata quoteConfig) external view returns (bool exists, Float outputMax, Float ioRatio) {
        //slither-disable-next-line unused-return
        return RAINDEX.quote3(quoteConfig);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Kill switch: [`deposit5`] and [`withdraw5`] revert
    /// `EnforcedPause` for the admin and operators. Raindex keeps clearing the
    /// live orders this contract owns, so incident response must also
    /// [`removeOrder4`] them; order management stays available for that.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Lift the kill switch: [`deposit5`] / [`withdraw5`] work again.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Sweep stray balances / dust to the caller (admin). Orders placed
    /// through this contract are expected to use vaults, not vault 0
    /// (vaultless IO). A vault-0 output cannot draw on this balance, because
    /// this contract never leaves an allowance to Raindex. A vault-0 input
    /// pays its proceeds into this balance, where `vaultBalance2` does not
    /// show them and `withdraw5` cannot reach them: only `rescue` moves them
    /// out. Not pause-gated.
    /// @param token The token to sweep.
    /// @param amount The raw amount to sweep to the caller.
    function rescue(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
    }
}
