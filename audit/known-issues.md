# RaindexInventory: known issues for the external audit

Pre-audit gate for [RAI-1707](https://linear.app/makeitrain/issue/RAI-1707):
`adversarial-mutation-test` 0.34.0, then `audit` 0.35.0 (whole repo), both at
their latest version on 2026-11-06.

## Evidence

- Mutation run:
  [`mutation-ledger-2026-11-06.json`](./mutation-ledger-2026-11-06.json). 67
  mutants over `src/RaindexInventory.sol`, 67 killed, 0 survived.
- The append-only stamps (`audit/mutation-test-scans.json` entry,
  `.audit/runs.jsonl`, `.audit/scope.json`) are recorded after this stack
  merges. The ledger check requires their commits to be on the merged history,
  and a squash merge rewrites the stack's commits.
- Raindex V7: the inventory targets Raindex V7
  (`0x91b95120D085Aa99C05167f3767eB63460c1dCaC`, raindex.deploy `sol-v0.1.17`,
  same address and codehash on Base, Ethereum and Robinhood, pinned by
  `test/RaindexV7Release.t.sol`). The run above was taken on the V6 interface.
  The V7 port renames the Raindex calls (`deposit5`, `withdraw5`, `addOrder5`,
  `removeOrder4`, `entask3`, `quote3`, `TaskV3`) and keeps the logic.
- Mutation run on V7:
  [`mutation-ledger-2026-11-09-v7.json`](./mutation-ledger-2026-11-09-v7.json).
  The same 67 mutants over the V7 source, 67 killed, 0 survived, against the
  deployed V7 on a Base fork.

## Fixed before the audit

| Finding                                                                                                                                        | Fix                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [#4](https://github.com/rainlanguage/raindex.governance/issues/4) `withdraw4` burned sub-precision vault value                                 | `withdraw5` floors the target before Raindex sees it                                                                                                                                |
| [#5](https://github.com/rainlanguage/raindex.governance/issues/5) pause NatSpec overstated                                                     | NatSpec narrowed; `rescue` stays usable while paused, pinned by a test                                                                                                              |
| Operators could send Raindex `tasks` into the inventory's order namespace                                                                      | non-admin callers with non-empty `tasks` revert `OperatorTasksForbidden`                                                                                                            |
| A sub-unit withdraw was a silent no-op that dropped `tasks`                                                                                    | reverts `ZeroWithdrawAmount`                                                                                                                                                        |
| A lossy deposit credited the vault less than the caller paid                                                                                   | the vault is credited exactly the rounded-up charge                                                                                                                                 |
| Unlimited standing allowance to Raindex                                                                                                        | exact allowance per deposit                                                                                                                                                         |
| [#21](https://github.com/rainlanguage/raindex.governance/issues/21) deploy script accepted the deploy key as admin, or any contract as raindex | the Raindex is always the released V7 (codehash checked), the deploy key cannot be admin, custom errors, fork-tested                                                                |
| [#24](https://github.com/rainlanguage/raindex.governance/issues/24) moving the pool was a manual runbook                                       | `script/MigrateInventory.sol` prints the admin transactions after it runs them on a fork and checks the end state; `test/MigrateInventory.t.sol` moves the live Base pool on a fork |

## Open

| Issue                                                               | Severity | Summary                                                                                                       |
| ------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------- |
| [#19](https://github.com/rainlanguage/raindex.governance/issues/19) | medium   | fee-on-transfer or short-delivering tokens can lock a vault                                                   |
| [#20](https://github.com/rainlanguage/raindex.governance/issues/20) | medium   | the last admin can renounce                                                                                   |
| [#22](https://github.com/rainlanguage/raindex.governance/issues/22) | medium   | deploy workflow has no branch or environment gate                                                             |
| [#23](https://github.com/rainlanguage/raindex.governance/issues/23) | low      | `withdraw5` forwards any inflow during the call to the caller                                                 |
| [#25](https://github.com/rainlanguage/raindex.governance/issues/25) | low      | no `IRaindexInventory` interface                                                                              |
| [#26](https://github.com/rainlanguage/raindex.governance/issues/26) | low      | each deploy network is configured in five places                                                              |
| [#27](https://github.com/rainlanguage/raindex.governance/issues/27) | low      | naming and test layout conventions                                                                            |
| [#28](https://github.com/rainlanguage/raindex.governance/issues/28) | low      | `RaindexInventory.t.sol` duplicates the test base                                                             |
| [#31](https://github.com/rainlanguage/raindex.governance/issues/31) | low      | fork tests run on the latest block and assert absolute balances                                               |
| [#32](https://github.com/rainlanguage/raindex.governance/issues/32) | low      | inventory-owned orders must not use vault 0: a vault-0 input pays into the wallet, and only `rescue` moves it |
| [#29](https://github.com/rainlanguage/raindex.governance/issues/29) | info     | no `AGENTS.md`                                                                                                |
| [#30](https://github.com/rainlanguage/raindex.governance/issues/30) | info     | gate logic has no test without a Base RPC                                                                     |
| [#9](https://github.com/rainlanguage/raindex.governance/issues/9)   | —        | `[package]` in `foundry.toml`                                                                                 |

Some findings go to the auditor through a private channel.

The fixes in this stack are not live until `RaindexInventory` is redeployed on
Raindex V7 and the pool is moved
([`docs/migrate-to-v7.md`](../docs/migrate-to-v7.md)).
