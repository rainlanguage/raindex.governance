// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RaindexInventory} from "../src/RaindexInventory.sol";
import {IRaindexV7} from "raindex-interface-0.1.13/src/interface/IRaindexV7.sol";
import {RAINDEX_V7, RAINDEX_V7_CODEHASH} from "./lib/RaindexV7Release.sol";

// Network selector (DEPLOYMENT_SUITE env): picks which foundry.toml
// rpc_endpoint to fork + broadcast to.
bytes32 constant SUITE_BASE = keccak256("base");
bytes32 constant SUITE_BASE_SEPOLIA = keccak256("base-sepolia");
bytes32 constant SUITE_BSC = keccak256("bsc");
bytes32 constant SUITE_ETHEREUM = keccak256("ethereum");
bytes32 constant SUITE_ROBINHOOD = keccak256("robinhood");

/// @notice `DEPLOYMENT_SUITE` names no known network.
error UnknownDeploymentSuite(string suite);
/// @notice The RPC for the suite serves a different chain.
error ChainIdMismatch(uint256 expected, uint256 actual);
/// @notice `INVENTORY_ADMIN` is the zero address.
error ZeroAdmin();
/// @notice `INVENTORY_ADMIN` is the deploy key's address. The deploy key is a
/// shared hot key and must never own the inventory.
error AdminIsDeployer(address admin);
/// @notice The chain has no released Raindex V7 at `RAINDEX_V7`: no code, or
/// other code.
error RaindexNotReleasedV7(address raindex, bytes32 codehash);

/// @title Deploy
/// @notice Manual (`workflow_dispatch`) deploy of a fresh `RaindexInventory`
/// on the released Raindex V7. Reads `DEPLOYMENT_KEY` (deployer private key),
/// `DEPLOYMENT_SUITE` (network) and `INVENTORY_ADMIN` from env, all required.
/// The Raindex is not an input: it is always `RAINDEX_V7`, and the script
/// reverts unless that address holds the released V7 code on the chain.
///
/// The deployer only pays gas and is NOT granted any role. `INVENTORY_ADMIN`
/// receives `DEFAULT_ADMIN_ROLE`, which already subsumes `OPERATOR_ROLE`
/// (deposit5/withdraw5 accept either), so no follow-up grant is needed for the
/// admin. Operator grants to any venue adapters are a separate admin-signed
/// step, made by the deployed contract's owner.
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYMENT_KEY");
        address admin = vm.envAddress("INVENTORY_ADMIN");
        (string memory rpcEndpoint, uint256 expectedChainId) = suiteNetwork(vm.envString("DEPLOYMENT_SUITE"));

        vm.createSelectFork(vm.rpcUrl(rpcEndpoint));
        checkChainId(expectedChainId);
        checkInputs(admin, vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        RaindexInventory inventory = new RaindexInventory(admin, IRaindexV7(RAINDEX_V7));
        vm.stopBroadcast();

        console2.log("RaindexInventory deployed at:", address(inventory));
        console2.log("  DEFAULT_ADMIN_ROLE:", admin);
        console2.log("  raindex (V7):", RAINDEX_V7);
    }

    /// @notice The foundry.toml rpc_endpoint and chain id of a deployment
    /// suite. Reverts `UnknownDeploymentSuite` for any other name.
    function suiteNetwork(string memory suite) public pure returns (string memory rpcEndpoint, uint256 chainId) {
        bytes32 suiteHash = keccak256(bytes(suite));
        if (suiteHash == SUITE_BASE) return ("base", 8453);
        if (suiteHash == SUITE_BASE_SEPOLIA) return ("base_sepolia", 84532);
        if (suiteHash == SUITE_BSC) return ("bsc", 56);
        if (suiteHash == SUITE_ETHEREUM) return ("ethereum", 1);
        if (suiteHash == SUITE_ROBINHOOD) return ("robinhood", 4663);
        revert UnknownDeploymentSuite(suite);
    }

    /// @notice Reverts unless the current chain is `expected`, so an RPC that
    /// serves the wrong chain stops the deploy.
    function checkChainId(uint256 expected) public view {
        if (block.chainid != expected) revert ChainIdMismatch(expected, block.chainid);
    }

    /// @notice The checks `run` makes on the current chain before it
    /// broadcasts.
    /// @param admin The address to receive `DEFAULT_ADMIN_ROLE`.
    /// @param deployer The deploy key's address.
    function checkInputs(address admin, address deployer) public view {
        if (admin == address(0)) revert ZeroAdmin();
        if (admin == deployer) revert AdminIsDeployer(admin);
        if (RAINDEX_V7.codehash != RAINDEX_V7_CODEHASH) revert RaindexNotReleasedV7(RAINDEX_V7, RAINDEX_V7.codehash);
    }
}
