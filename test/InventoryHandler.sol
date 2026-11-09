// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV7, TaskV3} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.3.11/src/lib/LibDecimalFloat.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Randomized driver for the invariant run. Two operators, the admin and
/// a stranger act on one shared vault of the live Base Raindex through the
/// inventory: deposits, withdrawals (including over-draws), pause/unpause,
/// stray donations, rescues, and unauthorized probes. Expected failures are
/// caught and CHECKED here; every unexpected outcome latches a violation flag
/// that the invariants assert on.
contract InventoryHandler is Test {
    using LibDecimalFloat for Float;

    RaindexInventory internal immutable INV;
    IRaindexV7 internal immutable RAINDEX_;
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
    bytes public lastUnexpectedRevert; // revert data behind the latest unexpectedOutcome

    constructor(
        RaindexInventory inv_,
        IRaindexV7 raindex_,
        // forge-lint: disable-next-line(missing-zero-check)
        address usdc_,
        bytes32 vaultId_,
        // forge-lint: disable-next-line(missing-zero-check)
        address admin_,
        address op1_,
        address op2_,
        // forge-lint: disable-next-line(missing-zero-check)
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
        try INV.deposit5(USDC_, VAULT_, _float(amount), new TaskV3[](0)) {
            if (expectFail) pauseBypassed = true;
            gDeposited += amount;
        } catch (bytes memory err) {
            if (!expectFail || _selector(err) != Pausable.EnforcedPause.selector) _unexpected(err);
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
        try INV.withdraw5(USDC_, VAULT_, _float(amount), new TaskV3[](0)) {
            if (paused) pauseBypassed = true;
            if (overdraw) overdrawSettled = true;
            gWithdrawn += amount;
        } catch (bytes memory err) {
            if (paused) {
                if (_selector(err) != Pausable.EnforcedPause.selector) _unexpected(err);
            } else if (overdraw) {
                // The shortfall must be the inventory's own atomic revert, with
                // the exact amounts, not some other failure on the way.
                bytes memory expected = abi.encodeWithSelector(
                    RaindexInventory.InsufficientVaultLiquidity.selector, USDC_, amount, vaultBefore
                );
                if (keccak256(err) != keccak256(expected)) _unexpected(err);
            } else {
                _unexpected(err);
            }
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
        assertTrue(IERC20(USDC_).transfer(address(INV), amount), "donation transfer");
        gStray += amount;
    }

    function rescue(uint256 amount) external {
        amount = bound(amount, 0, gStray);
        vm.prank(ADMIN);
        INV.rescue(USDC_, amount);
        gStray -= amount;
    }

    /// @dev The stranger probes the fund paths, rescue, pause, unpause,
    /// entask3 and role administration. Any success
    /// is an RBAC violation, and so is a revert for any reason other than the
    /// role check: the stranger is funded and has approved the inventory, so
    /// only the role gate can stop it.
    function strangerProbe(uint256 amount) external {
        amount = bound(amount, 1, 1e9);
        _fund(STRANGER, amount);
        vm.startPrank(STRANGER);
        IERC20(USDC_).approve(address(INV), amount);
        try INV.withdraw5(USDC_, VAULT_, _float(amount), new TaskV3[](0)) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.deposit5(USDC_, VAULT_, _float(amount), new TaskV3[](0)) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.rescue(USDC_, amount) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.pause() {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.unpause() {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.entask3(new TaskV3[](0)) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        bytes32 operatorRole = INV.OPERATOR_ROLE();
        try INV.grantRole(operatorRole, STRANGER) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        try INV.revokeRole(operatorRole, operators[0]) {
            rbacBypassed = true;
        } catch (bytes memory err) {
            _expectUnauthorized(err);
        }
        vm.stopPrank();
    }

    function _expectUnauthorized(bytes memory err) internal {
        if (_selector(err) != IAccessControl.AccessControlUnauthorizedAccount.selector) _unexpected(err);
    }

    function _selector(bytes memory err) internal pure returns (bytes4) {
        if (err.length < 4) return bytes4(0);
        // Truncating to the leading 4 bytes is the point: that is the error selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(err);
    }

    function _unexpected(bytes memory err) internal {
        unexpectedOutcome = true;
        lastUnexpectedRevert = err;
        emit log_named_bytes("unexpected revert", err);
    }

    function actorBalances() external view returns (uint256 total) {
        total = IERC20(USDC_).balanceOf(operators[0]) + IERC20(USDC_).balanceOf(operators[1])
            + IERC20(USDC_).balanceOf(ADMIN) + IERC20(USDC_).balanceOf(STRANGER)
            + IERC20(USDC_).balanceOf(address(this));
    }
}
