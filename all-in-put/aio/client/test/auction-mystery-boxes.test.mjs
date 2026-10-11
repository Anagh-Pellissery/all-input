import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

let auctionUi;
try {
  auctionUi = await import('../src/auction-ui.js');
} catch {
  auctionUi = null;
}

const schema = await readFile(new URL('../supabase/schema.sql', import.meta.url), 'utf8');

test('sold mystery boxes reveal the prize and winner', () => {
  assert.ok(auctionUi, 'auction reveal helpers are missing');
  if (!auctionUi) return;

  assert.equal(
    auctionUi.getMysteryRevealMessage({
      name: 'Mystery Box 1',
      reveal: 'Chassis Kit',
      team: 'Team Alpha',
      sold: true,
    }),
    'Mystery Box 1 revealed: Chassis Kit — won by Team Alpha',
  );
});

test('unsold and ordinary lots do not show a mystery reveal', () => {
  assert.ok(auctionUi, 'auction reveal helpers are missing');
  if (!auctionUi) return;

  assert.equal(auctionUi.getMysteryRevealMessage({
    name: 'Mystery Box 1', reveal: 'Chassis Kit', sold: false,
  }), null);
  assert.equal(auctionUi.getMysteryRevealMessage({
    name: 'LCD', reveal: null, team: 'Team Alpha', sold: true,
  }), null);
});

test('schema seeds the approved mystery boxes and LCD settings', () => {
  for (const id of ['a18', 'a19', 'a20', 'a21']) {
    assert.match(
      schema,
      new RegExp(`\\('${id}',\\s*\\d+,\\s*'Mystery Box [1-4]',\\s*'[^']+',\\s*90,\\s*1,\\s*3000,\\s*100,\\s*3000`),
      `${id} must be a single 90-second mystery-box lot starting at 3000 with a 100 increment`,
    );
  }
  assert.match(
    schema,
    /\('a17',\s*17,\s*'LCD',\s*90,\s*1,\s*3000,\s*100,\s*3000/,
    'LCD must use the approved quantity, timer, base, and increment',
  );
});

test('schema upgrades remove the retired auction LED without removing the shop LED', () => {
  assert.doesNotMatch(
    schema,
    /\('a13',\s*13,\s*'LED'/,
    'LED must no longer be seeded as an auction item',
  );
  assert.match(schema, /update\s+auction_state\s+set\s+queue\s*=\s*array_remove\(queue,\s*'a13'\)/i);
  assert.match(schema, /delete\s+from\s+auction_items\s+where\s+id\s*=\s*'a13'/i);
  assert.match(schema, /\('c7',\s*7,\s*'LED'/, 'the LED shop component must remain available');
});

test('schema upgrades preserve auction settings saved by the admin', () => {
  const mysteryUpgrade = schema.match(
    /insert into auction_items \(id, sort, name, reveal_name[\s\S]*?on conflict \(id\) do update set([\s\S]*?);/i,
  )?.[1] || '';

  assert.ok(mysteryUpgrade, 'mystery-box upgrade clause must exist');
  assert.doesNotMatch(mysteryUpgrade, /\b(time_sec|qty|base|inc|next_price)\s*=/i);
  assert.doesNotMatch(
    schema,
    /update\s+auction_items\s+set\s+time_sec\s*=\s*90[\s\S]*?where\s+id\s*=\s*'a17'/i,
    'rerunning the schema must not reset LCD settings saved by the admin',
  );
});

test('generated queues always start with Mystery Box 1 and randomize the remainder', () => {
  assert.match(
    schema,
    /then array\['a18'\]::text\[\][\s\S]*\|\|\s*coalesce\(\(select array_agg\(i\.id order by random\(\)\)/,
    'auction generation must prefix Mystery Box 1 before the randomized lots',
  );
  assert.match(
    schema,
    /where i\.id <> 'a18'/,
    'Mystery Box 1 must be excluded from the randomized remainder',
  );
});

test('mystery contents stay private until a sold result is published', () => {
  assert.match(schema, /alter table auction_items add column if not exists reveal_name text/);
  assert.match(
    schema,
    /case when exists[\s\S]*auction_history[\s\S]*h\.sold[\s\S]*then reveal_name end/,
    'public auction items may expose a prize only after that box is sold',
  );
  assert.match(
    schema,
    /jsonb_build_object\('name', h\.name, 'reveal', h\.reveal_name/,
    'completed auction results must publish the reveal separately from the hidden lot name',
  );
});
