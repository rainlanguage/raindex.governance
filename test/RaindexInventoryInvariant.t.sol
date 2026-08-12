// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV6} from "raindex-interface-0.1.2/src/interface/IRaindexV6.sol";
import {TaskV2} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Randomized driver for the invariant run. Two operators, the admin and
/// a stranger act on one shared vault of the live Base Raindex through the
/// inventory: deposits, withdrawals (including over-draws), pause/unpause,
/// stray donations, rescues, and unauthorized probes. Expected failures are
/// caught and CHECKED here; every unexpected outcome latches a violation flag
/// that the invariants assert on.
contract InventoryHandler is Test {
    using LibDecimalFloat for Float;

    RaindexInventory internal immutable INV;
    IRaindexV6 internal immutable RAINDEX_;
    address internal immutable USDC_;
    bytes32 internal immutable VAULT_;
    address internal immutable ADMIN;
    address internal immutable STRANGER;
    address[2] internal operators;

    // Ghost accounting.
    uint256 public gDealt; // total USDC minted into the system by the handler
    uint256 public gDeposited; // total raw USDC deposited into the vault
    uint256 public gWithdrawn; // total raw USDC withdrawn from the vault
    uint256 public gStray; // raw USDC donated directly to the inventory, minus rescues

    // Violation latches (asserted by the invariants).
    bool public pauseBypassed; // a fund movement succeeded while paused
    bool public overdrawSettled; // an over-draw did not revert
    bool public rbacBypassed; // an unauthorized call succeeded
    bool public unexpectedOutcome; // a call succeeded/failed against expectation

    constructor(
        RaindexInventory inv_,
        IRaindexV6 raindex_,
        address usdc_,
        bytes32 vaultId_,
        address admin_,
        address op1_,
        address op2_,
        address stranger_
    ) {
        INV = inv_;
        RAINDEX_ = raindex_;
        USDC_ = usdc_;
        VAULT_ = vaultId_;
        ADMIN = admin_;
        operators = [op1_, op2_];
        STRANGER = stranger_;
    }

    function _vaultRaw() internal view returns (uint256) {
        Float bal = RAINDEX_.vaultBalance2(address(INV), USDC_, VAULT_);
        (uint256 amount,) = bal.toFixedDecimalLossy(6);
        return amount;
    }

    function _float(uint256 amount) internal pure returns (Float f) {
        (f,) = LibDecimalFloat.fromFixedDecimalLossyPacked(amount, 6);
    }

    function _fund(address who, uint256 amount) internal {
        deal(USDC_, who, IERC20(USDC_).balanceOf(who) + amount);
        gDealt += amount;
    }

    function deposit(uint256 opSeed, uint256 amount) external {
        address op = operators[opSeed % 2];
        amount = bound(amount, 1, 1e10);
        _fund(op, amount);
        vm.startPrank(op);
        IERC20(USDC_).approve(address(INV), amount);
        bool expectFail = INV.paused();
        try INV.deposit4(USDC_, VAULT_, _float(amount), new TaskV2[](0)) {
            if (expectFail) pauseBypassed = true;
            gDeposited += amount;
        } catch {
            if (!expectFail) unexpectedOutcome = true;
        }
        vm.stopPrank();
    }

    function withdraw(uint256 opSeed, uint256 amount) external {
        address op = operators[opSeed % 2];
        amount = bound(amount, 1, 2e10); // deliberately allows over-draw attempts
        uint256 vaultBefore = _vaultRaw();
        bool paused = INV.paused();
        bool overdraw = amount > vaultBefore;
        vm.prank(op);
        try INV.withdraw4(USDC_, VAULT_, _float(amount), new TaskV2[](0)) {
            if (paused) pauseBypassed = true;
            if (overdraw) overdrawSettled = true;
            gWithdrawn += amount;
        } catch {
            if (!paused && !overdraw) unexpectedOutcome = true;
        }
    }

    function togglePause(bool toPaused) external {
        vm.startPrank(ADMIN);
        if (toPaused && !INV.paused()) INV.pause();
        else if (!toPaused && INV.paused()) INV.unpause();
        vm.stopPrank();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e9);
        _fund(address(this), amount);
        IERC20(USDC_).transfer(address(INV), amount);
        gStray += amount;
    }

    function rescue(uint256 amount) external {
        amount = bound(amount, 0, gStray);
        vm.prank(ADMIN);
        INV.rescue(USDC_, amount);
        gStray -= amount;
    }

    /// @dev The stranger constantly probes every gated surface; any success is
    /// an RBAC violation.
    function strangerProbe(uint256 amount) external {
        amount = bound(amount, 1, 1e9);
        vm.startPrank(STRANGER);
        try INV.withdraw4(USDC_, VAULT_, _float(amount), new TaskV2[](0)) {
            rbacBypassed = true;
        } catch {}
        try INV.deposit4(USDC_, VAULT_, _float(amount), new TaskV2[](0)) {
            rbacBypassed = true;
        } catch {}
        try INV.rescue(USDC_, amount) {
            rbacBypassed = true;
        } catch {}
        try INV.pause() {
            rbacBypassed = true;
        } catch {}
        try INV.unpause() {
            rbacBypassed = true;
        } catch {}
        vm.stopPrank();
    }

    function actorBalances() external view returns (uint256 total) {
        total = IERC20(USDC_).balanceOf(operators[0]) + IERC20(USDC_).balanceOf(operators[1])
            + IERC20(USDC_).balanceOf(ADMIN) + IERC20(USDC_).balanceOf(STRANGER) + IERC20(USDC_).balanceOf(address(this));
    }
}

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
        handler = new InventoryHandler(
            inv, RAINDEX, USDC, VAULT, admin, operator, operator2, makeAddr("stranger")
        );
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
        assertEq(
            _vaultRaw(USDC, VAULT),
            handler.gDeposited() - handler.gWithdrawn(),
            "vault != net deposits"
        );
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
