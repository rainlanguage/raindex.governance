# RaindexInventory — design notes

## Problem

A capital pool lives in Raindex vaults and backs Raindex limit orders. We want
_other_ on-chain consumers to draw on that same pool — borrow a token out to
fund something, return the proceeds — so one pool of capital is shared across
several venues instead of fragmenting it. The consumers must not each become the
owner of the Raindex orders/vaults (Raindex makes the `msg.sender` the
canonical, non-delegable owner, and we don't want N owners of one order book
position).

## Design

One contract, `RaindexInventory`, is the single owner of the orders/vaults.
Everything else is access control:

- **`DEFAULT_ADMIN_ROLE`** owns and manages the orders/vaults. It calls the
  drop-in `IRaindexV7` management methods (`addOrder5`, `removeOrder4`,
  `entask3`, …) _through_ the inventory, so existing Raindex tooling — including
  the CLI's `multicall([...])` output — works by pointing at the inventory
  address.
- **`OPERATOR_ROLE`** moves inventory. Operators call the same `deposit5` /
  `withdraw5` signatures; funds flow **to / from the caller**:

  ```
  withdraw5:  vault → inventory → msg.sender
  deposit5:   msg.sender → inventory → vault
  ```

The inventory knows nothing about _why_ an operator wants the funds. Each
consumer is a separate contract that holds `OPERATOR_ROLE` and contains all of
its own venue-specific logic (how it settles, where the borrowed token must end
up, where proceeds come from). Keeping that out of the inventory is what makes
this generic, reusable Raindex tooling rather than a one-venue integration.

### Why funds flow to/from the caller (and not a configured recipient)

Raindex `withdraw` always pays out to the vault owner — i.e. the inventory
contract — and has no recipient argument. So _something_ has to forward the
token the last hop. Forwarding to `msg.sender` is the most general choice: the
operator receives exactly what it withdrew and does whatever its venue needs. A
consumer that needs the token somewhere else (a settlement EOA, a pool manager)
does that hop itself. This keeps the dangerous primitive — moving funds out of
custody — pinned to "to the caller, who is a vetted role-holder," never to an
arbitrary address chosen per-call.

### Shared vaults & concurrency

Multiple operators can be pointed at the same vaults — that's the point, maximal
capital efficiency. If two operators race to draw a vault that can't cover both
in one block, the second `withdraw5` measures a short balance delta and reverts
`InsufficientVaultLiquidity`. Atomicity makes this safe: a consumer that draws
and settles in one transaction either gets the full amount or the whole thing
reverts and it retries. No partial fills, no over-draw.

## Trust & safety

- **`OPERATOR_ROLE` is the trust boundary.** A holder can withdraw a vault's
  balance to itself, so it is only ever granted to audited contracts and is
  admin-grantable/revocable. Production should point `DEFAULT_ADMIN_ROLE` at a
  multisig, optionally behind a timelock.
- **`pause()`** makes `deposit5` / `withdraw5` revert while leaving order
  management open. Live orders keep clearing on Raindex, so the admin must also
  cancel them during an incident. `rescue` is not pause-gated.
- `nonReentrant` guards `deposit5` / `withdraw5`; `deposit5` approves exactly
  the amount it deposits to Raindex. The guard is Multicall-safe because batched
  calls execute sequentially (each acquires/releases), not nested.

## Deploying onto existing positions (migration)

Moving an existing, already-owned Raindex position under a `RaindexInventory`:

1. Deploy `RaindexInventory(admin, RAINDEX_V7)` with `script/Deploy.sol`.
2. Re-create the orders under the inventory (it must be the `msg.sender`/owner),
   and move the vault balances across (withdraw from the old owner, deposit
   through the inventory). Orders are rebuilt for V7 from their source, never
   replayed from V6 calldata: V7 signed context is `SignedContextV2`.
3. `grantRole(OPERATOR_ROLE, consumer)` for each consumer contract.
4. Repoint each consumer at the inventory address.

This is a deliberate, supervised migration, not a hot swap. For a move from a V6
`RaindexInventory`, `script/MigrateInventory.sol` builds steps 2 and 3 as admin
transactions and checks the end state on a fork first. The runbook is
[`docs/migrate-to-v7.md`](./docs/migrate-to-v7.md).

## Status

`RaindexInventory` + fork tests (against the live Base Raindex V7; a few
forwarding tests mock single responses) are in this repo and green. Consumers
live in their own repositories and depend on this one; nothing consumer-specific
belongs here.
