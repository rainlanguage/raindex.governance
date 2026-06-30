# raindex.governance

Ownership and access-control tooling for [Raindex](https://github.com/rainlanguage)
orders and vaults.

## `RaindexInventory`

A contract that owns a pool of capital held in Raindex vaults and lets more than
one authorised consumer draw on it — without any of them owning the orders or
vaults directly. One pool of capital, many consumers.

It separates two concerns behind two roles:

| Concern | Role | What it can do |
| --- | --- | --- |
| **Own & manage orders/vaults** | `DEFAULT_ADMIN_ROLE` | `addOrder4`, `removeOrder3`, `entask2`, role grants, `pause`, `rescue` |
| **Move inventory** | `OPERATOR_ROLE` | `deposit4`, `withdraw4` against the owned vaults |

Because the contract is the `msg.sender` to Raindex, it is the canonical owner of
every order and vault placed through it (Raindex forbids delegated order
management). The admin manages those orders/vaults *through* this contract using
the **exact same `IRaindexV6` signatures** it would call on Raindex directly, so
existing Raindex tooling works by pointing at this address. `Multicall` is
inherited, so a Raindex CLI `multicall([addOrder4, …])` lands here unchanged.

### Inventory flows to / from the caller

Operators move funds with the same `deposit4` / `withdraw4` signatures, and funds
always flow to / from the **caller**:

```
withdraw4:  Raindex vault → this contract → msg.sender
deposit4:   msg.sender → this contract → Raindex vault
```

The contract is therefore completely agnostic about *why* an operator needs the
funds — the operator's own logic handles whatever it settles against. Several
operators can share the same vaults: a draw on a vault that can't cover the
request reverts atomically (`InsufficientVaultLiquidity`), so concurrent draws
are safe — the loser's transaction simply reverts, never a short fill.

### Trust & safety

- **The trust boundary is `OPERATOR_ROLE`.** An operator can withdraw a vault's
  balance to itself, so the role is only ever granted to audited contracts and
  stays admin-grantable/revocable. Point `DEFAULT_ADMIN_ROLE` at a multisig (and,
  if desired, a timelock) for production.
- **`pause()`** is the kill switch: it fails `deposit4` / `withdraw4` closed while
  leaving order management open, so the admin can cancel orders during an
  incident.
- `nonReentrant` on every fund movement; `deposit4` self-heals the contract's
  Raindex allowance.

## Build & test

Foundry + [soldeer](https://soldeer.xyz) (solc 0.8.25, EVM Cancun).

```bash
soldeer install      # restore dependencies
forge build
forge test           # fork tests run against the live Raindex on Base
```

The tests fork Base mainnet and exercise every path against the real deployed
Raindex OrderBook — no mocks. Set the `base` RPC endpoint in `foundry.toml`.

## License

MIT
