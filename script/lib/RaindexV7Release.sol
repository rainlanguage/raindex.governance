// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity ^0.8.25;

/// @dev The released Raindex V7 that `RaindexInventory` targets:
/// rainlanguage/raindex.deploy `sol-v0.1.17`,
/// `src/generated/0_1_17/RaindexV7.sol`. The same address and runtime code are
/// on every network the deploy script offers: Base (8453), Base Sepolia
/// (84532), BSC (56), Ethereum (1) and Robinhood Chain (4663). The deploy
/// script refuses any other code, and `RaindexV7ReleaseTest` checks each one.
address constant RAINDEX_V7 = 0x91b95120D085Aa99C05167f3767eB63460c1dCaC;

/// @dev `keccak256` of the released V7 runtime code (`BYTECODE_HASH` in the
/// same raindex.deploy file).
bytes32 constant RAINDEX_V7_CODEHASH = 0x68d6223023b2516f30acb5b6d4973cbaf5054e9d6156d27c51180939ba233cf5;
