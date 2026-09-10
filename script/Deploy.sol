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
        bytes32 suite = keccak256(bytes(vm.envString("DEPLOYMENT_SUITE")));

        string memory rpcEndpoint;
        uint256 expectedChainId;
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
        } else {
            revert("Unknown deployment suite");
        }

        // Required — reverts if unset. admin -> DEFAULT_ADMIN_ROLE; raindex is
        // the IRaindexV6 OrderBook the inventory owns its orders/vaults in.
        address admin = vm.envAddress("INVENTORY_ADMIN");
        address raindex = vm.envAddress("INVENTORY_RAINDEX");
        require(admin != address(0) && raindex != address(0), "zero admin/raindex");

        vm.createSelectFork(vm.rpcUrl(rpcEndpoint));
        require(block.chainid == expectedChainId, "RPC chain ID does not match deployment suite");
        require(raindex.code.length > 0, "raindex has no code");

        vm.startBroadcast(deployerKey);
        RaindexInventory inventory = new RaindexInventory(admin, IRaindexV6(raindex));
        vm.stopBroadcast();

        console2.log("RaindexInventory deployed at:", address(inventory));
        console2.log("  DEFAULT_ADMIN_ROLE:", admin);
        console2.log("  raindex (OrderBook):", raindex);
    }
}
