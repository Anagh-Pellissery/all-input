import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { buildTradingCatalog } from '../src/trading-ui.js';

const schema = await readFile(new URL('../supabase/schema.sql', import.meta.url), 'utf8');
const api = await readFile(new URL('../api/game.js', import.meta.url), 'utf8');
const seedUpgrade = schema.split('-- ---------------------------------------------------------------- seed data')[1] || '';

const sqlFunction = name => schema.match(
  new RegExp(`create or replace function ${name}\\([^]*?\\$\\$;`, 'i'),
)?.[0] || '';

test('trade catalog helpers resolve both shop and auction item tables', () => {
  assert.match(schema, /create or replace function _trade_item_exists\(p_item_id text\) returns boolean/i);
  assert.match(schema, /_trade_item_exists[\s\S]*?from shop_components[\s\S]*?from auction_items/i);
  assert.match(schema, /create or replace function _trade_item_name\(p_item_id text\) returns text/i);
  assert.match(schema, /create or replace function _trade_item_source\(p_item_id text\) returns text/i);
});

test('upgrade drops only item foreign keys from the two trading tables', () => {
  assert.match(schema, /pg_constraint/i);
  assert.match(schema, /trading_listings/i);
  assert.match(schema, /trading_history/i);
  assert.match(schema, /attname\s*=\s*'item_id'/i);
  assert.match(schema, /contype\s*=\s*'f'/i);
  assert.doesNotMatch(schema, /drop\s+table\s+(?:if\s+exists\s+)?trading_(?:listings|history)/i);
  assert.doesNotMatch(schema, /truncate\s+(?:table\s+)?trading_(?:listings|history)/i);
});

test('upgrade retires the old auction LED without deleting its saved references', () => {
  assert.match(seedUpgrade, /update\s+auction_items\s+set\s+qty\s*=\s*0\s+where\s+id\s*=\s*'a13'/i);
  assert.doesNotMatch(seedUpgrade, /delete\s+from\s+auction_items\s+where\s+id\s*=\s*'a13'/i);
});

test('upgrade section does not reset live event rows', () => {
  assert.doesNotMatch(seedUpgrade, /\b(?:truncate|drop\s+table)\b/i);
  assert.doesNotMatch(seedUpgrade, /\bdelete\s+from\s+(?:teams|inventory|orders|auction_history|trading_listings|trading_history)\b/i);
  assert.doesNotMatch(seedUpgrade, /\bperform\s+_(?:reset_auction|clear_lot)\b/i);
});

test('legacy non-zero listing prices remain compatible', () => {
  assert.match(schema, /create table if not exists trading_listings[\s\S]*?price int not null check \(price >= 0\)/i);
  assert.match(schema, /create table if not exists trading_history[\s\S]*?price int not null/i);

  const legacyPublicState = {
    components: [{ id: 'c1', name: 'Bread board' }],
    auctionItems: [],
    tradingListings: [{ itemId: 'c1', qty: 1, price: 200 }],
  };
  assert.deepEqual(buildTradingCatalog(legacyPublicState).get('c1'), {
    id: 'c1', name: 'Bread board', source: 'shop', revealed: null,
  });
});

test('team listing creation accepts either catalog and reserves only whole owned quantities', () => {
  const sell = sqlFunction('_trade_sell');

  assert.match(sell, /_trading_open\(\)/i);
  assert.match(sell, /_trade_item_exists\(p_item_id\)/i);
  assert.match(sell, /p_qty\s*<>\s*trunc\(p_qty\)/i);
  assert.match(sell, /sum\(qty\)[\s\S]*status\s*=\s*'active'/i);
  assert.match(sell, /q\s*>\s*owned\s*-\s*committed/i);
  assert.match(sell, /values\s*\(p_team,\s*p_item_id,\s*q,\s*q,\s*0\)/i);
  assert.doesNotMatch(sell, /only shop components/i);
});

test('team listing updates are open-phase, owner-only, active-only, and reservation-safe', () => {
  const update = sqlFunction('_trade_update');

  assert.ok(update, '_trade_update must exist');
  assert.match(update, /_trading_open\(\)/i);
  assert.match(update, /where id\s*=\s*p_listing_id\s+and team_id\s*=\s*p_team/i);
  assert.match(update, /status\s*<>\s*'active'/i);
  assert.match(update, /p_qty\s*<>\s*trunc\(p_qty\)/i);
  assert.match(update, /id\s*<>\s*l\.id/i);
  assert.match(update, /q\s*>\s*owned\s*-\s*committed/i);
  assert.match(update, /update trading_listings set qty\s*=\s*q where id\s*=\s*l\.id/i);
});

test('team cancellation stays owner-only, active-only, and closed before auction completion', () => {
  const cancel = sqlFunction('_trade_cancel');

  assert.match(cancel, /_trading_open\(\)/i);
  assert.match(cancel, /where id\s*=\s*p_listing_id\s+and team_id\s*=\s*p_team/i);
  assert.match(cancel, /status\s*<>\s*'active'/i);
});

test('team API exposes listing update but no direct trade purchase path', () => {
  assert.match(api, /'trade\/update'\s*:\s*'trade_update'/i);
  assert.doesNotMatch(api, /'trade\/buy'\s*:/i);
  assert.match(schema, /p_action\s*=\s*'trade_update'[\s\S]*?_trade_update/i);
  assert.doesNotMatch(schema, /p_action\s*=\s*'trade_buy'/i);
  assert.doesNotMatch(schema, /create or replace function _trade_buy/i);
  assert.match(schema, /drop function if exists _trade_buy\(bigint,\s*numeric,\s*numeric\)/i);
});

test('admin trade completion validates listing, buyer, whole quantity, and whole non-negative price', () => {
  const complete = sqlFunction('_trade_admin_complete');

  assert.ok(complete, '_trade_admin_complete must exist');
  assert.match(complete, /_trading_open\(\)/i);
  assert.match(complete, /p_listing_id\s+is\s+null[\s\S]*p_listing_id\s*<>\s*trunc\(p_listing_id\)/i);
  assert.match(complete, /p_qty\s+is\s+null[\s\S]*p_qty\s*<>\s*trunc\(p_qty\)/i);
  assert.match(complete, /p_price\s+is\s+null[\s\S]*p_price\s*<\s*0[\s\S]*p_price\s*<>\s*trunc\(p_price\)/i);
  assert.match(complete, /l\.status\s*<>\s*'active'/i);
  assert.match(complete, /l\.team_id\s*=\s*p_buyer_id/i);
  assert.match(complete, /from teams where id\s*=\s*p_buyer_id/i);
  assert.match(complete, /q\s*>\s*l\.qty/i);
  assert.match(complete, /seller_owned\s*<\s*q/i);
  assert.match(complete, /buyer\.credits\s*<\s*cost/i);
});

test('admin trade completion atomically moves credits and inventory and records partial or final status', () => {
  const complete = sqlFunction('_trade_admin_complete');
  const firstMutation = complete.search(/update trading_listings set/i);
  const lastValidation = complete.search(/buyer\.credits\s*<\s*cost/i);

  assert.ok(lastValidation > 0 && firstMutation > lastValidation, 'all validation must precede mutations');
  assert.match(complete, /status\s*=\s*case when qty\s*-\s*q\s*=\s*0 then 'sold_out' else 'active' end/i);
  assert.match(complete, /update teams set credits\s*=\s*credits\s*-\s*cost where id\s*=\s*p_buyer_id/i);
  assert.match(complete, /update teams set credits\s*=\s*credits\s*\+\s*cost where id\s*=\s*l\.team_id/i);
  assert.match(complete, /update inventory set qty\s*=\s*qty\s*-\s*q[\s\S]*team_id\s*=\s*l\.team_id/i);
  assert.match(complete, /insert into inventory \(team_id, item_id, qty\) values \(p_buyer_id, l\.item_id, q\)/i);
  assert.match(complete, /insert into trading_history[\s\S]*values \(l\.team_id, p_buyer_id, l\.item_id, q, unit_price, cost\)/i);
});

test('admin state exposes resolvable active listings and completed history', () => {
  const state = sqlFunction('admin_state');

  assert.match(state, /'tradingListings'/i);
  assert.match(state, /'sellerId'[\s\S]*'sellerName'[\s\S]*'itemName'[\s\S]*'itemSource'/i);
  assert.match(state, /jsonb_agg\([\s\S]*?order by l\.id\)/i);
  assert.match(state, /from trading_listings l[\s\S]*?where l\.status\s*=\s*'active'/i);
  assert.match(state, /'tradingHistory'/i);
  assert.match(state, /'buyerId'[\s\S]*'buyerName'/i);
});

test('trade completion is reachable only through the locked admin dispatcher', () => {
  const admin = sqlFunction('game_admin');
  const team = sqlFunction('game_team');

  assert.match(admin, /pg_advisory_xact_lock\(4242\)/i);
  assert.match(admin, /p_action\s*=\s*'trade-complete'[\s\S]*?_trade_admin_complete\(/i);
  for (const field of ['listingId', 'buyerId', 'qty', 'price']) {
    assert.match(admin, new RegExp(`b->'${field}'`, 'i'), `admin action must read ${field}`);
  }
  assert.doesNotMatch(team, /trade-complete|_trade_admin_complete/i);
  assert.doesNotMatch(api, /['"]trade\/complete['"]/i);
});
