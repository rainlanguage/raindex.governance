// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

import {LibInventoryMigration, MigrationPlan, AdminCall} from "../script/lib/LibInventoryMigration.sol";

/// @dev External wrappers, so tests can expect the library's reverts.
contract MigrationHarness {
    function amounts(MigrationPlan memory plan) external view returns (uint256[] memory) {
        return LibInventoryMigration.amounts(plan);
    }

    function needsFreeze(MigrationPlan memory plan) external view returns (bool) {
        return LibInventoryMigration.needsFreeze(plan);
    }

    function freezeCall(MigrationPlan memory plan) external view returns (AdminCall memory) {
        return LibInventoryMigration.freezeCall(plan);
    }

    function calls(MigrationPlan memory plan, uint256[] memory moved) external view returns (AdminCall[] memory) {
        return LibInventoryMigration.calls(plan, moved);
    }

    function resumeCalls(MigrationPlan memory plan, address admin, bytes memory signedDrain)
        external
        view
        returns (AdminCall[] memory out, uint256[] memory moved)
    {
        return LibInventoryMigration.resumeCalls(plan, admin, signedDrain);
    }

    function movedFromDrain(MigrationPlan memory plan, bytes memory signedDrain)
        external
        view
        returns (uint256[] memory)
    {
        return LibInventoryMigration.movedFromDrain(plan, signedDrain);
    }

    function verify(MigrationPlan memory plan, uint256[] memory moved) external view {
        LibInventoryMigration.verify(plan, moved);
    }
}
