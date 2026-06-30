// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV6} from "raindex-interface-0.1.2/src/interface/IRaindexV6.sol";
import {TaskV2} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Fork tests against the EXACT deployed Raindex on Base mainnet. Every
/// deposit/withdraw hits the live OrderBook at 0xe522…; the operator path is
/// exercised by an address granted `OPERATOR_ROLE`. No mock Raindex — the Float
/// conversions, approvals and vault accounting are all real.
contract RaindexInventoryForkTest is Test {
    using LibDecimalFloat for Float;

    IRaindexV6 internal constant RAINDEX = IRaindexV6(0xe522cB4a5fCb2eb31a52Ff41a4653d85A4fd7C9D);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 decimals

    bytes32 internal constant VAULT = bytes32(uint256(1));

    RaindexInventory internal inv;
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    bytes32 internal OPERATOR_ROLE;
    bytes32 internal ADMIN_ROLE;

    function setUp() external {
        vm.createSelectFork("base");
        inv = new RaindexInventory(admin, RAINDEX);
        OPERATOR_ROLE = inv.OPERATOR_ROLE();
        ADMIN_ROLE = inv.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, operator);
    }

    // ---- helpers ----

    function _vaultRaw(address token, bytes32 vaultId) internal view returns (uint256) {
        Float bal = RAINDEX.vaultBalance2(address(inv), token, vaultId);
        (uint256 amount,) = bal.toFixedDecimalLossy(IERC20Metadata(token).decimals());
        return amount;
    }

    /// @dev Pure on purpose: USDC is 6 dp, hardcoded so this makes NO external
    /// `decimals()` call. If it did, evaluating it as an argument right after a
    /// single-shot `vm.prank` would consume the prank and the real
    /// deposit4/withdraw4 would run unpranked.
    function _float(address, /*token*/ uint256 amount) internal pure returns (Float f) {
        (f,) = LibDecimalFloat.fromFixedDecimalLossyPacked(amount, 6);
    }

    /// @dev `who` must hold a role; deals + approves + deposits `amount` to `vaultId`.
    function _depositAs(address who, address token, bytes32 vaultId, uint256 amount) internal {
        deal(token, who, amount);
        vm.startPrank(who);
        IERC20(token).approve(address(inv), amount);
        inv.deposit4(token, vaultId, _float(token, amount), new TaskV2[](0));
        vm.stopPrank();
    }

    // ---- sanity ----

    function test_realContractsHaveCode() external view {
        assertGt(address(RAINDEX).code.length, 0, "Raindex has no code");
        assertGt(USDC.code.length, 0, "USDC has no code");
    }

    // ---- admin manages funds; funds flow to / from the caller ----

    function test_adminDeposit_thenWithdraw_toCaller() external {
        uint256 amount = 1_000e6;
        _depositAs(admin, USDC, VAULT, amount);
        assertEq(_vaultRaw(USDC, VAULT), amount, "vault holds deposited USDC");

        uint256 adminBefore = IERC20(USDC).balanceOf(admin);
        vm.prank(admin);
        inv.withdraw4(USDC, VAULT, _float(USDC, amount / 2), new TaskV2[](0));
        assertEq(IERC20(USDC).balanceOf(admin) - adminBefore, amount / 2, "admin (caller) receives withdrawn USDC");
        assertEq(_vaultRaw(USDC, VAULT), amount / 2, "vault halved");
    }

    // ---- operator path: funds to / from the OPERATOR, not the admin ----

    function test_operatorWithdraw_fundsGoToOperator() external {
        uint256 amount = 500e6;
        _depositAs(admin, USDC, VAULT, amount); // admin seeds the shared pool

        uint256 opBefore = IERC20(USDC).balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(USDC, amount), new TaskV2[](0));

        assertEq(IERC20(USDC).balanceOf(operator) - opBefore, amount, "operator (caller) receives the funds");
        assertEq(_vaultRaw(USDC, VAULT), 0, "vault drained by the operator draw");
    }

    function test_operatorDeposit_fundsFromOperator() external {
        uint256 amount = 750e6;
        deal(USDC, operator, amount);
        vm.startPrank(operator);
        IERC20(USDC).approve(address(inv), amount);
        inv.deposit4(USDC, VAULT, _float(USDC, amount), new TaskV2[](0));
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(operator), 0, "operator funds swept into vault");
        assertEq(_vaultRaw(USDC, VAULT), amount, "vault credited from the operator");
    }

    function test_operatorRoundTrip_withdrawThenDeposit() external {
        uint256 amount = 1_000e6;
        _depositAs(admin, USDC, VAULT, amount);

        // draw out (e.g. to fund a fill the operator settles elsewhere)
        vm.prank(operator);
        inv.withdraw4(USDC, VAULT, _float(USDC, amount), new TaskV2[](0));
        assertEq(_vaultRaw(USDC, VAULT), 0, "vault emptied");
        assertEq(IERC20(USDC).balanceOf(operator), amount, "operator holds the draw");

        // return proceeds (same token, clean numeric check)
        vm.startPrank(operator);
        IERC20(USDC).approve(address(inv), amount);
        inv.deposit4(USDC, VAULT, _float(USDC, amount), new TaskV2[](0));
        vm.stopPrank();
        assertEq(_vaultRaw(USDC, VAULT), amount, "vault refilled");
        assertEq(IERC20(USDC).balanceOf(operator), 0, "operator nets ~zero across the loop");
    }

    function test_withdraw_insufficientLiquidity_reverts() external {
        _depositAs(admin, USDC, VAULT, 100e6);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(RaindexInventory.InsufficientVaultLiquidity.selector, USDC, 500e6, 100e6)
        );
        inv.withdraw4(USDC, VAULT, _float(USDC, 500e6), new TaskV2[](0));
    }

    // ---- access control ----

    function test_unauthorized_cannotWithdraw() external {
        _depositAs(admin, USDC, VAULT, 100e6);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        inv.withdraw4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));
    }

    function test_unauthorized_cannotDeposit() external {
        address stranger = makeAddr("stranger");
        deal(USDC, stranger, 100e6);
        vm.startPrank(stranger);
        IERC20(USDC).approve(address(inv), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        inv.deposit4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));
        vm.stopPrank();
    }

    function test_orderManagement_onlyAdmin() external {
        // entask2 is admin-gated; a non-admin (even an operator) is rejected
        // before the Raindex call.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.entask2(new TaskV2[](0));
    }

    function test_operatorRole_grantAndRevoke() external {
        _depositAs(admin, USDC, VAULT, 200e6);
        address op2 = makeAddr("op2");

        // not yet an operator -> rejected
        vm.prank(op2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op2, OPERATOR_ROLE)
        );
        inv.withdraw4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));

        // admin grants -> works
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, op2);
        vm.prank(op2);
        inv.withdraw4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));
        assertEq(IERC20(USDC).balanceOf(op2), 100e6, "granted operator can draw");

        // admin revokes -> rejected again
        vm.prank(admin);
        inv.revokeRole(OPERATOR_ROLE, op2);
        vm.prank(op2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op2, OPERATOR_ROLE)
        );
        inv.withdraw4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));
    }

    function test_nonAdmin_cannotGrantOperator() external {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, ADMIN_ROLE)
        );
        inv.grantRole(OPERATOR_ROLE, attacker);
    }

    // ---- pause: fund movement fails closed, order management stays open ----

    function test_pause_blocksOperatorFunds() external {
        _depositAs(admin, USDC, VAULT, 100e6);
        vm.prank(admin);
        inv.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        inv.withdraw4(USDC, VAULT, _float(USDC, 100e6), new TaskV2[](0));
    }

    function test_pause_onlyAdmin() external {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        inv.pause();
    }

    // ---- multicall (admin tooling) ----

    function test_multicall_batchesAdminDeposits() external {
        bytes32 vault2 = bytes32(uint256(2));
        uint256 a = 600e6;
        uint256 b = 400e6;
        deal(USDC, admin, a + b);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(RaindexInventory.deposit4, (USDC, VAULT, _float(USDC, a), new TaskV2[](0)));
        calls[1] = abi.encodeCall(RaindexInventory.deposit4, (USDC, vault2, _float(USDC, b), new TaskV2[](0)));

        vm.startPrank(admin);
        IERC20(USDC).approve(address(inv), a + b);
        inv.multicall(calls);
        vm.stopPrank();

        assertEq(_vaultRaw(USDC, VAULT), a, "vault 1 funded via multicall");
        assertEq(_vaultRaw(USDC, vault2), b, "vault 2 funded via multicall");
    }

    function test_multicall_preservesGate() external {
        // A stranger calling multicall([deposit4]) must still revert — the role
        // gate is enforced on the inner delegatecall, not bypassed.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(RaindexInventory.deposit4, (USDC, VAULT, _float(USDC, 1e6), new TaskV2[](0)));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        inv.multicall(calls);
    }

    // ---- rescue ----

    function test_rescue_sweepsStrayTokens_toAdmin() external {
        deal(USDC, address(inv), 42e6); // stray dust, not in a vault
        uint256 adminBefore = IERC20(USDC).balanceOf(admin);
        vm.prank(admin);
        inv.rescue(USDC, 42e6);
        assertEq(IERC20(USDC).balanceOf(admin) - adminBefore, 42e6, "admin swept stray dust");
    }
}
