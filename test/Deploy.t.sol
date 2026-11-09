// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    Deploy,
    UnknownDeploymentSuite,
    ChainIdMismatch,
    ZeroAdmin,
    AdminIsDeployer,
    RaindexNotReleasedV7
} from "../script/Deploy.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {RAINDEX_V7, RAINDEX_V7_CODEHASH} from "../script/lib/RaindexV7Release.sol";

/// @notice The deploy script's checks and a full `run` on a Base fork.
contract DeployTest is Test {
    Deploy internal deploy;
    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.createSelectFork("base");
        deploy = new Deploy();
    }

    function test_suiteNetwork_knownSuites() external view {
        string[5] memory suites = ["base", "base-sepolia", "bsc", "ethereum", "robinhood"];
        string[5] memory endpoints = ["base", "base_sepolia", "bsc", "ethereum", "robinhood"];
        uint256[5] memory ids = [uint256(8453), 84532, 56, 1, 4663];
        for (uint256 i = 0; i < suites.length; i++) {
            (string memory endpoint, uint256 id) = deploy.suiteNetwork(suites[i]);
            assertEq(endpoint, endpoints[i], suites[i]);
            assertEq(id, ids[i], suites[i]);
        }
    }

    function test_suiteNetwork_unknown_reverts() external {
        vm.expectRevert(abi.encodeWithSelector(UnknownDeploymentSuite.selector, "basee"));
        deploy.suiteNetwork("basee");
        // HyperEVM has no released V7, so the suite is gone.
        vm.expectRevert(abi.encodeWithSelector(UnknownDeploymentSuite.selector, "hyperevm"));
        deploy.suiteNetwork("hyperevm");
    }

    /// @dev An RPC secret that serves the wrong chain stops the deploy.
    function test_checkChainId_mismatch_reverts() external {
        deploy.checkChainId(8453);
        vm.expectRevert(abi.encodeWithSelector(ChainIdMismatch.selector, 1, 8453));
        deploy.checkChainId(1);
    }

    function test_checkInputs_passesOnBase() external view {
        deploy.checkInputs(admin, deployer);
    }

    function test_checkInputs_zeroAdmin_reverts() external {
        vm.expectRevert(ZeroAdmin.selector);
        deploy.checkInputs(address(0), deployer);
    }

    function test_checkInputs_adminIsDeployer_reverts() external {
        vm.expectRevert(abi.encodeWithSelector(AdminIsDeployer.selector, deployer));
        deploy.checkInputs(deployer, deployer);
    }

    /// @dev A chain where `RAINDEX_V7` holds other code (or none) is refused.
    function test_checkInputs_otherCode_reverts() external {
        vm.etch(RAINDEX_V7, hex"00");
        vm.expectRevert(abi.encodeWithSelector(RaindexNotReleasedV7.selector, RAINDEX_V7, keccak256(hex"00")));
        deploy.checkInputs(admin, deployer);
    }

    function test_checkInputs_noCode_reverts() external {
        vm.etch(RAINDEX_V7, "");
        vm.expectRevert(abi.encodeWithSelector(RaindexNotReleasedV7.selector, RAINDEX_V7, keccak256("")));
        deploy.checkInputs(admin, deployer);
    }

    /// @dev `run` end to end: the inventory lands at the deployer's next
    /// address, points at V7, and only the admin holds a role.
    function test_run_deploysOnV7() external {
        uint256 key = 0xa11ce;
        address deployerAddr = vm.addr(key);
        vm.setEnv("DEPLOYMENT_KEY", vm.toString(key));
        vm.setEnv("DEPLOYMENT_SUITE", "base");
        vm.setEnv("INVENTORY_ADMIN", vm.toString(admin));
        vm.deal(deployerAddr, 1 ether);

        deploy.run();

        // `run` selects a new fork, so read the nonce after it ran.
        RaindexInventory inv = RaindexInventory(vm.computeCreateAddress(deployerAddr, vm.getNonce(deployerAddr) - 1));
        assertEq(address(inv.RAINDEX()), RAINDEX_V7, "raindex");
        assertEq(RAINDEX_V7.codehash, RAINDEX_V7_CODEHASH, "released V7");
        assertTrue(inv.hasRole(inv.DEFAULT_ADMIN_ROLE(), admin), "admin");
        assertFalse(inv.hasRole(inv.DEFAULT_ADMIN_ROLE(), deployerAddr), "deployer has no admin");
        assertFalse(inv.hasRole(inv.OPERATOR_ROLE(), deployerAddr), "deployer has no operator");
    }
}
