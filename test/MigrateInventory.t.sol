// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IRaindexV6} from "raindex-interface-0.1.13/src/interface/deprecated/v6/IRaindexV6.sol";
import {TaskV2} from "raindex-interface-0.1.13/src/interface/deprecated/v5/IOrderBookV5.sol";
import {
    IRaindexV7,
    OrderV4,
    OrderConfigV4,
    TaskV3,
    IOV2,
    EvaluableV4,
    IInterpreterV4,
    IInterpreterStoreV3
} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {RAINDEX_V7} from "../script/lib/RaindexV7Release.sol";
import {LibInventoryMigration, MigrationPlan, AdminCall} from "../script/lib/LibInventoryMigration.sol";
import {MigrateInventory, MigrationCallFailed, UnknownMigrationMode} from "../script/MigrateInventory.sol";
import {MigrationHarness} from "./MigrationHarness.sol";

/// @notice Moves the live Base pool from the V6 inventory to a fresh V7
/// inventory on a fork, as the live admin, with the transactions that
/// `MigrateInventory` prints, and checks the end state.
contract MigrateInventoryTest is Test {
    using LibDecimalFloat for Float;

    /// The live V6 inventory on Base, its V6 Raindex, and its admin.
    address internal constant OLD = 0x10e4db39275C3b128C01bA1194D45D19aE1520d9;
    address internal constant RAINDEX_V6 = 0xe522cB4a5fCb2eb31a52Ff41a4653d85A4fd7C9D;
    address internal constant ADMIN = 0xA9C16673F65AE808688cB18952AFE3d9658C808f;
    /// The old inventory's operators.
    address internal constant OLD_OPERATOR_A = 0x7BDEa3bA0101E06Cbb7f12500ed12eF046148A03;
    address internal constant OLD_OPERATOR_B = 0x3EE87Dcabfb324B2231044928080Dd4E6AC19baE;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    /// The live USDC vault, a second USDC vault and a WETH vault that the test
    /// seeds, and an empty vault.
    bytes32 internal constant USDC_VAULT = bytes32(uint256(0xfab));
    bytes32 internal constant USDC_VAULT_2 = keccak256("migration-test-usdc-2");
    bytes32 internal constant WETH_VAULT = keccak256("migration-test-weth");
    bytes32 internal constant EMPTY_VAULT = keccak256("migration-test-empty");
    uint256 internal constant USDC_2_AMOUNT = 2e6;

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// A Base block where the old inventory is live, funded and unpaused.
    uint256 internal constant BASE_FORK_BLOCK = 55203936;

    RaindexInventory internal inv;
    MigrationHarness internal harness;
    MigrateInventory internal script;
    address internal newOperator = makeAddr("newOperator");
    OrderConfigV4 internal config;
    bytes internal addOrderEvent;

    function setUp() public {
        // Pinned before the real move: these tests move the live pool, which
        // the real move pauses and empties.
        vm.createSelectFork("base", BASE_FORK_BLOCK);
        inv = new RaindexInventory(ADMIN, IRaindexV7(RAINDEX_V7));
        harness = new MigrationHarness();
        script = new MigrateInventory();

        // A minimal two-source order: Raindex only counts the sources when it
        // adds one, and nothing here takes it.
        bytes memory bytecode = hex"02000000040000000000000000";
        config.evaluable.interpreter = IInterpreterV4(address(0xdead));
        config.evaluable.store = IInterpreterStoreV3(address(0xbeef));
        config.evaluable.bytecode = abi.encodePacked(uint256(0), uint256(bytecode.length), bytecode);
        config.validInputs.push(IOV2(USDC, USDC_VAULT));
        config.validOutputs.push(IOV2(WETH, WETH_VAULT));
        config.nonce = keccak256("migration-test");

        // Seed the old inventory: one live V6 order, a WETH vault, and a
        // second USDC vault.
        vm.recordLogs();
        vm.prank(ADMIN);
        IRaindexV6(OLD).addOrder4(config, new TaskV2[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == RAINDEX_V6 && logs[i].topics[0] == IRaindexV6.AddOrderV3.selector) {
                addOrderEvent = logs[i].data;
            }
        }
        assertGt(addOrderEvent.length, 0, "seeded order event");

        deal(WETH, ADMIN, 3 ether);
        deal(USDC, ADMIN, IERC20(USDC).balanceOf(ADMIN) + USDC_2_AMOUNT);
        vm.startPrank(ADMIN);
        IERC20(WETH).approve(OLD, 3 ether);
        IRaindexV6(OLD).deposit4(WETH, WETH_VAULT, _float(3 ether, 18), new TaskV2[](0));
        IERC20(USDC).approve(OLD, USDC_2_AMOUNT);
        IRaindexV6(OLD).deposit4(USDC, USDC_VAULT_2, _float(USDC_2_AMOUNT, 6), new TaskV2[](0));
        vm.stopPrank();
    }

    function _float(uint256 raw, uint8 decimals) internal pure returns (Float f) {
        (f,) = LibDecimalFloat.fromFixedDecimalLossyPacked(raw, decimals);
    }

    function _planJson(uint256[] memory moved) internal returns (string memory) {
        string memory planKey = "plan";
        address[] memory tokens = new address[](4);
        tokens[0] = USDC;
        tokens[1] = WETH;
        tokens[2] = USDC;
        tokens[3] = USDC;
        bytes32[] memory vaultIds = new bytes32[](4);
        vaultIds[0] = USDC_VAULT;
        vaultIds[1] = WETH_VAULT;
        vaultIds[2] = EMPTY_VAULT;
        vaultIds[3] = USDC_VAULT_2;
        bytes[] memory events = new bytes[](1);
        events[0] = addOrderEvent;
        bytes[] memory addCalls = new bytes[](1);
        addCalls[0] = abi.encodeCall(IRaindexV7.addOrder5, (config, new TaskV3[](0)));
        address[] memory revoke = new address[](2);
        revoke[0] = OLD_OPERATOR_A;
        revoke[1] = OLD_OPERATOR_B;
        address[] memory grant = new address[](1);
        grant[0] = newOperator;

        vm.serializeAddress(planKey, "admin", ADMIN);
        vm.serializeAddress(planKey, "oldInventory", OLD);
        vm.serializeAddress(planKey, "newInventory", address(inv));
        vm.serializeAddress(planKey, "tokens", tokens);
        vm.serializeBytes32(planKey, "vaultIds", vaultIds);
        vm.serializeBytes(planKey, "removeOrderEvents", events);
        vm.serializeBytes(planKey, "addOrderCalls", addCalls);
        vm.serializeAddress(planKey, "revokeOperators", revoke);
        vm.serializeUint(planKey, "moved", moved);
        return vm.serializeAddress(planKey, "grantOperators", grant);
    }

    function _plan() internal returns (MigrationPlan memory) {
        return script.parsePlan(_planJson(new uint256[](0)));
    }

    function _freeze(MigrationPlan memory plan) internal {
        AdminCall[] memory first = new AdminCall[](1);
        first[0] = harness.freezeCall(plan);
        script.simulate(ADMIN, first);
    }

    function _migrate() internal returns (MigrationPlan memory plan, uint256[] memory moved) {
        plan = _plan();
        _freeze(plan);
        moved = harness.amounts(plan);
        script.simulate(ADMIN, harness.calls(plan, moved));
    }

    // ---- the full move ----

    function test_migrate_movesPoolAndPassesVerify() external {
        uint256 usdcBefore = LibInventoryMigration.rawVaultBalance(OLD, USDC, USDC_VAULT);
        assertGt(usdcBefore, 0, "live USDC vault is funded");
        uint256 adminUsdc = IERC20(USDC).balanceOf(ADMIN);
        uint256 adminWeth = IERC20(WETH).balanceOf(ADMIN);

        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        assertEq(moved[0], usdcBefore, "USDC amount");
        assertEq(moved[1], 3 ether, "WETH amount");
        assertEq(moved[2], 0, "empty vault moves nothing");
        assertEq(moved[3], USDC_2_AMOUNT, "second USDC amount");
        harness.verify(plan, moved);

        // Conservation: the vaults hold what left V6, the admin keeps nothing.
        assertEq(LibInventoryMigration.rawVaultBalance(address(inv), USDC, USDC_VAULT), usdcBefore, "USDC on V7");
        assertEq(LibInventoryMigration.rawVaultBalance(address(inv), WETH, WETH_VAULT), 3 ether, "WETH on V7");
        assertEq(IERC20(USDC).balanceOf(ADMIN), adminUsdc, "admin USDC unchanged");
        assertEq(IERC20(WETH).balanceOf(ADMIN), adminWeth, "admin WETH unchanged");
        assertEq(IERC20(USDC).allowance(ADMIN, address(inv)), 0, "no USDC allowance left");
        assertEq(IERC20(WETH).allowance(ADMIN, address(inv)), 0, "no WETH allowance left");
        assertEq(IERC20(USDC).balanceOf(address(inv)), 0, "nothing on the new inventory wallet");

        // One settle on the new inventory works end to end.
        uint256 operatorBefore = IERC20(USDC).balanceOf(newOperator);
        vm.startPrank(newOperator);
        inv.withdraw5(USDC, USDC_VAULT, _float(1, 6), new TaskV3[](0));
        assertEq(IERC20(USDC).balanceOf(newOperator) - operatorBefore, 1, "operator draws");
        IERC20(USDC).approve(address(inv), 1);
        inv.deposit5(USDC, USDC_VAULT, _float(1, 6), new TaskV3[](0));
        vm.stopPrank();
        assertEq(LibInventoryMigration.rawVaultBalance(address(inv), USDC, USDC_VAULT), usdcBefore, "round trip");

        // The old operators lost the role, and the old inventory is paused.
        assertFalse(IAccessControl(OLD).hasRole(OPERATOR_ROLE, OLD_OPERATOR_A), "old role revoked");
        assertTrue(Pausable(OLD).paused(), "old paused");
        vm.prank(OLD_OPERATOR_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OLD_OPERATOR_A, OPERATOR_ROLE
            )
        );
        IRaindexV6(OLD).withdraw4(USDC, USDC_VAULT, _float(1, 6), new TaskV2[](0));
    }

    /// @dev `run` as an operator uses it: the first run signs only the freeze
    /// and previews the rest; the run after the freeze moves the pool; check
    /// mode confirms the end state from the recorded amounts.
    function test_run_endToEnd() external {
        vm.createDir("./.tmp", true);
        string memory path = "./.tmp/migration-test-plan.json";
        MigrationPlan memory plan = _plan();
        vm.writeJson(_planJson(new uint256[](0)), path);

        // Dry run from the live state: it runs the freeze and the rest.
        uint256 snapshot = vm.snapshotState();
        script.runWith(path, "");
        vm.revertToState(snapshot);

        // The admin signs the freeze, then runs the script again.
        _freeze(plan);
        assertFalse(harness.needsFreeze(plan), "frozen");
        uint256[] memory moved = harness.amounts(plan);
        script.runWith(path, "");
        assertTrue(RaindexInventory(OLD).paused(), "old paused");
        assertEq(LibInventoryMigration.rawVaultBalance(address(inv), WETH, WETH_VAULT), 3 ether, "WETH on V7");
        assertTrue(inv.hasRole(OPERATOR_ROLE, newOperator), "new operator");

        // Check mode reads `moved` from the plan and checks the chain.
        vm.writeJson(_planJson(moved), path);
        script.runWith(path, "check");
    }

    // ---- freeze ----

    function test_needsFreeze_untilFrozen() external {
        MigrationPlan memory plan = _plan();
        assertTrue(harness.needsFreeze(plan), "live operators and order");
        _freeze(plan);
        assertFalse(harness.needsFreeze(plan), "frozen");
    }

    /// @dev After the freeze, nothing but the admin can change an old vault,
    /// so the amounts read then are exact.
    function test_freeze_locksOutOperators() external {
        MigrationPlan memory plan = _plan();
        _freeze(plan);
        assertFalse(IRaindexV6(OLD).orderExists(LibInventoryMigration.orderHash(plan.removeOrders[0])), "order removed");
        deal(USDC, OLD_OPERATOR_A, 1e6);
        vm.startPrank(OLD_OPERATOR_A);
        IERC20(USDC).approve(OLD, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OLD_OPERATOR_A, OPERATOR_ROLE
            )
        );
        IRaindexV6(OLD).deposit4(USDC, USDC_VAULT, _float(1e6, 6), new TaskV2[](0));
        vm.stopPrank();
    }

    /// @dev A plan order that is no longer live is left out of the freeze.
    function test_freeze_skipsDeadOrders() external {
        MigrationPlan memory plan = _plan();
        vm.prank(ADMIN);
        IRaindexV6(OLD).removeOrder3(plan.removeOrders[0], new TaskV2[](0));
        AdminCall memory freeze = harness.freezeCall(plan);
        bytes[] memory expected = new bytes[](2);
        expected[0] = abi.encodeCall(IAccessControl.revokeRole, (OPERATOR_ROLE, OLD_OPERATOR_A));
        expected[1] = abi.encodeCall(IAccessControl.revokeRole, (OPERATOR_ROLE, OLD_OPERATOR_B));
        assertEq(freeze.data, abi.encodeWithSignature("multicall(bytes[])", expected), "revokes only");
        _freeze(plan);
        uint256[] memory moved = harness.amounts(plan);
        script.simulate(ADMIN, harness.calls(plan, moved));
        harness.verify(plan, moved);
    }

    // ---- after the drain: no rebuild, only resume from the saved amounts ----

    function _drainOnly() internal returns (MigrationPlan memory plan, uint256[] memory moved) {
        plan = _plan();
        _freeze(plan);
        moved = harness.amounts(plan);
        AdminCall[] memory drain = new AdminCall[](1);
        drain[0] = harness.calls(plan, moved)[0];
        script.simulate(ADMIN, drain);
    }

    /// @dev A drained old inventory reads zero, so a rebuilt move would
    /// deposit nothing. `amounts` refuses it.
    function test_amounts_afterDrain_reverts() external {
        (MigrationPlan memory plan,) = _drainOnly();
        vm.expectRevert(LibInventoryMigration.OldInventoryAlreadyDrained.selector);
        harness.amounts(plan);
    }

    function test_resume_afterDrain_finishesMove() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _drainOnly();
        AdminCall[] memory rest = harness.resumeCalls(plan, moved, ADMIN);
        assertEq(rest.length, 3, "two approves and the new multicall");
        script.simulate(ADMIN, rest);
        harness.verify(plan, moved);
    }

    function test_resume_notDrained_reverts() external {
        MigrationPlan memory plan = _plan();
        _freeze(plan);
        uint256[] memory moved = harness.amounts(plan);
        vm.expectRevert(LibInventoryMigration.OldInventoryNotDrained.selector);
        harness.resumeCalls(plan, moved, ADMIN);
    }

    function test_resume_movedLengthMismatch_reverts() external {
        (MigrationPlan memory plan,) = _drainOnly();
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.MovedLengthMismatch.selector, 4, 1));
        harness.resumeCalls(plan, new uint256[](1), ADMIN);
    }

    function test_resume_allZero_reverts() external {
        (MigrationPlan memory plan,) = _drainOnly();
        vm.expectRevert(LibInventoryMigration.NothingToResume.selector);
        harness.resumeCalls(plan, new uint256[](4), ADMIN);
    }

    /// @dev An amount copied too high is caught: the admin does not hold it.
    function test_resume_amountTooHigh_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _drainOnly();
        uint256 held = IERC20(WETH).balanceOf(ADMIN);
        moved[1] = held + 1;
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.AdminBalanceShort.selector, WETH, held + 1, held));
        harness.resumeCalls(plan, moved, ADMIN);
    }

    /// @dev Pausing the old inventory with funds in it is not a drain.
    function test_amounts_pausedWithFunds_reverts() external {
        MigrationPlan memory plan = _plan();
        uint256 usdc = LibInventoryMigration.rawVaultBalance(OLD, USDC, USDC_VAULT);
        vm.prank(ADMIN);
        RaindexInventory(OLD).pause();
        vm.expectRevert(
            abi.encodeWithSelector(LibInventoryMigration.OldInventoryPausedWithFunds.selector, USDC, USDC_VAULT, usdc)
        );
        harness.amounts(plan);
    }

    function test_run_unknownMode_reverts() external {
        vm.createDir("./.tmp", true);
        string memory path = "./.tmp/migration-test-mode.json";
        vm.writeJson(_planJson(new uint256[](0)), path);
        vm.expectRevert(abi.encodeWithSelector(UnknownMigrationMode.selector, "chek"));
        script.runWith(path, "chek");
    }

    /// @dev `run` after the drain refuses to rebuild, and resume mode
    /// finishes the move from the saved amounts.
    function test_run_afterDrain_resumeMode() external {
        vm.createDir("./.tmp", true);
        string memory path = "./.tmp/migration-test-resume.json";
        (, uint256[] memory moved) = _drainOnly();
        vm.writeJson(_planJson(moved), path);

        vm.expectRevert(LibInventoryMigration.OldInventoryAlreadyDrained.selector);
        script.runWith(path, "");

        script.runWith(path, "resume");
        assertEq(LibInventoryMigration.rawVaultBalance(address(inv), WETH, WETH_VAULT), 3 ether, "WETH on V7");
    }

    // ---- calls ----

    /// @dev One approve per token, summing every funded vault of that token.
    function test_calls_shape() external {
        MigrationPlan memory plan = _plan();
        _freeze(plan);
        uint256[] memory moved = harness.amounts(plan);
        AdminCall[] memory txs = harness.calls(plan, moved);
        // drain, one approve each for USDC and WETH, new multicall
        assertEq(txs.length, 4, "tx count");
        assertEq(txs[0].target, OLD, "drain first");
        assertEq(txs[1].target, USDC, "USDC approve");
        assertEq(txs[1].data, abi.encodeCall(IERC20.approve, (address(inv), moved[0] + USDC_2_AMOUNT)), "USDC total");
        assertEq(txs[2].target, WETH, "WETH approve");
        assertEq(txs[2].data, abi.encodeCall(IERC20.approve, (address(inv), 3 ether)), "WETH total");
        assertEq(txs[3].target, address(inv), "new last");
    }

    /// @dev An amount above the vault balance reverts the whole drain, so
    /// nothing moves.
    function test_staleAmounts_revertAtomically() external {
        MigrationPlan memory plan = _plan();
        _freeze(plan);
        uint256[] memory moved = harness.amounts(plan);
        moved[1] += 1;
        AdminCall[] memory txs = harness.calls(plan, moved);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrationCallFailed.selector,
                0,
                abi.encodeWithSelector(RaindexInventory.InsufficientVaultLiquidity.selector, WETH, 3 ether + 1, 3 ether)
            )
        );
        script.simulate(ADMIN, txs);
        assertEq(LibInventoryMigration.rawVaultBalance(OLD, WETH, WETH_VAULT), 3 ether, "WETH still on V6");
    }

    // ---- plan checks ----

    function test_amounts_newInventoryNotOnV7_reverts() external {
        MigrationPlan memory plan = _plan();
        plan.newInventory = address(new RaindexInventory(ADMIN, IRaindexV7(RAINDEX_V6)));
        vm.expectRevert(
            abi.encodeWithSelector(LibInventoryMigration.NewInventoryNotOnV7.selector, RAINDEX_V6, RAINDEX_V6.codehash)
        );
        harness.amounts(plan);
    }

    function test_amounts_vaultLengthMismatch_reverts() external {
        MigrationPlan memory plan = _plan();
        plan.vaultIds = new bytes32[](1);
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.VaultLengthMismatch.selector, 4, 1));
        harness.amounts(plan);
    }

    function test_amounts_duplicateVault_reverts() external {
        MigrationPlan memory plan = _plan();
        plan.vaultIds[2] = USDC_VAULT;
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.DuplicateVault.selector, USDC, USDC_VAULT));
        harness.amounts(plan);
    }

    function test_amounts_foreignOrder_reverts() external {
        MigrationPlan memory plan = _plan();
        plan.removeOrders[0].owner = ADMIN;
        vm.expectRevert(
            abi.encodeWithSelector(
                LibInventoryMigration.OrderNotOwnedByOldInventory.selector,
                LibInventoryMigration.orderHash(plan.removeOrders[0]),
                ADMIN
            )
        );
        harness.amounts(plan);
    }

    function test_calls_notAddOrder5_reverts() external {
        MigrationPlan memory plan = _plan();
        plan.addOrderCalls[0] = abi.encodeCall(IRaindexV6.addOrder4, (config, new TaskV2[](0)));
        uint256[] memory moved = harness.amounts(plan);
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.NotAddOrder5Call.selector, 0));
        harness.calls(plan, moved);
    }

    // ---- verify catches every unfinished end state ----

    function test_verify_beforeMigration_reverts() external {
        MigrationPlan memory plan = _plan();
        uint256[] memory moved = harness.amounts(plan);
        vm.expectRevert(LibInventoryMigration.OldInventoryNotPaused.selector);
        harness.verify(plan, moved);
    }

    function test_verify_movedLengthMismatch_reverts() external {
        (MigrationPlan memory plan,) = _migrate();
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.MovedLengthMismatch.selector, 4, 3));
        harness.verify(plan, new uint256[](3));
    }

    function test_verify_vaultNotMoved_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        inv.withdraw5(WETH, WETH_VAULT, _float(1, 18), new TaskV3[](0));
        vm.expectRevert(
            abi.encodeWithSelector(LibInventoryMigration.VaultNotMoved.selector, WETH, WETH_VAULT, 3 ether, 3 ether - 1)
        );
        harness.verify(plan, moved);
    }

    function test_verify_vaultNotEmptied_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        deal(WETH, ADMIN, 1);
        vm.startPrank(ADMIN);
        RaindexInventory(OLD).unpause();
        IERC20(WETH).approve(OLD, 1);
        IRaindexV6(OLD).deposit4(WETH, WETH_VAULT, _float(1, 18), new TaskV2[](0));
        RaindexInventory(OLD).pause();
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.VaultNotEmptied.selector, WETH, WETH_VAULT, 1));
        harness.verify(plan, moved);
    }

    function test_verify_orderStillLive_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        IRaindexV6(OLD).addOrder4(config, new TaskV2[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                LibInventoryMigration.OrderStillLive.selector, LibInventoryMigration.orderHash(plan.removeOrders[0])
            )
        );
        harness.verify(plan, moved);
    }

    function test_verify_orderMissing_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        OrderV4 memory added = LibInventoryMigration.addedOrder(plan.addOrderCalls[0], address(inv), 0);
        vm.prank(ADMIN);
        inv.removeOrder4(added, new TaskV3[](0));
        vm.expectRevert(
            abi.encodeWithSelector(LibInventoryMigration.OrderMissing.selector, LibInventoryMigration.orderHash(added))
        );
        harness.verify(plan, moved);
    }

    function test_verify_operatorMissing_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        inv.revokeRole(OPERATOR_ROLE, newOperator);
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.OperatorMissingOnNew.selector, newOperator));
        harness.verify(plan, moved);
    }

    function test_verify_revokedOperatorStillOnOld_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        IAccessControl(OLD).grantRole(OPERATOR_ROLE, OLD_OPERATOR_A);
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.OperatorStillOnOld.selector, OLD_OPERATOR_A));
        harness.verify(plan, moved);
    }

    function test_verify_grantedOperatorStillOnOld_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        IAccessControl(OLD).grantRole(OPERATOR_ROLE, newOperator);
        vm.expectRevert(abi.encodeWithSelector(LibInventoryMigration.OperatorStillOnOld.selector, newOperator));
        harness.verify(plan, moved);
    }

    function test_verify_oldNotPaused_reverts() external {
        (MigrationPlan memory plan, uint256[] memory moved) = _migrate();
        vm.prank(ADMIN);
        RaindexInventory(OLD).unpause();
        vm.expectRevert(LibInventoryMigration.OldInventoryNotPaused.selector);
        harness.verify(plan, moved);
    }
}
