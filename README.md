# raindex.governance

Ownership and access-control tooling for
[Raindex](https://github.com/rainlanguage) orders and vaults.

## `RaindexInventory`

A contract that owns a pool of capital held in Raindex vaults and lets more than
one authorised consumer draw on it — without any of them owning the orders or
vaults directly. One pool of capital, many consumers.

It separates two concerns behind two roles:

| Concern                        | Role                 | What it can do                                                                                                  |
| ------------------------------ | -------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Own & manage orders/vaults** | `DEFAULT_ADMIN_ROLE` | `addOrder5`, `removeOrder4`, `entask3`, role grants, `pause`, `rescue`, and `deposit5`/`withdraw5` with `tasks` |
| **Move inventory**             | `OPERATOR_ROLE`      | `deposit5`, `withdraw5` against the owned vaults, with empty `tasks` only                                       |

Because the contract is the `msg.sender` to Raindex, it is the canonical owner
of every order and vault placed through it (Raindex forbids delegated order
management). The admin manages those orders/vaults _through_ this contract using
the **exact same `IRaindexV7` signatures** it would call on Raindex directly, so
existing Raindex tooling works by pointing at this address. `Multicall` is
inherited, so a Raindex CLI `multicall([addOrder5, …])` lands here unchanged.

### Inventory flows to / from the caller

Operators move funds with the same `deposit5` / `withdraw5` signatures, and
funds always flow to / from the **caller**:

```
withdraw5:  Raindex vault → this contract → msg.sender
deposit5:   msg.sender → this contract → Raindex vault
```

The contract is therefore completely agnostic about _why_ an operator needs the
funds — the operator's own logic handles whatever it settles against. Several
operators can share the same vaults: a draw on a vault that can't cover the
request reverts atomically (`InsufficientVaultLiquidity`), so concurrent draws
are safe — the loser's transaction simply reverts, never a short fill.

### Trust & safety

- **The trust boundary is `OPERATOR_ROLE`.** An operator can withdraw a vault's
  balance to itself, so the role is only ever granted to audited contracts and
  stays admin-grantable/revocable. Point `DEFAULT_ADMIN_ROLE` at a multisig
  (and, if desired, a timelock) for production.
- **`pause()`** is the kill switch: `deposit5` / `withdraw5` revert for the
  admin and operators. It does not touch Raindex: live orders owned by the
  inventory keep clearing against its vaults, so incident response must also
  `removeOrder4` them. Order management stays open for that, and `rescue` stays
  available for stray balances.
- `nonReentrant` on `deposit5` / `withdraw5`; `deposit5` approves Raindex for
  exactly the amount it deposits, so no standing allowance is left.

## Build & test

Foundry + [soldeer](https://soldeer.xyz) (solc 0.8.25, EVM Cancun).

```bash
forge soldeer install   # restore dependencies
forge build
forge test           # fork tests run against the live Raindex V7 on Base
```

The tests fork Base mainnet and exercise every path against the real deployed
Raindex V7 (`0x91b95120D085Aa99C05167f3767eB63460c1dCaC`, raindex.deploy
`sol-v0.1.17`; a test pins its codehash); a few forwarding tests mock single
Raindex responses. Export `BASE_RPC_URL` for the `base` RPC endpoint.

## Deploy & migrate

`script/Deploy.sol` (the `Deploy RaindexInventory` workflow) deploys a fresh
inventory on the released Raindex V7. It takes only the network and the admin,
and refuses a chain without the released V7. To move a live pool from a V6
inventory, follow [`docs/migrate-to-v7.md`](./docs/migrate-to-v7.md).

## License

[LicenseRef-DCL-1.0](./LICENSES/LicenseRef-DCL-1.0.txt) — the DecentraLicense,
as used across the Rain language repositories. This repo is
[REUSE](https://reuse.software) compliant.
