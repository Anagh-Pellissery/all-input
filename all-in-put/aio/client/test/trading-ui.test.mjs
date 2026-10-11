import assert from 'node:assert/strict';
import test from 'node:test';

let tradingUi;
try {
  tradingUi = await import('../src/trading-ui.js');
} catch {
  tradingUi = null;
}

const requireTradingUi = () => {
  assert.ok(tradingUi, 'trading UI helpers must exist');
  return tradingUi;
};

test('catalog merges shop and auction items without inventing hidden reveals', () => {
  const { buildTradingCatalog } = requireTradingUi();
  const catalog = buildTradingCatalog({
    components: [{ id: 'c1', name: 'Bread board' }],
    auctionItems: [
      { id: 'a18', name: 'Mystery Box 1', reveal: null },
      { id: 'a19', name: 'Mystery Box 2', reveal: '₹5,000 game credits' },
    ],
  });

  assert.deepEqual(catalog.get('c1'), {
    id: 'c1', name: 'Bread board', source: 'shop', revealed: null,
  });
  assert.deepEqual(catalog.get('a18'), {
    id: 'a18', name: 'Mystery Box 1', source: 'auction', revealed: null,
  });
  assert.deepEqual(catalog.get('a19'), {
    id: 'a19', name: 'Mystery Box 2', source: 'auction', revealed: '₹5,000 game credits',
  });
});

test('tradeable inventory subtracts active reservations from owned quantities', () => {
  const { getTradeableInventory } = requireTradingUi();
  const items = getTradeableInventory({
    components: [{ id: 'c1', name: 'Bread board' }],
    auctionItems: [{ id: 'a18', name: 'Mystery Box 1', reveal: 'Chassis Kit' }],
  }, {
    inv: { c1: 2, a18: 1 },
    tradeCommitted: { c1: 1, a18: 0 },
  });

  assert.deepEqual(items, [
    { id: 'c1', name: 'Bread board', source: 'shop', revealed: null, owned: 2, committed: 1, available: 1 },
    { id: 'a18', name: 'Mystery Box 1', source: 'auction', revealed: 'Chassis Kit', owned: 1, committed: 0, available: 1 },
  ]);
});

test('tradeable inventory excludes fully reserved and unknown inventory entries', () => {
  const { getTradeableInventory } = requireTradingUi();
  const items = getTradeableInventory({
    components: [{ id: 'c1', name: 'Bread board' }],
    auctionItems: [],
  }, {
    inv: { c1: 2, unknown: 9 },
    tradeCommitted: { c1: 2 },
  });

  assert.deepEqual(items, []);
});

test('catalog and inventory helpers tolerate empty state', () => {
  const { buildTradingCatalog, getTradeableInventory } = requireTradingUi();

  assert.equal(buildTradingCatalog(null).size, 0);
  assert.deepEqual(getTradeableInventory(undefined, undefined), []);
});

test('trading and building start together only after the auction is done', () => {
  const { getPostAuctionPhase } = requireTradingUi();

  assert.deepEqual(getPostAuctionPhase({ auction: { status: 'live' } }), {
    tradingOpen: false,
    buildingStarted: false,
  });
  assert.deepEqual(getPostAuctionPhase({ auction: { status: 'done' } }), {
    tradingOpen: true,
    buildingStarted: true,
  });
  assert.deepEqual(getPostAuctionPhase(null), {
    tradingOpen: false,
    buildingStarted: false,
  });
});
