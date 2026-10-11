# Admin-Mediated Trading and Building Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace direct team-to-team purchasing with quantity-only public listings and atomic admin-mediated transfers, while showing that trading and building are both open after the auction and preserving every existing team, inventory item, auction result, listing, and trade.

**Architecture:** Keep the existing React/Vite client, Vercel API function, and Supabase RPC boundary. Extend the existing trading tables and RPCs in place, add pure presentation helpers for catalog/phase rules, expose one admin trading screen and one public trading/building display, and remove the team purchase action from both UI and API authorization.

**Tech Stack:** React 19, Vite 8, Node test runner, Vercel serverless functions, Supabase/PostgreSQL PL/pgSQL, Supabase Realtime.

**Spec:** `docs/superpowers/specs/2026-10-11-admin-mediated-trading-design.md`

## Global Constraints

- Treat `supabase/schema.sql` as a repeatable in-place upgrade: no reset action, table recreation, blanket delete, or seed statement may overwrite live auction/team/trading state. Existing reset RPC definitions may remain, but the upgrade path must never invoke them.
- Preserve current rows in `teams`, `inventory`, `orders`, `auction_state`, `auction_history`, `trading_listings`, and `trading_history`.
- Keep `trading_listings.price` and `trading_history.price` non-null for compatibility; new quantity-only listings store `0`, and completed trades store the admin-entered final unit price.
- An item is tradeable only when its ID exists in either `shop_components` or `auction_items` and the seller owns enough unreserved inventory.
- Mystery-box contents remain hidden until that auction item has a sold history row; public listing/catalog payloads must never reveal unsold mystery contents.
- Team clients may create, update, and cancel their own listings, but may never select a buyer, set a price, or complete a transfer.
- Only the authenticated admin RPC may complete a trade. Inventory, credits, listing quantity/status, and history must change in the same transaction under the existing advisory lock.
- Trading and building have no countdown or close action. Both are considered started whenever `auction_state.status = 'done'`.
- Keep unrelated dirty workspace changes intact and stage only the files named by each task.

## Review Focus

Every class below must receive an explicit test in the task that introduces the behavior:

1. **Malformed numeric input:** null, zero, negative, fractional, NaN-like, and excessive quantity/price values are rejected or normalized exactly as specified.
2. **Authorization and ownership:** teams cannot buy or alter another team's listing; admin-only completion cannot be reached through the team API.
3. **Concurrent/stale state:** inactive listings, quantities larger than the live listing, or sellers whose inventory changed are rejected without partial credit/inventory changes.
4. **Catalog privacy and compatibility:** both shop and auction items resolve correctly, unknown IDs fail, existing price columns/rows survive, and unrevealed mystery-box contents stay hidden.
5. **Phase and empty-state behavior:** pre-auction trading stays closed; auction-done shows Trading Open and Building Started together; empty listings/history render safely.

---

### Task 1: Add pure trading catalog and phase helpers

**Files:**
- Create: `all-in-put/aio/client/src/trading-ui.js`
- Create: `all-in-put/aio/client/test/trading-ui.test.mjs`

**Interfaces:**
- `buildTradingCatalog(publicState)` returns a `Map` keyed by item ID. Each value has `{ id, name, source, revealed }`, where `source` is `'shop'` or `'auction'`.
- `getTradeableInventory(publicState, me)` returns owned catalog entries with `{ id, name, source, revealed, owned, committed, available }`, excluding entries with no available quantity.
- `getPostAuctionPhase(publicState)` returns `{ tradingOpen, buildingStarted }`; both flags are true only when `publicState.auction.status === 'done'`.
- Auction display names use the public auction item `name`; a non-empty public `reveal` may be appended only after Supabase has made it public.

- [ ] Write `test/trading-ui.test.mjs` covering merged shop/auction catalogs, reserved quantities, unknown inventory IDs, mystery reveal privacy, empty state, and pre/post-auction phase flags.
- [ ] Run `npm test -- test/trading-ui.test.mjs` from `all-in-put/aio/client` and confirm the import/helper assertions fail.
- [ ] Implement the three helpers with no React or network dependencies.
- [ ] Run `npm test -- test/trading-ui.test.mjs` and confirm all helper tests pass.
- [ ] Run `npm test` to catch interactions with existing shop-cap and auction tests.
- [ ] Commit only these two files with `git commit -m "test: define trading catalog and phase rules"`.

### Task 2: Make the database upgrade catalog-compatible and non-destructive

**Files:**
- Modify: `all-in-put/aio/client/supabase/schema.sql`
- Create: `all-in-put/aio/client/test/trading-schema.test.mjs`

**Interfaces:**
- Add `_trade_item_exists(p_item_id text) returns boolean` as a stable SQL helper covering `shop_components` and `auction_items`.
- Add `_trade_item_name(p_item_id text) returns text` and `_trade_item_source(p_item_id text) returns text` for resolved payloads.
- Replace the shop-only foreign keys on `trading_listings.item_id` and `trading_history.item_id` using a guarded `DO` block that drops only foreign-key constraints on those exact columns; do not drop tables, rows, primary keys, or indexes.
- Leave the item IDs as text and preserve the current non-null price columns.
- Replace the current `delete from auction_items where id = 'a13'` retirement with a non-destructive retirement (`qty = 0` and queue removal). Keep the catalog row so previously won inventory, listings, and history can still resolve the old auction LED item.

- [ ] Add source-contract tests that assert the new migration block targets only the two `item_id` foreign keys, contains no trading-table drop/truncate, defines the catalog helpers, removes the destructive `a13` delete, and does not introduce destructive updates to live auction/team state.
- [ ] Include a compatibility fixture in the test showing that legacy listing/history JSON with non-zero `price` remains accepted by presentation code.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and confirm the new assertions fail.
- [ ] Add the guarded constraint migration and helper functions before the trading RPCs.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and then `npm test`.
- [ ] Commit only the schema and new test with `git commit -m "db: allow shop and auction trade items"`.

### Task 3: Replace team buying with listing create, update, and cancel RPCs

**Files:**
- Modify: `all-in-put/aio/client/supabase/schema.sql`
- Modify: `all-in-put/aio/client/api/game.js`
- Modify: `all-in-put/aio/client/test/trading-schema.test.mjs`

**Interfaces:**
- `_trade_sell(p_team bigint, p_item_id text, p_qty numeric) returns void` validates an item from either catalog, validates integer quantity `1..100000`, checks owned minus active committed quantity, and inserts `price = 0`.
- `_trade_update(p_team bigint, p_listing_id numeric, p_qty numeric) returns void` updates only an active listing owned by `p_team`; the requested total listing quantity must fit current owned quantity after excluding the listing's prior reservation.
- `_trade_cancel(p_team bigint, p_listing_id numeric) returns void` remains owner-only and active-only.
- `game_team` supports `trade_sell`, `trade_update`, and `trade_cancel`; it has no `trade_buy` branch.
- `TEAM_ACTIONS` maps `trade/update` to `trade_update` and contains no `trade/buy` key.

- [ ] Extend schema/API contract tests for auction-item listing, unknown IDs, malformed quantities, over-reservation, update ownership, inactive listing update/cancel, and absence of every team-buy dispatch path.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and confirm failures identify the old shop-only/direct-buy behavior.
- [ ] Update `_trade_sell`, add `_trade_update`, remove `_trade_buy`, and update `game_team` dispatch.
- [ ] Update the Vercel team action allow-list.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and `npm test`.
- [ ] Commit these files with `git commit -m "feat: make team trading listing-only"`.

### Task 4: Add atomic admin trade completion and admin state

**Files:**
- Modify: `all-in-put/aio/client/supabase/schema.sql`
- Modify: `all-in-put/aio/client/test/trading-schema.test.mjs`

**Interfaces:**
- `_trade_admin_complete(p_listing_id numeric, p_buyer_id bigint, p_qty numeric, p_price numeric) returns void` performs the complete transfer.
- `game_admin` action `trade-complete` accepts `{ listingId, buyerId, qty, price }` and calls the helper while holding advisory lock `4242`.
- Valid quantity is an integer `1..100000`; valid unit price is an integer `0..1000000000`.
- Reject missing/inactive listing, seller as buyer, missing buyer, quantity above the listing, insufficient current seller inventory, or insufficient buyer credits.
- On success: decrement seller inventory, increment buyer inventory, move `qty * price` credits, decrement/close the listing, and insert one `trading_history` row with unit price and total.
- `admin_state()` adds top-level `tradingListings` and `tradingHistory` arrays with resolved seller/buyer/item names and item source; active listings are ordered oldest first for deterministic processing.

- [ ] Extend source-contract tests for every validation class (including fractional quantities/prices), atomic mutation set, partial versus sold-out listing status, zero-price transfers, history insertion, and admin-state payload names.
- [ ] Add a test asserting the admin completion branch exists only in `game_admin`, not `game_team` or `TEAM_ACTIONS`.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and confirm the tests fail.
- [ ] Implement `_trade_admin_complete`, the `game_admin` branch, and the admin-state projections.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and `npm test`.
- [ ] Commit the schema/test changes with `git commit -m "feat: add atomic admin trade settlement"`.

### Task 5: Publish safe listing details and team trade history

**Files:**
- Modify: `all-in-put/aio/client/supabase/schema.sql`
- Modify: `all-in-put/aio/client/test/trading-schema.test.mjs`

**Interfaces:**
- `refresh_public_state()` emits each active listing as `{ id, teamId, teamName, itemId, itemName, itemSource, itemReveal, qty, createdAt }`.
- `itemReveal` is null unless the auction item has a sold `auction_history` row; shop items never need a reveal field.
- `game_me()` retains legacy fields but adds resolved `itemName` and `itemSource` to `listings` and `trades`.
- Public active listings expose no actionable buyer control and no meaningful asking price; retaining a legacy `price: 0` field is allowed only if required for old clients.

- [ ] Add tests for shop names, auction names, sold mystery reveals, unsold mystery redaction, chronological active listings, empty arrays, and legacy history compatibility.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and confirm the payload assertions fail.
- [ ] Update `refresh_public_state()` and `game_me()` using the catalog helpers from Task 2.
- [ ] Run `npm test -- test/trading-schema.test.mjs` and `npm test`.
- [ ] Commit the schema/test changes with `git commit -m "feat: publish safe trading details"`.

### Task 6: Replace the team marketplace with a listing portal

**Files:**
- Modify: `all-in-put/aio/client/src/App.jsx`
- Modify: `all-in-put/aio/client/test/trading-ui.test.mjs`

**Interfaces:**
- `TeamTrading` tabs become `Public Listings`, `List Components`, `My Listings`, and `My Trades`.
- Public Listings show component name/source, seller, available quantity, and listed time only; there is no price input, buy button, or purchase handler.
- List Components uses `getTradeableInventory(pub, me)` and posts `{ itemId, qty }` to `trade/sell`.
- Active My Listings support quantity editing through `trade/update` and cancellation through `trade/cancel`; completed/cancelled rows are read-only.
- My Trades displays seller/buyer direction, counterparty, quantity, final unit price, and total from completed admin settlements.
- Before auction completion, mutation tabs are disabled and a closed message is shown; read-only personal history remains safe.

- [ ] Extend UI helper/contract tests to assert all four tabs and endpoint names, auction items are eligible, empty states render, and no `trade/buy`, `handleBuy`, asking-price copy, or team purchase button remains.
- [ ] Run `npm test -- test/trading-ui.test.mjs` and confirm the old marketplace fails the assertions.
- [ ] Refactor `TeamTrading`, importing the Task 1 helpers and keeping existing toast/error patterns.
- [ ] Run `npm test -- test/trading-ui.test.mjs`, `npm test`, and `npm run lint`.
- [ ] Commit `App.jsx` and the updated test with `git commit -m "feat: turn team trading into a listing portal"`.

### Task 7: Add the admin trading settlement screen

**Files:**
- Modify: `all-in-put/aio/client/src/App.jsx`
- Create: `all-in-put/aio/client/test/admin-trading-ui.test.mjs`

**Interfaces:**
- Add `AdminTrading({ adm, api, load, showToast, tok, role, logout })`.
- Add authenticated route `#/admin-trading` and an admin navigation link labelled `Trading Admin`.
- For each active listing, show seller, resolved item, available quantity, buyer selector excluding the seller, quantity input, final unit-price input, computed total, and `Complete Trade`.
- Submission posts `{ listingId, buyerId, qty, price }` to `admin/trade-complete`, waits for success, reloads admin state, and clears only that row's draft.
- Show a recent completed-trades table and useful empty states. Disable submission for missing buyer, out-of-range quantity, invalid price, or client-known insufficient credits while still relying on server validation.

- [ ] Add contract tests for the route/nav, payload keys, seller exclusion, zero-price acceptance, client validation, empty listings/history, and removal of a row only after server success.
- [ ] Run `npm test -- test/admin-trading-ui.test.mjs` and confirm the new component/route assertions fail.
- [ ] Implement `AdminTrading`, add the admin navigation entry, authorize the route in the route guard, and render it in `App`.
- [ ] Run `npm test -- test/admin-trading-ui.test.mjs`, `npm test`, and `npm run lint`.
- [ ] Commit `App.jsx` and the test with `git commit -m "feat: add admin trading settlement screen"`.

### Task 8: Add the public trading and building status display

**Files:**
- Modify: `all-in-put/aio/client/src/App.jsx`
- Create: `all-in-put/aio/client/test/trading-display.test.mjs`

**Interfaces:**
- Add public route `#/trading-display`, accessible without login and exempt from authenticated route redirects.
- Add `TradingDisplay({ pub })` using `getPostAuctionPhase(pub)`.
- Before the auction is done, show that trading/building have not started. After it is done, show `TRADING OPEN` and `BUILDING STARTED` simultaneously with no countdown, deadline, pause, stop, or admin control.
- Display live public seller listings with item, seller, quantity, and source only; include a clear empty-listings message.
- Add a public display link alongside the existing shop/auction display links.

- [ ] Add tests for public routing, both post-auction labels at once, no timer/control language, pre-auction state, live listing fields, and empty state.
- [ ] Run `npm test -- test/trading-display.test.mjs` and confirm the display assertions fail.
- [ ] Implement `TradingDisplay`, route access, and the display navigation link.
- [ ] Run `npm test -- test/trading-display.test.mjs`, `npm test`, `npm run lint`, and `npm run build`.
- [ ] Commit `App.jsx` and the test with `git commit -m "feat: add trading and building display"`.

### Task 9: Verify the full workflow and prepare the live-safe rollout

**Files:**
- Modify only if verification exposes a defect in files already named above.
- Create: `all-in-put/aio/client/docs/TRADING-ROLLOUT.md`

**Interfaces:**
- The rollout document separates read-only preflight, schema application, application deployment, smoke testing, and rollback/incident steps.
- Preflight SQL records counts and key state from `teams`, `inventory`, `orders`, `auction_state`, `auction_history`, `trading_listings`, and `trading_history`; it performs no writes.
- Post-migration checks compare those counts/state and verify existing auction status remains `done`.
- Deployment order is schema first, then Vercel application, because the new UI depends on the new RPC payload/actions.
- The document explicitly says not to run `reset-shop`, `reset-all`, `auction-reset`, truncate tables, or rerun destructive ad-hoc seed SQL.

- [ ] Add a manual test matrix covering: team creates shop listing; team creates auction/mystery listing; another team can only view it; owner updates/cancels; admin performs partial and final settlements; invalid/stale settlement changes nothing; credits/inventory/history reconcile; Trading Open and Building Started remain visible together.
- [ ] Run `npm test` from `all-in-put/aio/client` and save the passing count in the rollout document.
- [ ] Run `npm run lint` and resolve only findings caused by this feature.
- [ ] Run `npm run build` and record the successful command in the rollout document.
- [ ] Run `rg -n "trade/buy|handleBuy|Buy Components|asking price|countdown|building timer" all-in-put/aio/client/src all-in-put/aio/client/api all-in-put/aio/client/supabase` and confirm no forbidden team-buy or building-timer path remains (document any harmless historical text explicitly).
- [ ] Review `git diff --check` and `git status --short`; verify no live data or unrelated dirty work was overwritten.
- [ ] Commit the rollout document and any verification-only fixes with `git commit -m "docs: add safe trading rollout checklist"`.

### Task 10: Independent review against the approved specification

**Files:**
- Review: `docs/superpowers/specs/2026-10-11-admin-mediated-trading-design.md`
- Review: all files changed in Tasks 1-9

- [ ] Use the required review workflow to compare every spec requirement and Review Focus class to code and tests.
- [ ] Confirm direct team buying is impossible at UI, API allow-list, and `game_team` RPC levels.
- [ ] Confirm the database change is repeatable and preserves all current event state.
- [ ] Confirm mystery contents cannot leak through public listings before a sold auction history exists.
- [ ] Confirm admin settlement is atomic under the advisory lock and handles partial/final quantities correctly.
- [ ] Confirm both post-auction phases show concurrently without timers or close controls.
- [ ] Run `npm test`, `npm run lint`, and `npm run build` one final time.
- [ ] If review changes are needed, add focused regression tests first and commit fixes separately with `git commit -m "fix: address trading workflow review"`.
