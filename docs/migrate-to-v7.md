# Move a pool from a V6 `RaindexInventory` to a V7 one

This runbook moves the capital and orders of a live V6 `RaindexInventory` to a
new `RaindexInventory` on Raindex V7 (`RAINDEX_V7` in
[`script/lib/RaindexV7Release.sol`](../script/lib/RaindexV7Release.sol)). Do it
once per chain. Each chain has its own inventory.

The admin must hold `DEFAULT_ADMIN_ROLE` on the old inventory and receives it on
the new one. The admin signs every transaction below. Nothing in this repo
broadcasts for the admin.

## What changes for consumers

The new inventory has the V7 entry points: `deposit5`, `withdraw5`, `addOrder5`,
`removeOrder4`, `entask3`, `quote3`, with `TaskV3[]` tasks. `vaultBalance2`,
`orderExists`, the `OperatorDeposit` and `OperatorWithdraw` events, the errors,
and the vault ids stay the same. A consumer that calls `deposit4` or `withdraw4`
reverts on the new inventory. A consumer that holds the inventory address as an
immutable must be deployed again, pointing at the new inventory.

Orders are not a rename. Build every order again for V7 from its source (for
example with the Raindex CLI against the V7 deployment). Never replay V6
`addOrder4` calldata. V7 signed context is `SignedContextV2` (it adds a domain
separator), so every signed-context producer must move to it.

## 1. Before the move

1. Every consumer is built and reviewed on the V7 entry points, but not yet
   switched over: it still runs against the old inventory.
2. Deploy the new inventory: run the `Deploy RaindexInventory` workflow with the
   network and the admin. The script reverts unless the chain has the released
   V7 at `RAINDEX_V7`, and unless the admin is not the deploy key. Record the
   new address.
3. Deploy the consumers that hold the inventory as an immutable, pointing at the
   new address. Do not grant them a role yet.
4. Build the V7 `addOrder5` calldata for every order, with the new inventory as
   the target.
5. If the admin's signer has a policy, allow it to call `multicall` on both
   inventories and `approve` on each vault token.

## 2. Write the plan

Write the plan under `.tmp/` (gitignored). The scripts can read only that
directory. `MigrateInventory` reads this JSON:

```json
{
  "admin": "0x…",
  "oldInventory": "0x…",
  "newInventory": "0x…",
  "tokens": ["0x…", "0x…"],
  "vaultIds": ["0x…", "0x…"],
  "removeOrderEvents": ["0x…"],
  "addOrderCalls": ["0x…"],
  "revokeOperators": ["0x…"],
  "grantOperators": ["0x…"]
}
```

- `tokens[i]` and `vaultIds[i]` are one vault of the old inventory. List every
  vault that holds capital, including the vaults that orders use. Each vault
  keeps its id on the new inventory. The check covers only the vaults in the
  plan: a vault left out keeps its capital on V6.
- `removeOrderEvents` is the `data` of each `AddOrderV3` log in which V6 Raindex
  added an order for the old inventory (`sender` is the old inventory). For
  example:
  `cast logs --address <V6 Raindex> --from-block <inventory deploy
  block> "AddOrderV3(address,bytes32,(address,(address,address,bytes),(address,bytes32)[],(address,bytes32)[],bytes32))"`.
  Orders that are no longer live are skipped, so the full list is safe. An order
  left out stays live on V6 and can still change its vaults.
- `addOrderCalls` is the V7 `addOrder5` calldata from step 1.4.
- `revokeOperators` is every `OPERATOR_ROLE` holder on the old inventory.
- `grantOperators` is every consumer that gets `OPERATOR_ROLE` on the new one.
- The script checks that `newInventory` points at the released V7.

## 3. Dry run

```bash
MIGRATION_PLAN=.tmp/plan.json forge script script/MigrateInventory.sol \
  --fork-url "$RPC_URL"
```

The script prints the admin transactions, runs them on the fork as the admin,
and checks the end state. It must print `simulation: end state verified` before
`SIGN NOW`. If the run reverts, it prints nothing to sign. Without `--broadcast`
it sends nothing. An unknown `MIGRATION_MODE` reverts.

The check fails if a vault amount is not on the new inventory, if an old vault
still holds a raw unit, if an old order is still live or a new order is missing,
if an operator holds the role on the old inventory or lacks it on the new one,
or if the old inventory is not paused.

## 4. The move

The move has two signing rounds. Sign only what a run prints under `SIGN NOW`.
The script prints it only after the whole move ran on the fork and passed the
end-state check. Wait for each transaction to confirm before the next.

1. Stop the consumers from taking new work, and wait until none of them holds
   capital that it must return to the old inventory. Stop them in their own
   config, not with `pause()` on the old inventory: a paused inventory cannot be
   drained, and the script then reverts `OldInventoryPausedWithFunds`. From the
   freeze until step 5.2, no consumer can use either inventory.
2. Freeze. While the old inventory still has a plan operator or a live plan
   order, the dry run prints `SIGN NOW` above one transaction only:
   `oldInventory.multicall`, which revokes the old operators and removes the
   live orders. Sign it. After it, only the admin can change the old vaults.
3. Run the dry run again. It now prints `SIGN NOW, in order` and reads the
   amounts from the frozen vaults, so they are exact. Save its output: the
   amounts are the `moved` values. Sign its transactions in order:
   1. `oldInventory.multicall`: withdraw every vault to the admin, and
      `pause()`. If a vault holds less than the amount, the batch reverts and
      nothing moves.
   2. `token.approve(newInventory, total)` once for each token.
   3. `newInventory.multicall`: deposit every amount into the same vault id, add
      the V7 orders, and grant the new operators.

Between the drain and the last transaction, the admin wallet holds the whole
pool. Sign them back to back. A sub-raw-unit remainder of a vault stays on V6.

If the move stops after the drain, do not run the normal dry run again: it
reverts `OldInventoryAlreadyDrained`, because the drained vaults read zero.
Instead:

1. Get the exact drained amounts: run the normal dry run with
   `--fork-block-number <drain block - 1>`. The vaults were frozen there, so it
   prints the amounts that the drain moved. Use these, not a saved `PREVIEW`
   output and not hand-typed numbers.
2. Add them as `"moved": [...]` to the plan, and run it with
   `MIGRATION_MODE=resume`. It prints only the approve and new-inventory calls.
   It reverts if every amount is zero, or if the admin does not hold an amount.
   It cannot see an amount that is too low, which is why step 1 matters.

## 5. After the move

1. Right after the last transaction confirms, before anything can trade on V7,
   check the live end state. Add the saved amounts as `"moved": [...]` to the
   plan, and run check mode on a fork pinned to that transaction's block:
   `MIGRATION_MODE=check MIGRATION_PLAN=.tmp/plan.json forge script script/MigrateInventory.sol --fork-url "$RPC_URL" --fork-block-number <block>`.
   It must print `check: live end state verified`. It checks the old side first
   (nothing left on V6), so a later run on a trading pool can fail only on the
   V7 vault amounts, from normal trading.
2. Repoint every consumer's config at the new inventory: the inventory address,
   the vault owner, the Raindex address, and the first block to index (the new
   inventory's deploy block). Then start the consumers again.
3. Check one operator draw and return on the new inventory.
4. Check the orders quote and clear on V7.

## Rollback

- After the freeze only: no funds moved. Grant the old operators again and add
  the V6 orders again (`addOrder4` through the old inventory).
- After the drain, before the last transaction: the old inventory is paused and
  the funds are in the admin wallet. In order: `unpause()` the old inventory,
  `approve` each token to the old inventory, `deposit4` each vault back, add the
  V6 orders again, grant the old operators again, and set any approval to the
  new inventory back to zero. Consumers that were deployed again for V7 cannot
  use the old inventory.
- After the last transaction: going back is a second move, from V7 to V6. This
  script does not build it.
