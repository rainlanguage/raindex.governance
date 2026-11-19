// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RaindexInventory} from "src/RaindexInventory.sol";
import {IRaindexV6} from "raindex-interface-0.1.2/src/interface/IRaindexV6.sol";

// Network selector (DEPLOYMENT_SUITE env): picks which foundry.toml
// rpc_endpoint to fork + broadcast to. The constructor args are passed
// explicitly via env, so this script bakes in NO deployment-specific
// addresses — every value is supplied at dispatch time.
bytes32 constant SUITE_BASE = keccak256("base");
bytes32 constant SUITE_BASE_SEPOLIA = keccak256("base-sepolia");
bytes32 constant SUITE_BSC = keccak256("bsc");
bytes32 constant SUITE_ETHEREUM = keccak256("ethereum");
bytes32 constant SUITE_HYPEREVM = keccak256("hyperevm");
bytes32 constant SUITE_ROBINHOOD = keccak256("robinhood");
bytes32 constant SUITE_ZEROG = keccak256("zerog");

// The v0.2.0 `RaindexInventory` runtime, which every live inventory runs. Its
// only immutable is `RAINDEX`, so the runtime differs per deploy only in the 11
// 32-byte slots that hold it. The hash is of the runtime with those slots
// zeroed. The size, slot offsets and hash come from the v0.2.0 build artifact
// (`deployedBytecode.object` and `immutableReferences`).
bytes32 constant INVENTORY_V0_2_0_RUNTIME_TEMPLATE_HASH =
    0xf778e5e01e9575ec87a3b3d512b46d373588f869f6122315be23519728f31427;
uint256 constant INVENTORY_V0_2_0_RUNTIME_SIZE = 10222;

/// @title Deploy
/// @notice Manual (`workflow_dispatch`) deploy of a fresh `RaindexInventory`.
/// Reads `DEPLOYMENT_KEY` (deployer private key), `DEPLOYMENT_SUITE` (network),
/// and the two constructor args `INVENTORY_ADMIN` + `INVENTORY_RAINDEX` from
/// env — all required, no defaults. RPC + Etherscan keys come from
/// `foundry.toml`'s `[rpc_endpoints]` / `[etherscan]`.
///
/// The deployer only pays gas and is NOT granted any role. `INVENTORY_ADMIN`
/// receives `DEFAULT_ADMIN_ROLE`, which already subsumes `OPERATOR_ROLE`
/// (deposit4/withdraw4 accept either), so no follow-up grant is needed for the
/// admin. Operator grants to any venue adapters are a separate admin-signed
/// step, made by the deployed contract's owner.
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYMENT_KEY");
        (string memory rpcEndpoint, uint256 expectedChainId) = network(vm.envString("DEPLOYMENT_SUITE"));

        // Required — reverts if unset. admin -> DEFAULT_ADMIN_ROLE; raindex is
        // the IRaindexV6 OrderBook the inventory owns its orders/vaults in.
        address admin = vm.envAddress("INVENTORY_ADMIN");
        address raindex = vm.envAddress("INVENTORY_RAINDEX");
        require(admin != address(0) && raindex != address(0), "zero admin/raindex");

        vm.createSelectFork(vm.rpcUrl(rpcEndpoint));
        require(block.chainid == expectedChainId, "RPC chain ID does not match deployment suite");
        require(raindex.code.length > 0, "raindex has no code");

        vm.startBroadcast(deployerKey);
        RaindexInventory inventory = deploy(admin, raindex);
        vm.stopBroadcast();

        console2.log("RaindexInventory deployed at:", address(inventory));
        console2.log("  DEFAULT_ADMIN_ROLE:", admin);
        console2.log("  raindex (OrderBook):", raindex);
    }

    /// @notice The `foundry.toml` rpc_endpoint and chain id of a
    /// `DEPLOYMENT_SUITE` name. Reverts on an unknown name.
    function network(string memory suiteName) public pure returns (string memory rpcEndpoint, uint256 expectedChainId) {
        bytes32 suite = keccak256(bytes(suiteName));
        if (suite == SUITE_BASE) {
            rpcEndpoint = "base";
            expectedChainId = 8453;
        } else if (suite == SUITE_BASE_SEPOLIA) {
            rpcEndpoint = "base_sepolia";
            expectedChainId = 84532;
        } else if (suite == SUITE_BSC) {
            rpcEndpoint = "bsc";
            expectedChainId = 56;
        } else if (suite == SUITE_ETHEREUM) {
            rpcEndpoint = "ethereum";
            expectedChainId = 1;
        } else if (suite == SUITE_HYPEREVM) {
            rpcEndpoint = "hyperevm";
            expectedChainId = 999;
        } else if (suite == SUITE_ROBINHOOD) {
            rpcEndpoint = "robinhood";
            expectedChainId = 4663;
        } else if (suite == SUITE_ZEROG) {
            rpcEndpoint = "zerog";
            expectedChainId = 16661;
        } else {
            revert("Unknown deployment suite");
        }
    }

    /// @notice Deploys a `RaindexInventory` and requires that its runtime is the
    /// v0.2.0 release. `forge script` simulates the whole script before it
    /// broadcasts, so a build that drifted from v0.2.0 reverts in the
    /// simulation and sends no transaction.
    function deploy(address admin, address raindex) public returns (RaindexInventory inventory) {
        inventory = new RaindexInventory(admin, IRaindexV6(raindex));
        require(isReleaseRuntime(address(inventory), raindex), "RaindexInventory runtime is not v0.2.0");
    }

    /// @notice True only when the code at `inventory` is the v0.2.0
    /// `RaindexInventory` runtime with `raindex` as `RAINDEX`: the right size,
    /// `raindex` in each `RAINDEX` slot, and the v0.2.0 template hash once those
    /// slots are zeroed.
    function isReleaseRuntime(address inventory, address raindex) public view returns (bool) {
        bytes memory code = inventory.code;
        if (code.length != INVENTORY_V0_2_0_RUNTIME_SIZE) return false;
        uint256[11] memory slots = [uint256(598), 1200, 1379, 1798, 2228, 2589, 3159, 3260, 3760, 4725, 4853];
        bytes32 raindexWord = bytes32(uint256(uint160(raindex)));
        for (uint256 i = 0; i < slots.length; i++) {
            for (uint256 j = 0; j < 32; j++) {
                if (code[slots[i] + j] != raindexWord[j]) return false;
                code[slots[i] + j] = 0;
            }
        }
        return keccak256(code) == INVENTORY_V0_2_0_RUNTIME_TEMPLATE_HASH;
    }
}
