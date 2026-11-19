// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.sol";
import {RaindexInventory} from "../../src/RaindexInventory.sol";

/// @notice Offline tests of `script/Deploy.sol`. They need no RPC.
contract DeployTest is Test {
    /// @dev The RaindexV6 that the live inventories use as `RAINDEX`.
    address internal constant LIVE_RAINDEX = 0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20;
    /// @dev `keccak256` of the runtime of every live inventory (v0.2.0 with
    /// `LIVE_RAINDEX`), for example on Ethereum and Robinhood Chain.
    bytes32 internal constant LIVE_RUNTIME_CODEHASH =
        0x82e5c10ad17e1f3380cacefbcaee91801abd8352e68a7f07006813d4949b6ab3;

    Deploy internal script = new Deploy();
    address internal admin = makeAddr("admin");

    // ---- network table ----

    function assertNetwork(string memory suiteName, string memory rpcEndpoint, uint256 chainId) internal view {
        (string memory actualEndpoint, uint256 actualChainId) = script.network(suiteName);
        assertEq(actualEndpoint, rpcEndpoint);
        assertEq(actualChainId, chainId);
    }

    /// Every `network` option of `deploy-inventory.yaml`.
    function testNetworkTable() external view {
        assertNetwork("base", "base", 8453);
        assertNetwork("base-sepolia", "base_sepolia", 84532);
        assertNetwork("bsc", "bsc", 56);
        assertNetwork("ethereum", "ethereum", 1);
        assertNetwork("hyperevm", "hyperevm", 999);
        assertNetwork("robinhood", "robinhood", 4663);
        assertNetwork("zerog", "zerog", 16661);
    }

    function testNetworkUnknownSuiteReverts() external {
        vm.expectRevert(bytes("Unknown deployment suite"));
        script.network("0g");
    }

    // ---- release runtime ----

    /// This build deploys the exact runtime that the live inventories run.
    function testDeployIsLiveRuntime() external {
        RaindexInventory inventory = script.deploy(admin, LIVE_RAINDEX);
        assertEq(keccak256(address(inventory).code), LIVE_RUNTIME_CODEHASH);
        assertEq(address(inventory.RAINDEX()), LIVE_RAINDEX);
        assertTrue(inventory.hasRole(inventory.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// The check holds for any `raindex`, not only the live one.
    function testDeployAnyRaindex(address raindex) external {
        vm.assume(raindex != address(0));
        RaindexInventory inventory = script.deploy(admin, raindex);
        assertEq(address(inventory.RAINDEX()), raindex);
        assertTrue(script.isReleaseRuntime(address(inventory), raindex));
    }

    /// A drifted build reverts in `deploy`: the creation code that `Deploy`
    /// embeds gets one runtime byte changed, as a source, dependency or
    /// toolchain change would.
    function testDeployRevertsOnDriftedBuild() external {
        bytes memory creation = type(RaindexInventory).creationCode;
        bytes memory scriptCode = address(script).code;
        uint256 at = indexOf(scriptCode, creation);
        // The last creation code byte is the last runtime byte, which is not
        // in a `RAINDEX` slot.
        scriptCode[at + creation.length - 1] ^= 0x01;
        vm.etch(address(script), scriptCode);

        vm.expectRevert(bytes("RaindexInventory runtime is not v0.2.0"));
        script.deploy(admin, LIVE_RAINDEX);
    }

    /// Any one changed byte fails the check, in a `RAINDEX` slot or not.
    function testIsReleaseRuntimeRejectsChangedByte(uint256 index) external {
        bytes memory code = address(script.deploy(admin, LIVE_RAINDEX)).code;
        index = bound(index, 0, code.length - 1);
        code[index] ^= 0x01;
        assertFalse(script.isReleaseRuntime(etched(code), LIVE_RAINDEX));
    }

    /// The runtime of one `raindex` fails the check for another.
    function testIsReleaseRuntimeRejectsOtherRaindex(address raindex, address other) external {
        vm.assume(raindex != address(0) && other != raindex);
        RaindexInventory inventory = script.deploy(admin, raindex);
        assertFalse(script.isReleaseRuntime(address(inventory), other));
    }

    function testIsReleaseRuntimeRejectsWrongSize() external {
        bytes memory code = address(script.deploy(admin, LIVE_RAINDEX)).code;
        assertFalse(script.isReleaseRuntime(etched(bytes.concat(code, hex"00")), LIVE_RAINDEX));
        assertFalse(script.isReleaseRuntime(makeAddr("no code"), LIVE_RAINDEX));
    }

    /// A fresh address that holds `code`.
    function etched(bytes memory code) internal returns (address target) {
        target = makeAddr("etched");
        vm.etch(target, code);
    }

    /// The offset of the first `needle` in `haystack`. Fails the test if none.
    function indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256) {
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            uint256 j = 0;
            while (j < needle.length && haystack[i + j] == needle[j]) j++;
            if (j == needle.length) return i;
        }
        revert("needle not found");
    }
}
