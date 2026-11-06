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

## Fixed before the audit

| Finding                                                                                                        | Fix                                                                      |
| -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [#4](https://github.com/rainlanguage/raindex.governance/issues/4) `withdraw4` burned sub-precision vault value | `withdraw4` floors the target before Raindex sees it                     |
| [#5](https://github.com/rainlanguage/raindex.governance/issues/5) pause NatSpec overstated                     | NatSpec narrowed; `rescue` stays usable while paused, pinned by a test   |
| Operators could send Raindex `tasks` into the inventory's order namespace                                      | non-admin callers with non-empty `tasks` revert `OperatorTasksForbidden` |
| A sub-unit withdraw was a silent no-op that dropped `tasks`                                                    | reverts `ZeroWithdrawAmount`                                             |
| A lossy deposit credited the vault less than the caller paid                                                   | the vault is credited exactly the rounded-up charge                      |
| Unlimited standing allowance to Raindex                                                                        | exact allowance per deposit                                              |

## Open

| Issue                                                               | Severity | Summary                                                         |
| ------------------------------------------------------------------- | -------- | --------------------------------------------------------------- |
| [#19](https://github.com/rainlanguage/raindex.governance/issues/19) | medium   | fee-on-transfer or short-delivering tokens can lock a vault     |
| [#20](https://github.com/rainlanguage/raindex.governance/issues/20) | medium   | the last admin can renounce                                     |
| [#21](https://github.com/rainlanguage/raindex.governance/issues/21) | medium   | deploy script inputs are not validated                          |
| [#22](https://github.com/rainlanguage/raindex.governance/issues/22) | medium   | deploy workflow has no branch or environment gate               |
| [#24](https://github.com/rainlanguage/raindex.governance/issues/24) | medium   | moving the live pool to a new inventory is a manual runbook     |
| [#23](https://github.com/rainlanguage/raindex.governance/issues/23) | low      | `withdraw4` forwards any inflow during the call to the caller   |
| [#25](https://github.com/rainlanguage/raindex.governance/issues/25) | low      | no `IRaindexInventory` interface                                |
| [#26](https://github.com/rainlanguage/raindex.governance/issues/26) | low      | each deploy network is configured in five places                |
| [#27](https://github.com/rainlanguage/raindex.governance/issues/27) | low      | naming and test layout conventions                              |
| [#28](https://github.com/rainlanguage/raindex.governance/issues/28) | low      | `RaindexInventory.t.sol` duplicates the test base               |
| [#31](https://github.com/rainlanguage/raindex.governance/issues/31) | low      | fork tests run on the latest block and assert absolute balances |
| [#32](https://github.com/rainlanguage/raindex.governance/issues/32) | low      | vaultless orders would make the wallet balance order capital    |
| [#29](https://github.com/rainlanguage/raindex.governance/issues/29) | info     | no `AGENTS.md`                                                  |
| [#30](https://github.com/rainlanguage/raindex.governance/issues/30) | info     | gate logic has no test without a Base RPC                       |
| [#9](https://github.com/rainlanguage/raindex.governance/issues/9)   | —        | `[package]` in `foundry.toml`                                   |

Two further findings rated high by the audit skill's deploy-path rules are
shared with the auditor privately, as the skill's disclosure rule requires.

The fixes in this stack are not live until `RaindexInventory` is redeployed and
the pool is moved
([#24](https://github.com/rainlanguage/raindex.governance/issues/24)).
