// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV6} from "raindex-interface-0.1.2/src/interface/IRaindexV6.sol";
import {
    OrderConfigV4,
    OrderV4,
    TaskV2,
    QuoteV2
} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {EvaluableV4} from "rain-interpreter-interface-0.1.0/src/interface/IInterpreterCallerV4.sol";
import {IInterpreterV4} from "rain-interpreter-interface-0.1.0/src/interface/IInterpreterV4.sol";
import {IInterpreterStoreV3} from "rain-interpreter-interface-0.1.0/src/interface/IInterpreterStoreV3.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Gap-fill tests driven by the RAI-1193 adversarial mutation run:
/// every test here pins a behavior whose targeted mutation SURVIVED the
/// original 17-test suite. Fork tests against the live Base Raindex, same as
/// `RaindexInventoryForkTest`.
contract RaindexInventoryHardeningTest is RaindexInventoryTestBase {
    using LibDecimalFloat for Float;

    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);
    event OperatorDeposit(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    // ---- constructor guards (mutants C1, C2 survived) ----

    function test_constructor_zeroAdmin_reverts() external {
        vm.expectRevert(RaindexInventory.ZeroAddress.selector);
        new RaindexInventory(address(0), RAINDEX);
    }

    function test_constructor_zeroRaindex_reverts() external {
        vm.expectRevert(RaindexInventory.ZeroAddress.selector);
        new RaindexInventory(admin, IRaindexV6(address(0)));
    }

    // ---- OPERATOR_ROLE hash is a production ABI (mutant R3 survived) ----

    /// @dev The deployed Bebop hook holds exactly this hash on the prod
    /// inventory; changing the string literal silently severs that grant.
    function test_operatorRole_exactHash() external view {
        assertEq(
            inv.OPERATOR_ROLE(),
            0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929,
            "OPERATOR_ROLE != keccak256(\"OPERATOR_ROLE\")"
        );
    }

    // ---- rescue is admin-only (mutant A5 survived: gate drop was invisible) ----

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

    // ---- unpause: gate and effect (mutants A3, A4 survived) ----

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

    // ---- pause fails DEPOSIT closed too (mutant D2 survived: only the
    // withdraw path was pinned) ----

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

    function test_pause_blocksAdminFundMovement() external {
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

    // ---- order management gates (mutants O1, O3 survived) ----

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

    // ---- order management stays OPEN while paused (mutant O7 survived; the
    // NatSpec kill-switch contract: admin can cancel orders mid-incident) ----

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

    // ---- order management + view forwarding (mutants O2, O4, O6, V1, V2,
    // V3 survived: nothing pinned that calls actually reach Raindex) ----

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

    // ---- tasks are forwarded VERBATIM on the fund paths (round-2 mutants
    // WT, DT survived: every prior test passed empty tasks) ----

    /// @dev A recognizable non-empty task; never executed (the Raindex call is
    /// mocked), it only has to survive the abi.encode round-trip byte-exactly.
    function _dummyTasks() internal pure returns (TaskV2[] memory tasks) {
        tasks = new TaskV2[](1);
        tasks[0].evaluable =
            EvaluableV4(IInterpreterV4(address(0xdeadbeef)), IInterpreterStoreV3(address(0xcafe)), hex"c0de");
    }

    function test_withdraw4_forwardsTasksToRaindex() external {
        // Driven against the LIVE Raindex: a mock can't deliver tokens (so the
        // balance-delta check would revert), and a sub-unit amount now no-ops.
        // The single task carries empty bytecode — Raindex skips it at runtime,
        // so the withdraw settles — while the non-empty tasks ARRAY still
        // distinguishes verbatim forwarding from the empty-array mutant.
        // `_float(1e6)` is exact at 6dp, so the floored target handed to Raindex
        // is byte-identical to what the caller passed.
        _depositAs(admin, VAULT, 2e6);
        TaskV2[] memory tasks = new TaskV2[](1);
        tasks[0].evaluable = EvaluableV4(IInterpreterV4(address(0)), IInterpreterStoreV3(address(0)), hex"");

        bytes memory expected = abi.encodeCall(IRaindexV6.withdraw4, (USDC, VAULT, _float(1e6), tasks));
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(1e6), tasks);
    }

    function test_deposit4_forwardsTasksToRaindex() external {
        TaskV2[] memory tasks = _dummyTasks();
        Float zero = _float(0);
        bytes memory expected = abi.encodeCall(IRaindexV6.deposit4, (USDC, VAULT, zero, tasks));
        vm.mockCall(address(RAINDEX), expected, "");
        vm.expectCall(address(RAINDEX), expected);
        vm.prank(operator);
        inv.deposit4(USDC, VAULT, zero, tasks);
        vm.clearMockedCalls();
    }

    // ---- withdraw measures the DELTA, not the absolute balance (mutant W5
    // survived: `balBefore = 0` was invisible) ----

    function test_withdraw_preservesStrayContractBalance() external {
        deal(USDC, address(inv), 42e6); // stray, not vault-backed
        _depositAs(admin, VAULT, 100e6);

        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(100e6), _noTasks());

        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 100e6, "caller gets exactly the withdrawn amount");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 42e6, "stray balance NOT swept to the caller");
    }

    // ---- withdraw4 floors the target to token precision so Raindex debits the
    // vault by exactly what leaves it — no sub-unit dust burned (finding #4) ----

    function test_withdraw_subPrecisionTarget_burnsNoVaultDust() external {
        _depositAs(admin, VAULT, 10e6);
        (uint256 vaultBefore18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);

        // 1.0000005 USDC is lossy at USDC's 6dp. Pre-fix, `withdraw4` handed
        // Raindex the raw Float: Raindex debited the vault by the full
        // 1.0000005 but could only transfer 1.000000 raw, silently burning the
        // 5e-7 remainder from the shared pool (the floored `requested` never
        // trips InsufficientVaultLiquidity). The fix floors the target first,
        // so the vault is debited by exactly 1.000000.
        Float f = LibDecimalFloat.packLossless(10_000_005, -7);
        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, f, _noTasks());

        (uint256 vaultAfter18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);
        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, 1_000_000, "caller receives the floored amount");
        // Exactly 1.000000 USDC leaves the vault (1e6 raw == 1e18 at 18dp), not
        // 1.0000005. Pre-fix this delta was 1_000_000_500_000_000_000.
        assertEq(vaultBefore18 - vaultAfter18, uint256(1_000_000) * 1e12, "vault debited exactly, no dust burned");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "nothing stranded on the inventory");
    }

    // ---- events (mutants W8, D10 survived: zero event assertions existed) ----

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

    // ---- a sub-unit target is a clean no-op: `requested == 0` returns early,
    // so nothing moves, no event fires, and the vault is NOT touched (finding
    // #4: the pre-fix path debited the vault float and burned the remainder) ----

    function test_withdraw_subUnitTarget_noOp_noVaultTouch() external {
        _depositAs(admin, VAULT, 5e6); // fund the vault so a burn would be visible
        (uint256 vaultBefore18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);

        Float subUnit = LibDecimalFloat.packLossless(5, -7); // 5e-7 USDC < 1 raw unit
        uint256 opBefore = IERC20(USDC).balanceOf(operator);

        vm.recordLogs();
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, subUnit, _noTasks());

        assertEq(IERC20(USDC).balanceOf(operator), opBefore, "no funds moved");
        (uint256 vaultAfter18,) = RAINDEX.vaultBalance2(address(inv), USDC, VAULT).toFixedDecimalLossy(18);
        assertEq(vaultAfter18, vaultBefore18, "vault untouched: no sub-unit dust burned");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != OperatorWithdraw.selector, "no OperatorWithdraw event on a no-op");
        }
    }
}
