// SPDX-License-Identifier: MIT
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

    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);
    event OperatorDeposit(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    error ZeroAddress();
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
    /// vault balance)`), then forwarded to `msg.sender`.
    function withdraw4(address token, bytes32 vaultId, Float targetAmount, TaskV2[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        uint256 requested = _fromFloat(targetAmount, token);
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        RAINDEX.withdraw4(token, vaultId, targetAmount, tasks);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received < requested) revert InsufficientVaultLiquidity(token, requested, received);
        if (received > 0) {
            SafeERC20.safeTransfer(IERC20(token), msg.sender, received);
            emit OperatorWithdraw(msg.sender, token, vaultId, received);
        }
    }

    /// @notice Pull `depositAmount` of `token` from the caller and deposit it
    /// into `vaultId`. The caller must have approved this contract for `token`.
    /// @dev Drop-in `IRaindexV6.deposit4` signature. We pull
    /// `toFixedDecimal(depositAmount)` from `msg.sender` using the identical
    /// conversion Raindex uses to pull from us, so the amounts line up.
    function deposit4(address token, bytes32 vaultId, Float depositAmount, TaskV2[] calldata tasks)
        external
        onlyAdminOrOperator
        whenNotPaused
        nonReentrant
    {
        uint256 amount = _fromFloat(depositAmount, token);
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

    function addOrder4(OrderConfigV4 calldata config, TaskV2[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.addOrder4(config, tasks);
    }

    function removeOrder3(OrderV4 calldata order, TaskV2[] calldata tasks)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        return RAINDEX.removeOrder3(order, tasks);
    }

    function entask2(TaskV2[] calldata tasks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RAINDEX.entask2(tasks);
    }

    // Views: forward so tooling can read through this address (owner = this).
    function vaultBalance2(address owner_, address token, bytes32 vaultId) external view returns (Float) {
        return RAINDEX.vaultBalance2(owner_, token, vaultId);
    }

    function orderExists(bytes32 orderHash) external view returns (bool) {
        return RAINDEX.orderExists(orderHash);
    }

    function quote2(QuoteV2 calldata quoteConfig) external view returns (bool, Float, Float) {
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

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Sweep stray balances / dust to the caller (admin).
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

    function _fromFloat(Float f, address token) internal view returns (uint256) {
        (uint256 amount,) = f.toFixedDecimalLossy(IERC20Metadata(token).decimals());
        return amount;
    }
}
