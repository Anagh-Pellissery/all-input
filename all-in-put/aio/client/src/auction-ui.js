export const getMysteryRevealMessage = (result) => {
  if (!result?.sold || !result.reveal || !result.name?.startsWith('Mystery Box')) return null;
  return `${result.name} revealed: ${result.reveal} — won by ${result.team}`;
};
