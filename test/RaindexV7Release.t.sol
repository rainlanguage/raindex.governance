// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {RAINDEX_V7, RAINDEX_V7_CODEHASH} from "../script/lib/RaindexV7Release.sol";

/// @notice The released Raindex V7 is at `RAINDEX_V7` with the release
/// codehash on every network the inventory runs on.
contract RaindexV7ReleaseTest is Test {
    function _check(string memory network) internal {
        vm.createSelectFork(network);
        assertEq(RAINDEX_V7.codehash, RAINDEX_V7_CODEHASH, network);
    }

    function test_releasedV7_base() external {
        _check("base");
    }

    function test_releasedV7_ethereum() external {
        _check("ethereum");
    }

    function test_releasedV7_robinhood() external {
        _check("robinhood");
    }

    function test_releasedV7_baseSepolia() external {
        _check("base_sepolia");
    }

    function test_releasedV7_bsc() external {
        _check("bsc");
    }
}
