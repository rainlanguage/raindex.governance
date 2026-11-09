// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV7} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";

/// @notice The inventory's drop-in claim: every forwarded entry point has the
/// `IRaindexV7` selector, so tooling and consumers that encode against V7 reach
/// it. Needs no RPC.
contract RaindexInventorySelectorsTest is Test {
    function test_dropInSelectorsMatchRaindexV7() external pure {
        assertEq(RaindexInventory.deposit5.selector, IRaindexV7.deposit5.selector, "deposit5");
        assertEq(RaindexInventory.withdraw5.selector, IRaindexV7.withdraw5.selector, "withdraw5");
        assertEq(RaindexInventory.addOrder5.selector, IRaindexV7.addOrder5.selector, "addOrder5");
        assertEq(RaindexInventory.removeOrder4.selector, IRaindexV7.removeOrder4.selector, "removeOrder4");
        assertEq(RaindexInventory.entask3.selector, IRaindexV7.entask3.selector, "entask3");
        assertEq(RaindexInventory.quote3.selector, IRaindexV7.quote3.selector, "quote3");
        assertEq(RaindexInventory.vaultBalance2.selector, IRaindexV7.vaultBalance2.selector, "vaultBalance2");
        assertEq(RaindexInventory.orderExists.selector, IRaindexV7.orderExists.selector, "orderExists");
    }
}
