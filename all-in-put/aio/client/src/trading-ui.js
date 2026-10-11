const count = value => {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
};

export function buildTradingCatalog(publicState) {
  const catalog = new Map();

  for (const item of publicState?.components || []) {
    if (!item?.id) continue;
    catalog.set(item.id, {
      id: item.id,
      name: item.name || item.id,
      source: 'shop',
      revealed: null,
    });
  }

  for (const item of publicState?.auctionItems || []) {
    if (!item?.id) continue;
    const reveal = typeof item.reveal === 'string' && item.reveal.trim()
      ? item.reveal.trim()
      : null;
    catalog.set(item.id, {
      id: item.id,
      name: item.name || item.id,
      source: 'auction',
      revealed: reveal,
    });
  }

  return catalog;
}

export function getTradeableInventory(publicState, me) {
  const inventory = me?.inv || {};
  const committed = me?.tradeCommitted || {};

  return [...buildTradingCatalog(publicState).values()].flatMap(item => {
    const owned = count(inventory[item.id]);
    const reserved = count(committed[item.id]);
    const available = Math.max(0, owned - reserved);
    return available > 0
      ? [{ ...item, owned, committed: reserved, available }]
      : [];
  });
}

export function getPostAuctionPhase(publicState) {
  const started = publicState?.auction?.status === 'done';
  return { tradingOpen: started, buildingStarted: started };
}
