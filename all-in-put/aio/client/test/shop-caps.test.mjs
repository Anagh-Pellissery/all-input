import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

let shopCaps;
try {
  shopCaps = await import('../src/shop-caps.js');
} catch {
  shopCaps = null;
}

const allowance = (itemId, inventory = {}) => {
  assert.ok(shopCaps, 'shop cap helpers must exist');
  return shopCaps.getShopAllowance(itemId, inventory);
};

test('individual shop caps use the quantity already owned by the team', () => {
  assert.deepEqual(allowance('c1', { c1: 1 }), { cap: 2, owned: 1, remaining: 1 });
  assert.deepEqual(allowance('c2', { c2: 2 }), { cap: 2, owned: 2, remaining: 0 });
  assert.deepEqual(allowance('c7', { c7: 4 }), { cap: 10, owned: 4, remaining: 6 });
  assert.deepEqual(allowance('c8', {}), { cap: 1, owned: 0, remaining: 1 });
});

test('all resistor types share one combined cap of ten', () => {
  const inventory = { c3: 3, c4: 2, c5: 4, c6: 0 };

  assert.deepEqual(allowance('c3', inventory), { cap: 10, owned: 9, remaining: 1 });
  assert.deepEqual(allowance('c6', { ...inventory, c6: 1 }), { cap: 10, owned: 10, remaining: 0 });
});

test('the exact remaining quantity is allowed and any larger purchase is blocked', () => {
  assert.ok(shopCaps, 'shop cap helpers must exist');
  if (!shopCaps) return;

  assert.equal(shopCaps.canBuyShopQuantity('c7', 4, { c7: 6 }), true);
  assert.equal(shopCaps.canBuyShopQuantity('c7', 5, { c7: 6 }), false);
  assert.equal(shopCaps.canBuyShopQuantity('c5', 1, { c3: 4, c4: 3, c5: 2, c6: 1 }), false);
  assert.equal(shopCaps.canBuyShopQuantity('c1', 0, {}), false);
});

test('the database purchase function enforces caps and migrates the jumper-wire label', async () => {
  const schema = await readFile(new URL('../supabase/schema.sql', import.meta.url), 'utf8');

  assert.match(schema, /v_owned\s*\+\s*q\s*>\s*v_cap/i);
  assert.match(schema, /item_id\s+in\s*\(\s*'c3'\s*,\s*'c4'\s*,\s*'c5'\s*,\s*'c6'\s*\)/i);
  assert.match(schema, /update\s+shop_components\s+set\s+name\s*=\s*'Jumper wires 8x each'\s+where\s+id\s*=\s*'c2'/i);
});
