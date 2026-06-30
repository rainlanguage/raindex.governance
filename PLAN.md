# RaindexInventory — design notes

## Problem

A capital pool lives in Raindex vaults and backs Raindex limit orders. We want
*other* on-chain consumers to draw on that same pool — borrow a token out to
fund something, return the proceeds — so one pool of capital is shared across
several venues instead of fragmenting it. The consumers must not each become the
owner of the Raindex orders/vaults (Raindex makes the `msg.sender` the canonical,
non-delegable owner, and we don't want N owners of one order book position).

## Design

One contract, `RaindexInventory`, is the single owner of the orders/vaults.
Everything else is access control:

- **`DEFAULT_ADMIN_ROLE`** owns and manages the orders/vaults. It calls the
  drop-in `IRaindexV6` management methods (`addOrder4`, `removeOrder3`,
  `entask2`, …) *through* the inventory, so existing Raindex tooling — including
  the CLI's `multicall([...])` output — works by pointing at the inventory
  address.
- **`OPERATOR_ROLE`** moves inventory. Operators call the same `deposit4` /
  `withdraw4` signatures; funds flow **to / from the caller**:

  ```
  withdraw4:  vault → inventory → msg.sender
  deposit4:   msg.sender → inventory → vault
  ```

The inventory knows nothing about *why* an operator wants the funds. Each
consumer is a separate contract that holds `OPERATOR_ROLE` and contains all of
its own venue-specific logic (how it settles, where the borrowed token must end
up, where proceeds come from). Keeping that out of the inventory is what makes
this generic, reusable Raindex tooling rather than a one-venue integration.

### Why funds flow to/from the caller (and not a configured recipient)

Raindex `withdraw` always pays out to the vault owner — i.e. the inventory
contract — and has no recipient argument. So *something* has to forward the
token the last hop. Forwarding to `msg.sender` is the most general choice: the
operator receives exactly what it withdrew and does whatever its venue needs.
A consumer that needs the token somewhere else (a settlement EOA, a pool
manager) does that hop itself. This keeps the dangerous primitive — moving funds
out of custody — pinned to "to the caller, who is a vetted role-holder," never
to an arbitrary address chosen per-call.

### Shared vaults & concurrency

Multiple operators can be pointed at the same vaults — that's the point, maximal
capital efficiency. If two operators race to draw a vault that can't cover both
in one block, the second `withdraw4` measures a short balance delta and reverts
`InsufficientVaultLiquidity`. Atomicity makes this safe: a consumer that draws
and settles in one transaction either gets the full amount or the whole thing
reverts and it retries. No partial fills, no over-draw.

## Trust & safety

- **`OPERATOR_ROLE` is the trust boundary.** A holder can withdraw a vault's
  balance to itself, so it is only ever granted to audited contracts and is
  admin-grantable/revocable. Production should point `DEFAULT_ADMIN_ROLE` at a
  multisig, optionally behind a timelock.
- **`pause()`** fails `deposit4` / `withdraw4` closed while leaving order
  management open, so the admin can cancel orders during an incident even while
  inventory movement is frozen.
- `nonReentrant` guards every fund movement; `deposit4` self-heals the
  inventory→Raindex allowance. The guard is Multicall-safe because batched calls
  execute sequentially (each acquires/releases), not nested.

## Deploying onto existing positions (migration)

Moving an existing, already-owned Raindex position under a `RaindexInventory`:

1. Deploy `RaindexInventory(admin, raindex)`.
2. Re-create the orders under the inventory (it must be the `msg.sender`/owner),
   and move the vault balances across (withdraw from the old owner, deposit
   through the inventory). Do this in a quiet window — orders are briefly absent.
3. `grantRole(OPERATOR_ROLE, consumer)` for each consumer contract.
4. Repoint each consumer at the inventory address.

This is a deliberate, supervised migration, not a hot swap.

## Status

`RaindexInventory` + fork tests (against the live Base Raindex, no mocks) are in
this repo and green. Consumers live in their own repositories and depend on this
one; nothing consumer-specific belongs here.
