const RESISTOR_IDS = ['c3', 'c4', 'c5', 'c6'];
const INDIVIDUAL_CAPS = { c1: 2, c2: 2, c7: 10, c8: 1, c9: 2, c10: 2 };

export const isResistorShopItem = itemId => RESISTOR_IDS.includes(itemId);

const ownedQuantity = (inventory, itemId) => {
  const quantity = Number(inventory?.[itemId] || 0);
  return Number.isFinite(quantity) && quantity > 0 ? quantity : 0;
};

export const getShopAllowance = (itemId, inventory = {}) => {
  const isResistor = isResistorShopItem(itemId);
  const cap = isResistor ? 10 : INDIVIDUAL_CAPS[itemId];
  if (cap === undefined) return null;

  const owned = isResistor
    ? RESISTOR_IDS.reduce((total, id) => total + ownedQuantity(inventory, id), 0)
    : ownedQuantity(inventory, itemId);

  return { cap, owned, remaining: Math.max(0, cap - owned) };
};

export const canBuyShopQuantity = (itemId, quantity, inventory = {}) => {
  const requested = Number(quantity);
  if (!Number.isInteger(requested) || requested < 1) return false;

  const allowance = getShopAllowance(itemId, inventory);
  return allowance === null || requested <= allowance.remaining;
};
