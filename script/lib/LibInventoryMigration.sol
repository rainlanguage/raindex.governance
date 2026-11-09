// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity ^0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRaindexV6} from "raindex-interface-0.1.13/src/interface/deprecated/v6/IRaindexV6.sol";
import {TaskV2} from "raindex-interface-0.1.13/src/interface/deprecated/v5/IOrderBookV5.sol";
import {IRaindexV7, OrderV4, OrderConfigV4, TaskV3} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";
import {RaindexInventory} from "../../src/RaindexInventory.sol";
import {RAINDEX_V7, RAINDEX_V7_CODEHASH} from "./RaindexV7Release.sol";

/// @dev One move of a shared pool from a V6 `RaindexInventory` to a V7 one.
/// Vault `i` is `(tokens[i], vaultIds[i])` and keeps its id on the new
/// inventory, so consumers only change the inventory address.
struct MigrationPlan {
    /// The V6 `RaindexInventory` that is retired. It exposes the V6 entry
    /// points (`withdraw4`, `removeOrder3`).
    address oldInventory;
    /// The V7 `RaindexInventory` that receives the pool.
    address newInventory;
    address[] tokens;
    bytes32[] vaultIds;
    /// The live V6 orders that the old inventory owns.
    OrderV4[] removeOrders;
    /// `addOrder5` calldata for the same strategies, built again for V7. The
    /// new inventory gets each one verbatim.
    bytes[] addOrderCalls;
    /// `OPERATOR_ROLE` holders on the old inventory.
    address[] revokeOperators;
    /// Consumers, already on the V7 entry points, that get `OPERATOR_ROLE` on
    /// the new inventory.
    address[] grantOperators;
}

/// @dev One transaction the admin signs: `target.call(data)`.
struct AdminCall {
    address target;
    bytes data;
}

/// @title LibInventoryMigration
/// @notice Builds the admin transactions that move a pool from a V6
/// `RaindexInventory` to a V7 one, and checks the end state. The admin is one
/// account that holds `DEFAULT_ADMIN_ROLE` on both inventories. It signs, in
/// order:
/// 1. Freeze (`freezeCall`): `oldInventory.multicall` revokes every old
///    operator and removes every live order. After it, nothing but the admin
///    can change the old vaults, so the amounts are read only after it lands.
/// 2. Drain (`calls`): `oldInventory.multicall` withdraws every vault to the
///    admin, then `pause()`. The amounts are exact: a vault that holds less
///    reverts the batch, and a frozen vault cannot hold more.
/// 3. `token.approve(newInventory, total)` once for each token.
/// 4. `newInventory.multicall`: deposit every amount into the same vault id,
///    add every V7 order, and grant every new operator.
library LibInventoryMigration {
    using LibDecimalFloat for Float;

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    error VaultLengthMismatch(uint256 tokens, uint256 vaultIds);
    error DuplicateVault(address token, bytes32 vaultId);
    error OrderNotOwnedByOldInventory(bytes32 orderHash, address owner);
    error NotAddOrder5Call(uint256 index);
    error VaultNotMoved(address token, bytes32 vaultId, uint256 expected, uint256 actual);
    error VaultNotEmptied(address token, bytes32 vaultId, uint256 left);
    error OrderStillLive(bytes32 orderHash);
    error OrderMissing(bytes32 orderHash);
    error OperatorStillOnOld(address operator);
    error OperatorMissingOnNew(address operator);
    error OldInventoryNotPaused();
    error NewInventoryNotOnV7(address raindex, bytes32 codehash);
    error OldInventoryAlreadyDrained();
    error OldInventoryNotDrained();
    error MovedLengthMismatch(uint256 vaults, uint256 moved);

    /// @notice Raindex's order hash.
    function orderHash(OrderV4 memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    /// @notice The order that an `addOrder5` call creates for `owner`.
    function addedOrder(bytes memory addOrderCall, address owner, uint256 index)
        internal
        pure
        returns (OrderV4 memory)
    {
        // Truncating to the leading 4 bytes is the point: that is the selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (addOrderCall.length < 4 || bytes4(addOrderCall) != IRaindexV7.addOrder5.selector) {
            revert NotAddOrder5Call(index);
        }
        bytes memory args = new bytes(addOrderCall.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = addOrderCall[i + 4];
        }
        // The config is the first argument; the tasks after it are not needed.
        OrderConfigV4 memory config = abi.decode(args, (OrderConfigV4));
        return OrderV4(owner, config.evaluable, config.validInputs, config.validOutputs, config.nonce);
    }

    /// @notice A vault's balance on `inventory`, floored to raw token units.
    function rawVaultBalance(address inventory, address token, bytes32 vaultId) internal view returns (uint256) {
        Float balance = IRaindexV7(inventory).vaultBalance2(inventory, token, vaultId);
        //slither-disable-next-line unused-return
        (uint256 raw,) = balance.toFixedDecimalLossy(IERC20Metadata(token).decimals());
        return raw;
    }

    /// @notice Checks the plan's shape and reads the raw amount that each
    /// vault moves: its current old-inventory balance, floored. A
    /// sub-raw-unit remainder stays on V6. Read it after the freeze lands.
    function amounts(MigrationPlan memory plan) internal view returns (uint256[] memory moved) {
        // A paused old inventory is already drained: its vaults read zero, so
        // a move built now would deposit nothing. Resume from the saved
        // amounts instead (`resumeCalls`).
        if (Pausable(plan.oldInventory).paused()) revert OldInventoryAlreadyDrained();
        checkPlan(plan);
        moved = new uint256[](plan.tokens.length);
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            moved[i] = rawVaultBalance(plan.oldInventory, plan.tokens[i], plan.vaultIds[i]);
        }
    }

    /// @notice Reverts unless the plan is well formed: the new inventory is on
    /// the released V7, vault lists match with no duplicate, and every order
    /// to remove belongs to the old inventory.
    function checkPlan(MigrationPlan memory plan) internal view {
        address raindex = address(RaindexInventory(plan.newInventory).RAINDEX());
        if (raindex != RAINDEX_V7 || raindex.codehash != RAINDEX_V7_CODEHASH) {
            revert NewInventoryNotOnV7(raindex, raindex.codehash);
        }
        if (plan.tokens.length != plan.vaultIds.length) {
            revert VaultLengthMismatch(plan.tokens.length, plan.vaultIds.length);
        }
        for (uint256 i = 0; i < plan.removeOrders.length; i++) {
            if (plan.removeOrders[i].owner != plan.oldInventory) {
                revert OrderNotOwnedByOldInventory(orderHash(plan.removeOrders[i]), plan.removeOrders[i].owner);
            }
        }
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (plan.tokens[j] == plan.tokens[i] && plan.vaultIds[j] == plan.vaultIds[i]) {
                    revert DuplicateVault(plan.tokens[i], plan.vaultIds[i]);
                }
            }
        }
    }

    /// @notice Whether the old inventory still has a plan operator or a live
    /// plan order, so the freeze transaction is still needed.
    function needsFreeze(MigrationPlan memory plan) internal view returns (bool) {
        for (uint256 i = 0; i < plan.revokeOperators.length; i++) {
            if (IAccessControl(plan.oldInventory).hasRole(OPERATOR_ROLE, plan.revokeOperators[i])) return true;
        }
        for (uint256 i = 0; i < plan.removeOrders.length; i++) {
            if (IRaindexV6(plan.oldInventory).orderExists(orderHash(plan.removeOrders[i]))) return true;
        }
        return false;
    }

    /// @notice The freeze transaction: revoke every old operator and remove
    /// every live order. Orders that are no longer live are skipped.
    function freezeCall(MigrationPlan memory plan) internal view returns (AdminCall memory) {
        uint256 liveOrders = 0;
        for (uint256 i = 0; i < plan.removeOrders.length; i++) {
            if (IRaindexV6(plan.oldInventory).orderExists(orderHash(plan.removeOrders[i]))) liveOrders++;
        }
        bytes[] memory batch = new bytes[](plan.revokeOperators.length + liveOrders);
        uint256 batchIndex = 0;
        for (uint256 i = 0; i < plan.revokeOperators.length; i++) {
            batch[batchIndex++] = abi.encodeCall(IAccessControl.revokeRole, (OPERATOR_ROLE, plan.revokeOperators[i]));
        }
        for (uint256 i = 0; i < plan.removeOrders.length; i++) {
            if (IRaindexV6(plan.oldInventory).orderExists(orderHash(plan.removeOrders[i]))) {
                batch[batchIndex++] = abi.encodeCall(IRaindexV6.removeOrder3, (plan.removeOrders[i], new TaskV2[](0)));
            }
        }
        return AdminCall(plan.oldInventory, abi.encodeCall(Multicall.multicall, (batch)));
    }

    /// @notice The admin transactions after the freeze, in signing order.
    function calls(MigrationPlan memory plan, uint256[] memory moved) internal view returns (AdminCall[] memory out) {
        (address[] memory approveTokens, uint256[] memory approveTotals) = _tokenTotals(plan, moved);
        out = new AdminCall[](2 + approveTokens.length);
        out[0] = AdminCall(plan.oldInventory, abi.encodeCall(Multicall.multicall, (_oldInventoryCalls(plan, moved))));
        for (uint256 i = 0; i < approveTokens.length; i++) {
            out[1 + i] =
                AdminCall(approveTokens[i], abi.encodeCall(IERC20.approve, (plan.newInventory, approveTotals[i])));
        }
        out[out.length - 1] =
            AdminCall(plan.newInventory, abi.encodeCall(Multicall.multicall, (_newInventoryCalls(plan, moved))));
    }

    /// @notice After the drain landed: the approve and new-inventory calls
    /// from the saved `moved` amounts, without the drain. Reverts unless the
    /// old inventory is paused (drained).
    function resumeCalls(MigrationPlan memory plan, uint256[] memory moved)
        internal
        view
        returns (AdminCall[] memory out)
    {
        if (!Pausable(plan.oldInventory).paused()) revert OldInventoryNotDrained();
        checkPlan(plan);
        if (moved.length != plan.tokens.length) revert MovedLengthMismatch(plan.tokens.length, moved.length);
        AdminCall[] memory all = calls(plan, moved);
        out = new AdminCall[](all.length - 1);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = all[i + 1];
        }
    }

    /// @notice Reverts unless the end state is the planned one: every vault
    /// amount is on the new inventory and the old vault is empty, every old
    /// order is gone and every V7 order is live under the new inventory, the
    /// operators hold the role on the new inventory only, and the old
    /// inventory is paused.
    function verify(MigrationPlan memory plan, uint256[] memory moved) internal view {
        if (moved.length != plan.tokens.length) revert MovedLengthMismatch(plan.tokens.length, moved.length);
        // The old side first: a leftover on V6 is the failure that trading on
        // V7 cannot cause.
        if (!Pausable(plan.oldInventory).paused()) revert OldInventoryNotPaused();
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            uint256 left = rawVaultBalance(plan.oldInventory, plan.tokens[i], plan.vaultIds[i]);
            if (left != 0) revert VaultNotEmptied(plan.tokens[i], plan.vaultIds[i], left);
        }
        for (uint256 i = 0; i < plan.removeOrders.length; i++) {
            bytes32 hash = orderHash(plan.removeOrders[i]);
            if (IRaindexV6(plan.oldInventory).orderExists(hash)) revert OrderStillLive(hash);
        }
        for (uint256 i = 0; i < plan.revokeOperators.length; i++) {
            if (IAccessControl(plan.oldInventory).hasRole(OPERATOR_ROLE, plan.revokeOperators[i])) {
                revert OperatorStillOnOld(plan.revokeOperators[i]);
            }
        }
        for (uint256 i = 0; i < plan.grantOperators.length; i++) {
            if (IAccessControl(plan.oldInventory).hasRole(OPERATOR_ROLE, plan.grantOperators[i])) {
                revert OperatorStillOnOld(plan.grantOperators[i]);
            }
            if (!IAccessControl(plan.newInventory).hasRole(OPERATOR_ROLE, plan.grantOperators[i])) {
                revert OperatorMissingOnNew(plan.grantOperators[i]);
            }
        }
        for (uint256 i = 0; i < plan.addOrderCalls.length; i++) {
            bytes32 hash = orderHash(addedOrder(plan.addOrderCalls[i], plan.newInventory, i));
            if (!IRaindexV7(plan.newInventory).orderExists(hash)) revert OrderMissing(hash);
        }
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            uint256 got = rawVaultBalance(plan.newInventory, plan.tokens[i], plan.vaultIds[i]);
            if (got != moved[i]) revert VaultNotMoved(plan.tokens[i], plan.vaultIds[i], moved[i], got);
        }
    }

    function _oldInventoryCalls(MigrationPlan memory plan, uint256[] memory moved)
        private
        view
        returns (bytes[] memory batch)
    {
        batch = new bytes[](_nonZero(moved) + 1);
        uint256 batchIndex = 0;
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            if (moved[i] == 0) continue;
            batch[batchIndex++] = abi.encodeCall(
                IRaindexV6.withdraw4,
                (plan.tokens[i], plan.vaultIds[i], _float(plan.tokens[i], moved[i]), new TaskV2[](0))
            );
        }
        batch[batchIndex] = abi.encodeWithSignature("pause()");
    }

    function _newInventoryCalls(MigrationPlan memory plan, uint256[] memory moved)
        private
        view
        returns (bytes[] memory batch)
    {
        batch = new bytes[](_nonZero(moved) + plan.addOrderCalls.length + plan.grantOperators.length);
        uint256 batchIndex = 0;
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            if (moved[i] == 0) continue;
            batch[batchIndex++] = abi.encodeCall(
                IRaindexV7.deposit5,
                (plan.tokens[i], plan.vaultIds[i], _float(plan.tokens[i], moved[i]), new TaskV3[](0))
            );
        }
        for (uint256 i = 0; i < plan.addOrderCalls.length; i++) {
            // Checks the selector so a wrong entry fails here, not on chain.
            addedOrder(plan.addOrderCalls[i], plan.newInventory, i);
            batch[batchIndex++] = plan.addOrderCalls[i];
        }
        for (uint256 i = 0; i < plan.grantOperators.length; i++) {
            batch[batchIndex++] = abi.encodeCall(IAccessControl.grantRole, (OPERATOR_ROLE, plan.grantOperators[i]));
        }
    }

    function _tokenTotals(MigrationPlan memory plan, uint256[] memory moved)
        private
        pure
        returns (address[] memory tokens, uint256[] memory totals)
    {
        tokens = new address[](plan.tokens.length);
        totals = new uint256[](plan.tokens.length);
        uint256 tokenCount = 0;
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            if (moved[i] == 0) continue;
            uint256 j = 0;
            while (j < tokenCount && tokens[j] != plan.tokens[i]) j++;
            if (j == tokenCount) tokens[tokenCount++] = plan.tokens[i];
            totals[j] += moved[i];
        }
        assembly ("memory-safe") {
            mstore(tokens, tokenCount)
            mstore(totals, tokenCount)
        }
    }

    function _nonZero(uint256[] memory moved) private pure returns (uint256 count) {
        for (uint256 i = 0; i < moved.length; i++) {
            if (moved[i] != 0) count++;
        }
    }

    function _float(address token, uint256 raw) private view returns (Float) {
        return LibDecimalFloat.fromFixedDecimalLosslessPacked(raw, IERC20Metadata(token).decimals());
    }
}
