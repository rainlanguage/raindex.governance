// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {RaindexInventoryTestBase} from "./RaindexInventoryTestBase.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {TaskV2} from "raindex-interface-0.1.2/src/interface/deprecated/v5/IOrderBookV5.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal ERC20 whose transfer hooks attempt ONE re-entrant call into a
/// target and record the outcome. Deposited into a REAL Raindex vault, so the
/// full inventory→Raindex→token call chain is live; only the token is hostile.
contract ReentrantERC20 {
    string public constant name = "Evil";
    string public constant symbol = "EVIL";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentryCalldata;
    bool public armed;
    uint256 public skipHooks;
    bool internal inFlight;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @param skipHooks_ Number of transfer hooks to let pass before firing,
    /// to choose WHERE in the call chain the re-entry happens.
    function arm(address target_, bytes calldata reentryCalldata_, uint256 skipHooks_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
        skipHooks = skipHooks_;
        armed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        _hook();
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _hook() internal {
        if (armed && !inFlight) {
            if (skipHooks > 0) {
                skipHooks--;
                return;
            }
            inFlight = true;
            armed = false;
            //slither-disable-next-line low-level-calls
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            reentrySucceeded = ok;
            if (!ok && ret.length >= 4) reentryRevertSelector = bytes4(ret);
            inFlight = false;
        }
    }
}

/// @dev Minimal ERC20 that over-delivers on `transfer` into one beneficiary:
/// moves `amount` and mints `bonus` extra to the recipient. Models any token
/// whose transfers can deliver more than requested (rebasing up, reward-bearing,
/// airdropping) so "forward everything received" is observable.
contract DonatingERC20 {
    string public constant name = "Donor";
    string public constant symbol = "DONR";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public beneficiary;
    uint256 public bonus;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setDonation(address beneficiary_, uint256 bonus_) external {
        beneficiary = beneficiary_;
        bonus = bonus_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        if (to == beneficiary && bonus > 0) {
            balanceOf[to] += bonus;
            totalSupply += bonus;
            bonus = 0;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Reentrancy + weird-token behavior, driven by surviving mutants W3,
/// D3 (nonReentrant on both fund paths was unpinned) and W7 (nothing
/// distinguished forwarding `received` from forwarding `requested`).
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
