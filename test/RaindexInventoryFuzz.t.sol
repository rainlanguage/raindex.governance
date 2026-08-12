// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {TaskV2, OrderConfigV4, OrderV4} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Property fuzz tests for `RaindexInventory` (RAI-1193): conservation
/// against the caller, over-draw fails atomically, RBAC over arbitrary
/// addresses, pause fails closed on every fund path, rounding never dips the
/// pool, concurrent operators. All against the live Base Raindex.
contract RaindexInventoryFuzzTest is RaindexInventoryTestBase {
    using LibDecimalFloat for Float;

    /// @dev deposit then withdraw of the same amount conserves value exactly
    /// against the CALLER: the vault sees +amount then -amount, the caller
    /// nets zero, the inventory contract itself never holds anything.
    function testFuzz_depositWithdraw_conservation_usdc(uint256 amount) external {
        amount = bound(amount, 1, 1e12); // up to 1M USDC
        deal(USDC, operator, amount);

        vm.startPrank(operator);
        IERC20(USDC).approve(address(inv), amount);
        inv.deposit4(USDC, VAULT, _float(amount), _noTasks());
        vm.stopPrank();

        assertEq(_vaultRaw(USDC, VAULT), amount, "vault credited exactly");
        assertEq(IERC20(USDC).balanceOf(operator), 0, "caller debited exactly");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "inventory holds nothing");

        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(amount), _noTasks());

        assertEq(_vaultRaw(USDC, VAULT), 0, "vault debited exactly");
        assertEq(IERC20(USDC).balanceOf(operator), amount, "caller recovers exactly");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "inventory still holds nothing");
    }

    /// @dev Same conservation property at 18 decimals (WETH) — the Float
    /// conversion path is decimals-sensitive, so 6dp coverage alone is blind
    /// to 18dp regressions.
    function testFuzz_depositWithdraw_conservation_weth(uint256 amount) external {
        amount = bound(amount, 1, 1e24); // up to 1M WETH
        deal(WETH, operator, amount);

        vm.startPrank(operator);
        IERC20(WETH).approve(address(inv), amount);
        inv.deposit4(WETH, VAULT, _floatAt(amount, 18), _noTasks());
        vm.stopPrank();

        assertEq(_vaultRaw(WETH, VAULT), amount, "vault credited exactly");
        assertEq(IERC20(WETH).balanceOf(operator), 0, "caller debited exactly");

        vm.prank(operator);
        inv.withdraw4(WETH, VAULT, _floatAt(amount, 18), _noTasks());

        assertEq(_vaultRaw(WETH, VAULT), 0, "vault debited exactly");
        assertEq(IERC20(WETH).balanceOf(operator), amount, "caller recovers exactly");
        assertEq(IERC20(WETH).balanceOf(address(inv)), 0, "inventory holds nothing");
    }

    /// @dev Any request exceeding the vault reverts InsufficientVaultLiquidity
    /// with the exact requested/received amounts — the atomic no-partial-fill
    /// guarantee concurrent operators rely on.
    function testFuzz_overdraw_reverts(uint256 vaultAmount, uint256 requested) external {
        vaultAmount = bound(vaultAmount, 1, 1e12);
        requested = bound(requested, vaultAmount + 1, 2e12 + 1);
        _depositAs(admin, VAULT, vaultAmount);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaindexInventory.InsufficientVaultLiquidity.selector, USDC, requested, vaultAmount
            )
        );
        inv.withdraw4(USDC, VAULT, _float(requested), _noTasks());
    }

    /// @dev No address without a role ever moves funds or reaches admin
    /// surfaces: every gated entrypoint rejects an arbitrary stranger with the
    /// exact missing role.
    function testFuzz_rbac_strangerAlwaysRejected(address stranger) external {
        vm.assume(stranger != admin && stranger != operator);
        _depositAs(admin, VAULT, 10e6);

        bytes memory operatorGate =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE);
        bytes memory adminGate =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE);

        vm.startPrank(stranger);
        vm.expectRevert(operatorGate);
        inv.withdraw4(USDC, VAULT, _float(1e6), _noTasks());
        vm.expectRevert(operatorGate);
        inv.deposit4(USDC, VAULT, _float(1e6), _noTasks());

        OrderConfigV4 memory config;
        vm.expectRevert(adminGate);
        inv.addOrder4(config, _noTasks());
        OrderV4 memory order;
        vm.expectRevert(adminGate);
        inv.removeOrder3(order, _noTasks());
        vm.expectRevert(adminGate);
        inv.entask2(_noTasks());
        vm.expectRevert(adminGate);
        inv.pause();
        vm.expectRevert(adminGate);
        inv.unpause();
        vm.expectRevert(adminGate);
        inv.rescue(USDC, 1);
        vm.expectRevert(adminGate);
        inv.grantRole(OPERATOR_ROLE, stranger);
        vm.stopPrank();
    }

    /// @dev Paused ⇒ EVERY fund-movement path fails closed, for both roles and
    /// any amount; order management stays open.
    function testFuzz_pause_failsClosed_allFundPaths(uint256 amount, bool asAdmin) external {
        amount = bound(amount, 1, 1e12);
        address caller = asAdmin ? admin : operator;
        _depositAs(admin, VAULT, amount);
        deal(USDC, caller, amount);
        vm.prank(caller);
        IERC20(USDC).approve(address(inv), amount);

        vm.prank(admin);
        inv.pause();

        vm.startPrank(caller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.deposit4(USDC, VAULT, _float(amount), _noTasks());
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.withdraw4(USDC, VAULT, _float(amount), _noTasks());
        vm.stopPrank();

        // Kill switch leaves order management available.
        vm.prank(admin);
        inv.entask2(_noTasks());

        assertEq(_vaultRaw(USDC, VAULT), amount, "vault untouched while paused");
    }

    /// @dev For ANY sub-precision (lossy) deposit Float, the caller is charged
    /// exactly the rounded-UP raw amount Raindex pulls, and the shared pool
    /// (the inventory's own balance) never dips.
    function testFuzz_lossyDeposit_neverDipsPool(uint256 coefficient) external {
        coefficient = bound(coefficient, 1, 1e13); // up to 1M USDC at 7dp
        Float f = LibDecimalFloat.packLossless(int256(coefficient), -7); // 7dp value on a 6dp token
        bool exact = coefficient % 10 == 0;
        uint256 charged = coefficient / 10 + (exact ? 0 : 1);

        deal(USDC, operator, charged);
        vm.startPrank(operator);
        // Approval of EXACTLY `charged`: pulling one unit more would revert.
        IERC20(USDC).approve(address(inv), charged);
        inv.deposit4(USDC, VAULT, f, _noTasks());
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(operator), 0, "caller charged exactly the rounded-up amount");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "pool never dips, nothing stranded");
    }

    /// @dev Two operators racing one vault: the first draw settles in full,
    /// the second either settles in full (if covered) or reverts atomically
    /// with the exact shortfall — never a partial fill.
    function testFuzz_concurrentOperators_loserRevertsAtomically(uint256 vaultAmount, uint256 first, uint256 second)
        external
    {
        vaultAmount = bound(vaultAmount, 2, 1e12);
        first = bound(first, 1, vaultAmount);
        second = bound(second, 1, 1e12);
        _depositAs(admin, VAULT, vaultAmount);

        address operator2 = makeAddr("operator2");
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, operator2);

        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(first), _noTasks());
        assertEq(IERC20(USDC).balanceOf(operator), first, "first draw settles in full");

        uint256 remaining = vaultAmount - first;
        if (second <= remaining) {
            vm.prank(operator2);
            inv.withdraw4(USDC, VAULT, _float(second), _noTasks());
            assertEq(IERC20(USDC).balanceOf(operator2), second, "covered second draw settles in full");
            assertEq(_vaultRaw(USDC, VAULT), remaining - second, "vault reconciles");
        } else {
            vm.prank(operator2);
            vm.expectRevert(
                abi.encodeWithSelector(
                    RaindexInventory.InsufficientVaultLiquidity.selector, USDC, second, remaining
                )
            );
            inv.withdraw4(USDC, VAULT, _float(second), _noTasks());
            assertEq(IERC20(USDC).balanceOf(operator2), 0, "loser gets nothing, not a partial fill");
            assertEq(_vaultRaw(USDC, VAULT), remaining, "vault unchanged by the failed draw");
        }
    }
}
