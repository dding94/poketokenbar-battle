// Generates a deterministic corpus of random Gen 5 1v1 battles. Usage: node gen-corpus.js N out.json
const {Dex} = require(process.env.PKG + '/node_modules/@pkmn/sim');
const N = +process.argv[2], OUT = process.argv[3];
function mulberry32(a){return function(){a=(a+0x6D2B79F5)>>>0;let t=a;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);return((t^(t>>>14))>>>0)/4294967296;};}
const R = mulberry32(20261029);
const ri = n => Math.floor(R() * n);
const pick = a => a[ri(a.length)];
const d = Dex.forGen(5);
const species = d.species.all().filter(s => s.exists && s.num >= 1 && s.num <= 649 && !s.isNonstandard &&
  !s.battleOnly && !s.requiredItem && !(s.requiredItems && s.requiredItems.length) && !s.requiredMove);
const allMoves = d.moves.all().filter(m => m.exists && !m.isNonstandard && m.gen <= 5 && m.id !== 'struggle' && !m.isZ && !m.isMax);
const natures = d.natures.all().map(n => n.name);
let fallbackCount = 0;
function learnable(s) {
  for (const id of [s.id, d.toID(s.changesFrom || ''), d.toID(s.baseSpecies)]) {
    if (!id) continue;
    const ls = d.species.getLearnsetData(id);
    if (ls && ls.learnset) {
      const ms = Object.entries(ls.learnset).filter(([m, src]) => src.some(x => +x.charAt(0) <= 5))
        .map(([m]) => d.moves.get(m)).filter(m => m.exists && !m.isNonstandard && m.gen <= 5).map(m => m.id);
      if (ms.length) return ms;
    }
  }
  return null;
}
function mkSet() {
  const s = pick(species);
  let pool = learnable(s);
  if (!pool) { fallbackCount++; pool = allMoves.map(m => m.id); }
  pool = pool.slice();
  const moves = [];
  while (moves.length < 4 && pool.length) moves.push(pool.splice(ri(pool.length), 1)[0]);
  const abil = Object.values(s.abilities).filter(Boolean);
  const iv = () => ri(32);
  return {species: s.name, ability: pick(abil), moves, nature: pick(natures), level: 5 + ri(96),
    evs: {hp:0,atk:0,def:0,spa:0,spd:0,spe:0}, ivs: {hp:iv(),atk:iv(),def:iv(),spa:iv(),spd:iv(),spe:iv()}, item: ''};
}
const hex = n => Array.from({length:n}, () => ri(16).toString(16)).join('');
const corpus = [];
for (let i = 0; i < N; i++) {
  const seed = i % 2 === 0 ? [ri(65536), ri(65536), ri(65536), ri(65536)].join(',') : 'sodium,' + hex(32);
  corpus.push({id: i, seed, policySeed: (R() * 4294967296) >>> 0, p1: [mkSet()], p2: [mkSet()]});
}
require('fs').writeFileSync(OUT, JSON.stringify(corpus));
console.log(JSON.stringify({n: N, speciesPool: species.length, movePool: allMoves.length, fallbackSets: fallbackCount}));
