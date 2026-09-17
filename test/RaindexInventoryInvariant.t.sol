// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {InventoryHandler} from "./InventoryHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Invariant suite for `RaindexInventory` (RAI-1193), run against the
/// live Base Raindex under randomized operator/admin action sequences.
/// forge-config: default.invariant.runs = 4
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract RaindexInventoryInvariantTest is RaindexInventoryTestBase {
    InventoryHandler internal handler;

    function setUp() public override {
        super.setUp();
        address operator2 = makeAddr("operator2");
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, operator2);
        handler = new InventoryHandler(inv, RAINDEX, USDC, VAULT, admin, operator, operator2, makeAddr("stranger"));
        targetContract(address(handler));
    }

    /// @dev The inventory contract is a pass-through: at rest it holds exactly
    /// the stray donations, never pool funds.
    function invariant_inventoryHoldsOnlyStray() external view {
        assertEq(IERC20(USDC).balanceOf(address(inv)), handler.gStray(), "inventory balance != stray donations");
    }

    /// @dev Conservation: the vault always equals net settled deposits minus
    /// withdrawals — no draw ever creates or destroys value.
    function invariant_vaultEqualsNetDeposits() external view {
        assertEq(_vaultRaw(USDC, VAULT), handler.gDeposited() - handler.gWithdrawn(), "vault != net deposits");
    }

    /// @dev Closed system: everything the handler ever minted is accounted for
    /// across actor wallets, the vault, and the inventory's stray balance.
    function invariant_closedSystem() external view {
        assertEq(
            handler.actorBalances() + _vaultRaw(USDC, VAULT) + IERC20(USDC).balanceOf(address(inv)),
            handler.gDealt(),
            "value leaked from the closed system"
        );
    }

    /// @dev Pause fails closed: no deposit or withdraw ever settled while
    /// paused, across every randomized sequence.
    function invariant_pauseFailsClosed() external view {
        assertFalse(handler.pauseBypassed(), "a fund movement settled while paused");
    }

    /// @dev Over-draws revert atomically, never partially settle.
    function invariant_overdrawNeverSettles() external view {
        assertFalse(handler.overdrawSettled(), "an over-draw settled");
    }

    /// @dev RBAC: the stranger's continuous probing of every gated surface
    /// never once succeeded.
    function invariant_rbacHolds() external view {
        assertFalse(handler.rbacBypassed(), "an unauthorized call succeeded");
    }

    /// @dev Sanity on the harness itself: every success/failure matched the
    /// handler's model (paused / over-draw), so the run actually exercised
    /// what it claims.
    function invariant_modelMatchesOutcomes() external view {
        assertFalse(handler.unexpectedOutcome(), "a call outcome contradicted the model");
    }
}
