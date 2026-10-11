# Admin-Mediated Trading and Building Display

## Context

The event auction has already ended and the production database contains the current teams, credit balances, inventories, auction results, auction settings, active trading listings, and trading history. This work must upgrade the existing system without resetting, replacing, or deleting that event data.

The existing trading portal lets teams buy directly from other teams at a fixed base price and restricts listings to shop components. The new workflow turns the portal into a public notice board. Teams advertise components they are willing to sell, negotiate outside the portal, and an admin records the agreed transaction.

## Goals

- Let teams publicly list both shop components and auction components they own.
- Let every team see which team is selling each component and the available quantity.
- Prevent teams from buying or transferring components through the team portal or team API.
- Let only an authenticated admin choose the buyer, quantity, and agreed price and complete a trade.
- Transfer inventory and game credits atomically and retain a trade history.
- Show a public, realtime display with `BUILDING STARTED`, `TRADING OPEN`, and all active listings.
- Preserve all existing event data during the database upgrade.

## Non-Goals

- No trading countdown or building countdown.
- No asking price on team listings.
- No team-side purchase request, buyer selection, or checkout flow.
- No auction reset, event reset, or regeneration of the completed auction.
- No automatic closing of trading while building is in progress.

## Phase Rules

Trading and building both become open when the auction status is `done`. The current event is already in that state, so both statuses appear open immediately after the upgrade. Trading remains open indefinitely. Building is represented only by the public `BUILDING STARTED` status; it has no controls or timer.

Before the auction is complete, teams may view their existing listing/history pages but cannot create or edit active sale listings. The public display reports that trading and building have not started.

## Team Trading Portal

The team Trading route contains four views:

1. **Public Listings** shows all active listings with seller team, component name, and available quantity. It contains no price, quantity-to-buy input, or purchase control.
2. **List Components** shows every shop or auction component in the team's inventory that is eligible to be listed. A team selects only a component and quantity.
3. **My Listings** lets the seller change the listed quantity or cancel an active listing.
4. **My Trades** keeps the existing completed-trade history and shows whether the team was the seller or buyer, the other team, component, quantity, agreed unit price, and total.

An active listing reserves its quantity while leaving the physical inventory row with the seller until an admin completes a trade. The sum of a team's active listings for an item cannot exceed its current inventory quantity.

Auction items use the public auction name and, where a sold mystery box has a revealed prize, the revealed description. Unsold or unrevealed mystery contents are never exposed by the trading feature.

## Admin Trading Portal

A new `Admin Trading` route is added to the admin navigation. It shows all active listings and completed trading history.

For an active listing, the admin selects:

- buyer team;
- quantity, limited by the listing and seller inventory;
- agreed unit price, which may be zero or greater.

The seller cannot be selected as the buyer. The action is disabled when inputs are invalid. On success, the admin view refreshes and the realtime public snapshot updates all team and display screens.

## Database Design

The existing `trading_listings` and `trading_history` tables remain the source of truth. Existing rows are preserved.

The shop-only foreign key on `trading_listings.item_id` and `trading_history.item_id` is removed because one foreign key cannot reference the union of shop and auction catalogs. Item validity is instead enforced in the database functions: an item can be listed only when it exists in either `shop_components` or `auction_items` and the seller owns it.

Existing non-null price columns remain for backward compatibility and data preservation. New team listings store a neutral value because teams do not set an asking price. The admin-supplied agreed price is recorded in `trading_history` when a transaction completes.

The public snapshot adds resolved listing fields needed by untrusted clients: component display name, seller name, available quantity, and whether the item came from the shop or auction catalog. It does not expose hidden mystery contents.

## Database Operations

### Team create listing

The operation:

1. requires the completed-auction state;
2. validates a positive whole quantity;
3. validates that the item exists in either catalog;
4. totals active reservations for the seller and item;
5. rejects quantities above unreserved inventory;
6. creates the active listing without accepting a team-supplied price.

### Team update listing

The operation verifies that the listing belongs to the authenticated team and remains active. A positive quantity updates the listing when the new total reservation remains within inventory. Cancellation changes the listing status to `cancelled`. Teams cannot edit another team's listing.

### Admin complete trade

The admin-only operation runs under the existing advisory transaction lock and:

1. loads and validates the active listing;
2. validates buyer, quantity, and non-negative agreed unit price;
3. rejects a seller buying from itself;
4. confirms the seller still owns enough inventory;
5. confirms the buyer has enough credits;
6. reduces or closes the listing;
7. debits the buyer and credits the seller;
8. transfers inventory from seller to buyer;
9. inserts the completed trade history row;
10. refreshes the public snapshot.

Any validation failure raises an error before changes are committed, so partial transfers cannot occur.

### Team purchase removal

The `trade_buy` action is removed from the team API dispatcher. The previous team-buy database function is disabled or removed from the executable function set so an older frontend cannot bypass the new workflow.

## Public Display

A new public route, `/#/trading-display`, uses the existing realtime `public_state` subscription. After the auction is complete it shows:

- a dominant `BUILDING STARTED` heading;
- a `TRADING OPEN` status;
- an automatically updating table or card grid of seller team, component, and quantity.

It contains no timer, price, buyer controls, or mutation actions. Before auction completion it shows a waiting state.

## Data Preservation and Upgrade Safety

The schema upgrade must not delete or reset teams, credits, inventory, orders, auction history, auction configuration, active listings, or trading history. It must not call reset functions or change the completed auction status.

Schema changes are idempotent. Constraint removal is performed by resolving the existing foreign-key constraints by table/column rather than assuming generated constraint names. New functions replace existing definitions without changing stored event rows. Existing listing prices and completed history remain intact.

## Error Handling

User-facing errors cover closed trading, invalid quantities, insufficient unreserved seller inventory, insufficient buyer credits, inactive listings, missing teams/items, self-trading, and invalid prices. The UI refreshes after an error so stale listings do not remain actionable.

## Testing and Verification

Automated tests cover:

- public listing visibility without team purchase controls;
- listing both shop and auction inventory;
- reservation limits across multiple listings;
- seller-only listing edits and cancellation;
- absence of `trade_buy` from the team API;
- admin-only transfer validation;
- atomic inventory and credit movement;
- partial and complete listing fulfillment;
- public `BUILDING STARTED` and `TRADING OPEN` state after auction completion;
- non-destructive, idempotent schema upgrade behavior.

Verification includes the full test suite, production frontend build, scoped lint, schema review, and read-only checks of current production row counts/state before any live migration. Live migration and deployment are separate explicit actions and must not reset the current event.
