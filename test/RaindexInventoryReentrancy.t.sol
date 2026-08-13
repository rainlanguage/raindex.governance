// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {ReentrantERC20} from "./hostile/ReentrantERC20.sol";
import {DonatingERC20} from "./hostile/DonatingERC20.sol";
import {TaskV2} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RaindexInventoryReentrancyTest is RaindexInventoryTestBase {
    using LibDecimalFloat for Float;

    event OperatorWithdraw(address indexed operator, address indexed token, bytes32 indexed vaultId, uint256 amount);

    bytes32 internal constant EVIL_VAULT = bytes32(uint256(0xe1));

    /// @dev The guard, not the RBAC gate, must be what stops a re-entrant
    /// withdraw: the token is granted OPERATOR_ROLE so the gate passes.
    function test_withdraw_reentrancyBlocked() external {
        ReentrantERC20 evil = new ReentrantERC20();
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, address(evil));

        // Seed a real Raindex vault with the evil token through the inventory.
        evil.mint(operator, 10e6);
        vm.startPrank(operator);
        evil.approve(address(inv), 10e6);
        inv.deposit4(address(evil), EVIL_VAULT, _float(10e6), _noTasks());
        vm.stopPrank();

        // Re-enter withdraw4 from inside the inventory's OWN forward transfer
        // to the caller (hook #2). Hook #1 (Raindex's transfer to the
        // inventory) is skipped: that window sits inside Raindex's own
        // reentrancy guard, which shares the OZ error selector, so it cannot
        // distinguish the inventory's guard from Raindex's. The forward step
        // happens AFTER Raindex returns — only the inventory's guard protects
        // it.
        evil.arm(
            address(inv),
            abi.encodeCall(RaindexInventory.withdraw4, (address(evil), EVIL_VAULT, _float(1e6), _noTasks())),
            1
        );
        uint256 opBefore = evil.balanceOf(operator);
        vm.prank(operator);
        inv.withdraw4(address(evil), EVIL_VAULT, _float(5e6), _noTasks());

        assertFalse(evil.reentrySucceeded(), "re-entrant withdraw4 must revert");
        assertEq(
            evil.reentryRevertSelector(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "stopped by the reentrancy guard specifically"
        );
        assertEq(evil.balanceOf(operator) - opBefore, 5e6, "outer withdraw unaffected");
    }

    function test_deposit_reentrancyBlocked() external {
        ReentrantERC20 evil = new ReentrantERC20();
        vm.prank(admin);
        inv.grantRole(OPERATOR_ROLE, address(evil));
        evil.mint(address(evil), 1e6); // funds for the re-entrant deposit attempt
        evil.mint(operator, 10e6);

        // Re-enter deposit4 from inside the inventory's safeTransferFrom pull
        // (hook #1) — this window precedes any Raindex involvement, so the
        // inventory's own guard is what must trip.
        evil.arm(
            address(inv),
            abi.encodeCall(RaindexInventory.deposit4, (address(evil), EVIL_VAULT, _float(1e6), _noTasks())),
            0
        );
        vm.startPrank(operator);
        evil.approve(address(inv), 10e6);
        inv.deposit4(address(evil), EVIL_VAULT, _float(10e6), _noTasks());
        vm.stopPrank();

        assertFalse(evil.reentrySucceeded(), "re-entrant deposit4 must revert");
        assertEq(
            evil.reentryRevertSelector(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "stopped by the reentrancy guard specifically"
        );
        assertEq(_vaultRaw(address(evil), EVIL_VAULT), 10e6, "outer deposit landed exactly once");
    }

    /// @dev NatSpec contract: "forward everything received to the caller."
    /// When Raindex's outbound transfer over-delivers (donating token), the
    /// caller must receive the full balance delta, not just the request.
    function test_withdraw_forwardsEverythingReceived_overDelivery() external {
        DonatingERC20 donor = new DonatingERC20();
        donor.mint(operator, 10e6);
        vm.startPrank(operator);
        donor.approve(address(inv), 10e6);
        inv.deposit4(address(donor), EVIL_VAULT, _float(10e6), _noTasks());
        vm.stopPrank();

        // Next transfer INTO the inventory delivers +2e6 on top.
        donor.setDonation(address(inv), 2e6);

        uint256 opBefore = donor.balanceOf(operator);
        // The event must report what was RECEIVED (and forwarded), not the
        // request.
        vm.expectEmit(true, true, true, true, address(inv));
        emit OperatorWithdraw(operator, address(donor), EVIL_VAULT, 7e6);
        vm.prank(operator);
        inv.withdraw4(address(donor), EVIL_VAULT, _float(5e6), _noTasks());

        assertEq(donor.balanceOf(operator) - opBefore, 7e6, "caller receives request + over-delivery");
        assertEq(donor.balanceOf(address(inv)), 0, "nothing stranded on the inventory");
    }
}
