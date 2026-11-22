<div align="center">

# satchel

Session-locked player data, stacking inventory, equip slots and safe two-player trading for Roblox. It leaves out shops, crafting, item art and any purchase flow.

![License](https://img.shields.io/badge/LICENSE-MIT-blue?style=for-the-badge)  ![Language](https://img.shields.io/badge/LUAU-00A2FF?style=for-the-badge&logo=roblox&logoColor=white)  ![Tests](https://img.shields.io/badge/TESTS-89-brightgreen?style=for-the-badge)

Refer to [LICENSE](LICENSE) for the legal bits.

</div>

## What's in it

- **Session lock with a lease.** Each load claims the player's record with a lease through one `UpdateAsync`, so two servers can't both write the same profile. A lease that nobody refreshed (a crashed server) expires and can be taken over. A server that finds its lease gone stops saving and kicks the player instead of overwriting the new owner's data.
- **Retries and budget waits.** Loads retry with doubling waits (1, 2, 4, 8, 16 seconds by default). Before each DataStore call the store waits for request budget, for up to 10 seconds, so a busy server queues instead of throwing.
- **Schema migrations, and a read-only mode.** Saved data carries a schema number and is upgraded step by step on load. A record written by a newer version of the game loads read-only, so an old server can never write over data it doesn't understand.
- **Stacking inventory.** Adds fill part-full stacks before taking a new slot, and every change is all-or-nothing. A refused call leaves the bag exactly as it was.
- **Equip slots.** Items with a slot equip from the bag. Whatever was already worn goes back into the bag first, or the equip is refused.
- **Two-player trades.** Offers are references until commit. Any change to an offer clears both confirmations, and the items only move after both players have confirmed and the countdown has run out. The commit is worked out on copies of both bags and written back only if every step worked.
- **Server authority.** Clients send intent only. Every call is checked for type and range, rate limited per player and then checked against the game rules. A refused call is dropped and counted, and nothing is sent back about why.

```lua
-- src/shared/Config.luau
Items = table.freeze({
	apple = table.freeze({ name = "Apple", maxStack = 20, slot = nil, colour = { 200, 60, 60 } }),
	iron_helm = table.freeze({ name = "Iron Helm", maxStack = 1, slot = "Head", colour = { 150, 155, 165 } }),
}),
```

## 🏗️ Architecture

```
                     Player joins / leaves / autosave
                                   |
                                   v
 init.server.luau  --------->  Store  ---->  Lease (claim / refresh / release)
 (services, remotes)             |    ---->  Migrations (schema upgrades)
        |                        |
        |                        v
        |                   DataStore  (MemoryStore in Studio)
        |
        |  Request (RemoteFunction)        Sync (RemoteEvent)
        |  <---------------------------    --------------------------->
        v                                                            client
   Handlers  -- Validate, RateLimiter ---> Inventory (pure functions)
        |                                  Trade (two-player factory)
        v
   Sync snapshots to the players involved
```

- **init.server.luau** is the only server file that touches Players, DataStoreService and remotes. It builds the Store and Handlers with their dependencies and runs the autosave, trade tick and shutdown loops.
- **Data/Lease.luau** holds the pure claim, refresh and release transforms that run inside `UpdateAsync`.
- **Data/Migrations.luau** upgrades saved data one schema step at a time and flags records from the future as read-only.
- **Data/Store.luau** loads and saves sessions over a DataStore, with retries, budget waits and lease loss handling.
- **Data/MemoryStore.luau** is an in-memory stand-in with the same `UpdateAsync` contract, used in Studio.
- **Inventory/Inventory.luau** is the bag: add, remove, move, split, equip, unequip, plus the DataStore-safe encoding.
- **Trade/Trade.luau** is one trade between two players: offers, confirmations, countdown and the all-or-nothing commit.
- **Handlers.luau** validates and routes every client request, runs the trade lifecycle and decides who gets a Sync.
- **shared/Config.luau** is the one place to edit items, slots, limits and timings. **ConfigCheck.luau** refuses to start the server on a bad config. **RateLimiter.luau** and **Validate.luau** are the small shared helpers.
- **client/** builds the bag, equip slots and trade window in code. It never changes the bag itself and redraws from the next Sync.

## 🚀 Quick start

```
rokit install
rojo serve
```

Open `demo/satchel.rbxl` in Studio, connect the Rojo plugin and press Play. You should see a bag of 24 slots along the bottom with five apples in it. Drag a stack to another slot to move it, hold Shift and drag to split it in half, drag an item onto an equip slot to wear it, and press B to hide the bag. The Trade button opens a list of the other players. With two players in range, one sends a request, the other accepts, and both click items in their bags to put them on the table.

In Studio the server uses an in-memory store, so nothing is saved between sessions. To use the real DataStore, set the attribute `SatchelUseDataStore` to true on ServerStorage and turn on API access for the place.

## 🧪 Testing

```
lune run tests/run
```

89 tests, all passing:

- Rate limiter (4): a full bucket allows exactly its capacity, time refills it, it never overfills, and forgetting a key resets only that key.
- Validate (10): integers, strings, unit vectors and set membership, including NaN, infinity, floats, wrong types and out-of-range values.
- Config checks (9): the shipped config passes, and each rule (lease length, retries, close timeout, stack sizes, slots, starting items, offer slots) fails when broken and passes when fixed.
- Lease (10): new, taken, stolen and held outcomes, expiry, refresh, release, lost leases and no mutation of the stored record.
- Migrations (4): steps run in order, current records are unchanged, records from the future go read-only, and the input is never mutated.
- Store (10): fresh loads, two-server lockout, stealing an expired lease, load retries, persistent failure, budget waits, read-only sessions, double release, round trips and the encode hooks.
- Inventory (17): stacking, refusals that leave the bag untouched, remove, move, merge, swap, split, equip, unequip and the DataStore encoding.
- Trade (11): swaps, confirmations cleared by changes, commits cancelled when a bag changed or is full, a player leaving, offer limits, countdown timing and gifts.
- Handlers (12): argument checks, rate limiting, trade requests and range, request timeouts, a full trade with saves, players walking apart and quiet ticks.
- Memory store (2): copies on the way in and out, and the cancel-on-nil contract.

The Roblox-facing scripts (the entry scripts and the UI) can't run under Lune. They build with Rojo and are checked in Studio.

## ⚠️ Honest limits

- A trade writes two DataStore keys, and that isn't atomic. Each trade saves both players straight after the commit to keep the window short, but a server crash between the two saves can still lose or duplicate the traded items.
- In Studio the demo uses an in-memory store unless the `SatchelUseDataStore` attribute is set, so it proves the flow but not real DataStore behaviour such as throttling.
- There's no global trade log and no rollback tool. If a trade goes wrong, there is nothing here to undo it.
- The lease protects against two servers writing at once, not against a player's data being edited from outside the game.
- Item definitions live in the `Config.luau` table. There is no item catalogue, no art and no purchase flow.
- The UI is functional rather than finished: no gamepad support, no animation and a fixed layout.

## Licence

MIT.
