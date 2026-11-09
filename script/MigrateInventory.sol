// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {OrderV4} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibInventoryMigration, MigrationPlan, AdminCall} from "./lib/LibInventoryMigration.sol";

/// @notice Admin call `index` reverted in the simulation.
error MigrationCallFailed(uint256 index, bytes reason);
/// @notice `MIGRATION_MODE` is not "", "resume" or "check".
error UnknownMigrationMode(string mode);

/// @title MigrateInventory
/// @notice Prints the admin transactions that move a pool from a V6
/// `RaindexInventory` to a V7 one, after it runs them on a fork as the admin
/// and checks the end state (`LibInventoryMigration.verify`). It never
/// broadcasts: the admin signs the printed calls. Run it with `--fork-url` (or
/// `--rpc-url`) and no `--broadcast`.
///
/// The move has two signing rounds. While the old inventory still has a plan
/// operator or a live plan order, the script prints only the freeze
/// transaction to sign, and previews the rest. Sign the freeze, run the script
/// again, and sign the calls it prints then: their amounts are read from the
/// frozen vaults, so they are exact. The script prints `SIGN NOW` only after
/// the whole move ran on the fork and passed `verify`.
///
/// After the drain landed, a normal run reverts `OldInventoryAlreadyDrained`.
/// `MIGRATION_MODE=resume` then builds only the approve and new-inventory
/// calls from the plan's `moved` amounts. Take them from a normal run pinned
/// to the block before the drain (`--fork-block-number`), where the vaults
/// were frozen. Any other `MIGRATION_MODE` value reverts. `MIGRATION_MODE=check` only
/// checks the end state on the chain from `moved`. Run it on a fork pinned to
/// the block of the last move transaction, before trading can change a vault.
///
/// Env: `MIGRATION_PLAN`, the path of a JSON file under `.tmp/` with:
/// - `admin`: the account that holds `DEFAULT_ADMIN_ROLE` on both inventories.
/// - `oldInventory`, `newInventory`: addresses.
/// - `tokens`, `vaultIds`: vault `i` is `(tokens[i], vaultIds[i])`.
/// - `removeOrderEvents`: the `data` of each `AddOrderV3` log in which V6
///   Raindex added an order for the old inventory. Orders that are no longer
///   live are skipped.
/// - `addOrderCalls`: `addOrder5` calldata for each order, built again for V7.
/// - `revokeOperators`, `grantOperators`: addresses.
/// - `moved` (resume and check modes): the amounts that the drain moved, as
///   printed by the run whose calls were signed.
contract MigrateInventory is Script {
    function run() external {
        runWith(vm.envString("MIGRATION_PLAN"), vm.envOr("MIGRATION_MODE", string("")));
    }

    /// @notice `run` with the plan path and mode as arguments: "" (the move),
    /// "resume" or "check".
    function runWith(string memory planPath, string memory modeName) public {
        string memory json = vm.readFile(planPath);
        MigrationPlan memory plan = parsePlan(json);
        address admin = vm.parseJsonAddress(json, ".admin");
        bytes32 mode = keccak256(bytes(modeName));

        if (mode == keccak256("check")) {
            LibInventoryMigration.verify(plan, vm.parseJsonUintArray(json, ".moved"));
            console2.log("check: live end state verified");
            return;
        }
        if (mode == keccak256("resume")) {
            uint256[] memory saved = vm.parseJsonUintArray(json, ".moved");
            AdminCall[] memory rest = LibInventoryMigration.resumeCalls(plan, saved, admin);
            simulate(admin, rest);
            LibInventoryMigration.verify(plan, saved);
            console2.log("simulation: end state verified");
            console2.log("SIGN NOW, in order (resume after the drain):");
            _printAmounts(plan, saved);
            _printCalls(rest);
            return;
        }

        if (mode != keccak256("")) revert UnknownMigrationMode(modeName);
        LibInventoryMigration.checkPlan(plan);
        bool freeze = LibInventoryMigration.needsFreeze(plan);
        AdminCall[] memory first = new AdminCall[](freeze ? 1 : 0);
        if (freeze) {
            first[0] = LibInventoryMigration.freezeCall(plan);
            simulate(admin, first);
        }
        uint256[] memory moved = LibInventoryMigration.amounts(plan);
        AdminCall[] memory txs = LibInventoryMigration.calls(plan, moved);
        simulate(admin, txs);
        LibInventoryMigration.verify(plan, moved);
        console2.log("simulation: end state verified");

        if (freeze) {
            console2.log("SIGN NOW: the freeze transaction only. Then run this script again.");
            _printCalls(first);
            console2.log("PREVIEW, do not sign: the calls after the freeze");
        } else {
            console2.log("SIGN NOW, in order. Save the amounts: they are `moved`.");
        }
        _printAmounts(plan, moved);
        _printCalls(txs);
    }

    function _printAmounts(MigrationPlan memory plan, uint256[] memory moved) internal pure {
        for (uint256 i = 0; i < plan.tokens.length; i++) {
            console2.log("vault", plan.tokens[i], vm.toString(plan.vaultIds[i]), moved[i]);
        }
    }

    function _printCalls(AdminCall[] memory txs) internal pure {
        for (uint256 i = 0; i < txs.length; i++) {
            console2.log("tx", i, txs[i].target);
            console2.logBytes(txs[i].data);
        }
    }

    /// @notice Runs `txs` in order as `admin` on the current fork.
    function simulate(address admin, AdminCall[] memory txs) public {
        for (uint256 i = 0; i < txs.length; i++) {
            vm.prank(admin);
            (bool ok, bytes memory reason) = txs[i].target.call(txs[i].data);
            if (!ok) revert MigrationCallFailed(i, reason);
        }
    }

    /// @notice Reads a plan from the JSON described on the contract.
    function parsePlan(string memory json) public pure returns (MigrationPlan memory plan) {
        plan.oldInventory = vm.parseJsonAddress(json, ".oldInventory");
        plan.newInventory = vm.parseJsonAddress(json, ".newInventory");
        plan.tokens = vm.parseJsonAddressArray(json, ".tokens");
        plan.vaultIds = vm.parseJsonBytes32Array(json, ".vaultIds");
        bytes[] memory events = vm.parseJsonBytesArray(json, ".removeOrderEvents");
        plan.removeOrders = new OrderV4[](events.length);
        for (uint256 i = 0; i < events.length; i++) {
            plan.removeOrders[i] = decodeAddOrderEvent(events[i]);
        }
        plan.addOrderCalls = vm.parseJsonBytesArray(json, ".addOrderCalls");
        plan.revokeOperators = vm.parseJsonAddressArray(json, ".revokeOperators");
        plan.grantOperators = vm.parseJsonAddressArray(json, ".grantOperators");
    }

    /// @notice The order in the `data` of a V6 `AddOrderV3` log.
    function decodeAddOrderEvent(bytes memory data) public pure returns (OrderV4 memory order) {
        //slither-disable-next-line unused-return
        (,, order) = abi.decode(data, (address, bytes32, OrderV4));
    }
}
