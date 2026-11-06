// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV6} from "raindex-interface-0.1.13/src/interface/deprecated/v6/IRaindexV6.sol";
import {
    OrderConfigV4,
    OrderV4,
    TaskV2,
    QuoteV2
} from "raindex-interface-0.1.13/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";
import {
    EvaluableV4,
    IInterpreterV4,
    IInterpreterStoreV3
} from "rainlang-0.2.30/src/interface/deprecated/v3/IInterpreterCallerV4.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pins RaindexInventory's role gates, pause scope, forwarding and
/// event payloads against the live Base Raindex.
contract RaindexInventoryHardeningTest is RaindexInventoryTestBase {
    using LibDecimalFloat for Float;

    // ---- constructor guards ----

    function test_constructor_zeroAdmin_reverts() external {
        vm.expectRevert(RaindexInventory.ZeroAddress.selector);
        new RaindexInventory(address(0), RAINDEX);
    }

    function test_constructor_zeroRaindex_reverts() external {
        vm.expectRevert(RaindexInventory.ZeroAddress.selector);
        new RaindexInventory(admin, IRaindexV6(address(0)));
    }

    // ---- OPERATOR_ROLE hash is a production ABI ----

    /// @dev Deployed operators hold grants of exactly this hash; changing the
    /// string literal silently severs them.
    function test_operatorRole_exactHash() external view {
        assertEq(
            inv.OPERATOR_ROLE(),
            0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929,
            "OPERATOR_ROLE != keccak256(\"OPERATOR_ROLE\")"
        );
        assertEq(inv.OPERATOR_ROLE(), keccak256("OPERATOR_ROLE"), "re-derived from its documented preimage");
    }

    // ---- rescue is admin-only ----

    function test_rescue_stranger_reverts() external {
        deal(USDC, address(inv), 42e6);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        inv.rescue(USDC, 42e6);
        assertEq(IERC20(USDC).balanceOf(address(inv)), 42e6, "stray balance untouched");
    }

    function test_rescue_operator_reverts() external {
        deal(USDC, address(inv), 42e6);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.rescue(USDC, 42e6);
    }

    // ---- unpause: gate and effect ----

    function test_unpause_nonAdmin_reverts_whilePaused() external {
        vm.prank(admin);
        inv.pause();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        inv.unpause();

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.unpause();

        assertTrue(inv.paused(), "still paused after rejected unpause attempts");
    }

    function test_unpause_restoresFundMovement() external {
        _depositAs(admin, VAULT, 100e6);
        vm.prank(admin);
        inv.pause();
        vm.prank(admin);
        inv.unpause();
        assertFalse(inv.paused(), "unpaused");

        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(100e6), _noTasks());
        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 100e6, "withdraw works again after unpause");
    }

    // ---- pause fails deposit closed too ----

    function test_pause_blocksOperatorDeposit() external {
        deal(USDC, operator, 100e6);
        vm.prank(operator);
        IERC20(USDC).approve(address(inv), 100e6);

        vm.prank(admin);
        inv.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.deposit4(USDC, VAULT, _float(100e6), _noTasks());
    }

    function test_pause_blocksAdminVaultMovement() external {
        _depositAs(admin, VAULT, 100e6);
        deal(USDC, admin, 50e6);
        vm.prank(admin);
        IERC20(USDC).approve(address(inv), 50e6);

        vm.prank(admin);
        inv.pause();

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.deposit4(USDC, VAULT, _float(50e6), _noTasks());

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.withdraw4(USDC, VAULT, _float(100e6), _noTasks());
    }

    /// @dev `rescue` is deliberately not pause-gated: incident recovery of
    /// stray balances must work while the vault paths are frozen.
    function test_rescue_worksWhilePaused() external {
        deal(USDC, address(inv), 7e6);
        vm.startPrank(admin);
        inv.pause();
        inv.rescue(USDC, 7e6);
        vm.stopPrank();
        assertTrue(inv.paused(), "still paused");
        assertEq(IERC20(USDC).balanceOf(admin), 7e6, "admin swept the stray balance while paused");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "nothing left on the inventory");
    }

    // ---- order management gates ----

    function test_addOrder4_nonAdmin_reverts() external {
        OrderConfigV4 memory config;
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.addOrder4(config, _noTasks());
    }

    function test_removeOrder3_nonAdmin_reverts() external {
        OrderV4 memory order;
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.removeOrder3(order, _noTasks());
    }

    // ---- order management stays open while paused, so the admin can cancel
    // orders mid-incident ----

    function test_orderManagement_worksWhilePaused() external {
        vm.prank(admin);
        inv.pause();

        // entask2 with no tasks reaches the live Raindex and succeeds.
        vm.prank(admin);
        inv.entask2(_noTasks());

        // removeOrder3 of a nonexistent order reaches the live Raindex and
        // returns false (nothing removed) rather than reverting on pause.
        OrderV4 memory order;
        order.owner = address(inv);
        order.nonce = bytes32(uint256(0xdead));
        vm.prank(admin);
        assertFalse(inv.removeOrder3(order, _noTasks()), "nonexistent order not removed");

        // addOrder4 is not pause-gated either: the inventory forwards it even
        // while paused (Raindex response mocked so no valid expression is
        // needed — the pause/gate logic under test lives in the inventory).
        OrderConfigV4 memory config;
        vm.mockCall(address(RAINDEX), abi.encodeWithSelector(IRaindexV6.addOrder4.selector), abi.encode(true));
        vm.prank(admin);
        assertTrue(inv.addOrder4(config, _noTasks()), "addOrder4 forwards while paused");
        vm.clearMockedCalls();
    }

    // ---- order management and view calls reach Raindex ----

    function test_addOrder4_forwardsToRaindex_andReturns() external {
        OrderConfigV4 memory config;
        config.nonce = bytes32(uint256(0xbeef));
        bytes memory expected = abi.encodeCall(IRaindexV6.addOrder4, (config, _noTasks()));
        vm.mockCall(address(RAINDEX), expected, abi.encode(true));
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(admin);
        assertTrue(inv.addOrder4(config, _noTasks()), "returns Raindex's result");
        vm.clearMockedCalls();
    }

    function test_removeOrder3_forwardsToRaindex_andReturns() external {
        OrderV4 memory order;
        order.owner = address(inv);
        order.nonce = bytes32(uint256(0xbeef));
        bytes memory expected = abi.encodeCall(IRaindexV6.removeOrder3, (order, _noTasks()));
        vm.mockCall(address(RAINDEX), expected, abi.encode(true));
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(admin);
        assertTrue(inv.removeOrder3(order, _noTasks()), "returns Raindex's result");
        vm.clearMockedCalls();
    }

    function test_entask2_forwardsToRaindex() external {
        bytes memory expected = abi.encodeCall(IRaindexV6.entask2, (_noTasks()));
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(admin);
        inv.entask2(_noTasks());
    }

    function test_vaultBalance2_forwardsToRaindex() external {
        // Real value through the inventory equals the direct Raindex read...
        _depositAs(admin, VAULT, 123e6);
        assertEq(
            Float.unwrap(inv.vaultBalance2(address(inv), USDC, VAULT)),
            Float.unwrap(RAINDEX.vaultBalance2(address(inv), USDC, VAULT)),
            "view mismatch vs direct Raindex read"
        );
        // ...and the plumbing is byte-exact (distinctive mocked value round-trips).
        bytes memory expected = abi.encodeCall(IRaindexV6.vaultBalance2, (address(0xabc), USDC, VAULT));
        vm.mockCall(address(RAINDEX), expected, abi.encode(Float.wrap(bytes32(uint256(0x12345)))));
        assertEq(Float.unwrap(inv.vaultBalance2(address(0xabc), USDC, VAULT)), bytes32(uint256(0x12345)));
        vm.clearMockedCalls();
    }

    function test_orderExists_forwardsToRaindex() external {
        bytes32 orderHash = bytes32(uint256(0xfeed));
        assertEq(inv.orderExists(orderHash), RAINDEX.orderExists(orderHash), "real read matches");
        bytes memory expected = abi.encodeCall(IRaindexV6.orderExists, (orderHash));
        vm.mockCall(address(RAINDEX), expected, abi.encode(true));
        assertTrue(inv.orderExists(orderHash), "mocked true round-trips");
        vm.clearMockedCalls();
    }

    function test_quote2_forwardsToRaindex() external {
        QuoteV2 memory quoteConfig;
        bytes memory expected = abi.encodeCall(IRaindexV6.quote2, (quoteConfig));
        vm.mockCall(
            address(RAINDEX),
            expected,
            abi.encode(true, Float.wrap(bytes32(uint256(7))), Float.wrap(bytes32(uint256(9))))
        );
        (bool exists, Float outputMax, Float ioRatio) = inv.quote2(quoteConfig);
        assertTrue(exists);
        assertEq(Float.unwrap(outputMax), bytes32(uint256(7)));
        assertEq(Float.unwrap(ioRatio), bytes32(uint256(9)));
        vm.clearMockedCalls();
    }

    // ---- tasks are forwarded verbatim on the fund paths ----

    /// @dev A recognizable non-empty task; never executed (the Raindex call is
    /// mocked), it only has to survive the abi.encode round-trip byte-exactly.
    function _dummyTasks() internal pure returns (TaskV2[] memory tasks) {
        tasks = new TaskV2[](1);
        tasks[0].evaluable =
            EvaluableV4(IInterpreterV4(address(0xdeadbeef)), IInterpreterStoreV3(address(0xcafe)), hex"c0de");
    }

    function test_withdraw4_forwardsTasksToRaindex() external {
        // Driven against the live Raindex, because a mock cannot deliver the
        // tokens the balance-delta check needs. The task has distinct nonzero
        // interpreter and store fields but empty bytecode, which Raindex skips
        // at runtime, so the full calldata check sees every field. `_float(1e6)`
        // is exact at 6dp, so the floored target equals what the caller passed.
        _depositAs(admin, VAULT, 2e6);
        TaskV2[] memory tasks = new TaskV2[](1);
        tasks[0].evaluable =
            EvaluableV4(IInterpreterV4(address(0xdeadbeef)), IInterpreterStoreV3(address(0xcafe)), hex"");

        // Tasks are admin only, so the admin is the caller here.
        bytes memory expected = abi.encodeCall(IRaindexV6.withdraw4, (USDC, VAULT, _float(1e6), tasks));
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(admin);
        inv.withdraw4(USDC, VAULT, _float(1e6), tasks);
    }

    function test_deposit4_forwardsTasksToRaindex() external {
        TaskV2[] memory tasks = _dummyTasks();
        Float zero = _float(0);
        bytes memory expected = abi.encodeCall(IRaindexV6.deposit4, (USDC, VAULT, zero, tasks));
        vm.mockCall(address(RAINDEX), expected, "");
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(admin);
        inv.deposit4(USDC, VAULT, zero, tasks);
        vm.clearMockedCalls();
    }

    // ---- tasks are admin only: Raindex runs them in the inventory's state
    // namespace, which every owned order shares ----

    function test_operatorTasks_forbidden() external {
        _depositAs(admin, VAULT, 5e6);
        TaskV2[] memory tasks = new TaskV2[](1);
        deal(USDC, operator, 1e6);
        vm.startPrank(operator);
        IERC20(USDC).approve(address(inv), 1e6);
        vm.expectRevert(RaindexInventory.OperatorTasksForbidden.selector);
        inv.withdraw4(USDC, VAULT, _float(1e6), tasks);
        vm.expectRevert(RaindexInventory.OperatorTasksForbidden.selector);
        inv.deposit4(USDC, VAULT, _float(1e6), tasks);
        // Empty tasks still work for the operator.
        inv.withdraw4(USDC, VAULT, _float(1e6), _noTasks());
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(operator), 2e6, "operator kept its 1e6 and withdrew 1e6");
    }

    // ---- withdraw measures the balance delta, not the absolute balance ----

    function test_withdraw_preservesStrayContractBalance() external {
        deal(USDC, address(inv), 42e6); // stray, not vault-backed
        _depositAs(admin, VAULT, 100e6);

        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(100e6), _noTasks());

        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 100e6, "caller gets exactly the withdrawn amount");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 42e6, "stray balance NOT swept to the caller");
    }

    // ---- withdraw4 floors the target to token precision, so Raindex debits
    // the vault by exactly what leaves it ----

    function test_withdraw_subPrecisionTarget_burnsNoVaultDust() external {
        _depositAs(admin, VAULT, 10e6);
        (uint256 vaultBefore18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);

        // 1.0000005 USDC is lossy at 6dp; the vault must drop by exactly the
        // 1.000000 sent.
        Float f = LibDecimalFloat.packLossless(10_000_005, -7);
        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, f, _noTasks());

        (uint256 vaultAfter18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);
        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 1_000_000, "caller receives the floored amount");
        assertEq(vaultBefore18 - vaultAfter18, uint256(1_000_000) * 1e12, "vault debited exactly, no dust burned");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "nothing stranded on the inventory");
    }

    /// @dev One raw unit is the smallest target that still reaches Raindex.
    function test_withdraw_oneRawUnit_settles() external {
        _depositAs(admin, VAULT, 5e6);
        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(1), _noTasks());
        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 1, "one raw unit is not a no-op");
        assertEq(_vaultRaw(USDC, VAULT), 5e6 - 1, "vault debited one raw unit");
    }

    // ---- event payloads ----

    /// @dev The test-base event mirrors must match the contract's ABI, or
    /// every `vm.expectEmit` above would check a stale signature.
    function test_eventSelectorsMatchContract() external pure {
        assertEq(OperatorWithdraw.selector, RaindexInventory.OperatorWithdraw.selector, "OperatorWithdraw mirror");
        assertEq(OperatorDeposit.selector, RaindexInventory.OperatorDeposit.selector, "OperatorDeposit mirror");
    }

    function test_withdraw_emitsOperatorWithdraw() external {
        _depositAs(admin, VAULT, 100e6);
        vm.expectEmit(true, true, true, true, address(inv));
        emit OperatorWithdraw(operator, USDC, VAULT, 100e6);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(100e6), _noTasks());
    }

    function test_deposit_emitsOperatorDeposit() external {
        deal(USDC, operator, 100e6);
        vm.startPrank(operator);
        IERC20(USDC).approve(address(inv), 100e6);
        vm.expectEmit(true, true, true, true, address(inv));
        emit OperatorDeposit(operator, USDC, VAULT, 100e6);
        inv.deposit4(USDC, VAULT, _float(100e6), _noTasks());
        vm.stopPrank();
    }

    // ---- a zero or sub-unit target reverts before it reaches Raindex ----

    function testFuzz_withdraw_subUnitOrZeroTarget_reverts(uint256 coefficient) external {
        coefficient = bound(coefficient, 0, 9); // 0..9e-7 USDC, all below 1 raw unit
        _depositAs(admin, VAULT, 5e6);
        // forge-lint: disable-next-line(unsafe-typecast)
        Float f = LibDecimalFloat.packLossless(int256(coefficient), -7);
        vm.expectCall(address(RAINDEX), abi.encodeWithSelector(IRaindexV6.withdraw4.selector), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RaindexInventory.ZeroWithdrawAmount.selector, USDC, VAULT));
        inv.withdraw4(USDC, VAULT, f, _noTasks());
    }
}
