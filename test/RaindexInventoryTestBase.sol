// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV7, TaskV3} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Shared fork-test scaffolding for the `RaindexInventory` suites.
/// Same live-Base setup as `RaindexInventoryForkTest`: the EXACT deployed
/// Raindex at 0x91b9… (V7), real USDC. A few forwarding tests mock single Raindex
/// responses with `vm.mockCall`.
abstract contract RaindexInventoryTestBase is Test {
    using LibDecimalFloat for Float;

    IRaindexV7 internal constant RAINDEX = IRaindexV7(0x91b95120D085Aa99C05167f3767eB63460c1dCaC);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 decimals
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // 18 decimals

    bytes32 internal constant VAULT = bytes32(uint256(1));

    /// @dev Mirrors of the inventory's events for `vm.expectEmit`. Keep them
    /// identical to `RaindexInventory`; `test_eventSelectorsMatchContract`
    /// fails if they drift.
    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);
    event OperatorDeposit(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    RaindexInventory internal inv;
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    bytes32 internal OPERATOR_ROLE;
    bytes32 internal ADMIN_ROLE;

    function setUp() public virtual {
        vm.createSelectFork("base");
        inv = new RaindexInventory(admin, RAINDEX);
        OPERATOR_ROLE = inv.OPERATOR_ROLE();
        ADMIN_ROLE = inv.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, operator);
    }

    /// @dev Raw vault balance as seen through Raindex, floored to the token's
    /// own decimals.
    function _vaultRaw(address token, bytes32 vaultId) internal view returns (uint256) {
        Float bal = RAINDEX.vaultBalance2(address(inv), token, vaultId);
        (uint256 amount,) = bal.toFixedDecimalLossy(IERC20Metadata(token).decimals());
        return amount;
    }

    /// @dev Exact Float for `amount` raw units at `decimals`. Pure on purpose:
    /// no external call, so evaluating it as an argument right after a
    /// single-shot `vm.prank` does not consume the prank.
    function _floatAt(uint256 amount, uint8 decimals) internal pure returns (Float f) {
        (f,) = LibDecimalFloat.fromFixedDecimalLossyPacked(amount, decimals);
    }

    /// @dev Exact Float for `amount` raw USDC units (6 decimals).
    function _float(uint256 amount) internal pure returns (Float) {
        return _floatAt(amount, 6);
    }

    /// @dev `who` must hold `DEFAULT_ADMIN_ROLE` or `OPERATOR_ROLE`; deals +
    /// approves + deposits `amount` of USDC to `vaultId`.
    function _depositAs(address who, bytes32 vaultId, uint256 amount) internal {
        deal(USDC, who, amount);
        vm.startPrank(who);
        IERC20(USDC).approve(address(inv), amount);
        inv.deposit5(USDC, vaultId, _float(amount), new TaskV3[](0));
        vm.stopPrank();
    }

    function _noTasks() internal pure returns (TaskV3[] memory) {
        return new TaskV3[](0);
    }
}
