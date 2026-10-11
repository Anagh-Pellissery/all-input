import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { buildTradingCatalog } from '../src/trading-ui.js';

const schema = await readFile(new URL('../supabase/schema.sql', import.meta.url), 'utf8');
const seedUpgrade = schema.split('-- ---------------------------------------------------------------- seed data')[1] || '';

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
