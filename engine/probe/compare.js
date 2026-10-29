// Usage: node compare.js a.json b.json
const fs = require('fs');
const [a, b] = process.argv.slice(2).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
let mism = 0, winnerMism = 0, inputMism = 0; const ex = [];
const stats = {p1: 0, p2: 0, tie: 0, capTies: 0, turns: [], forced: 0, choiceErrors: 0, sodium: 0};
for (let i = 0; i < a.results.length; i++) {
  const x = a.results[i], y = b.results[i];
  if (x.id !== y.id) throw new Error('id order');
  if (x.winner !== y.winner) winnerMism++;
  if (x.inputLog !== y.inputLog) inputMism++;
  if (x.log !== y.log || x.hash !== y.hash) {
    mism++;
    if (ex.length < 3) {
      const la = x.log.split('\n'), lb = y.log.split('\n'); let k = 0;
      while (k < la.length && la[k] === lb[k]) k++;
      ex.push({id: x.id, line: k, a: la[k], b: lb[k]});
    }
  }
  stats[x.winner === '' ? 'tie' : x.winner]++;
  if (x.winner === '' && x.turns > 200) stats.capTies++;
  stats.turns.push(x.turns); stats.forced += x.forced; stats.choiceErrors += x.choiceErrors;
}
const t = stats.turns.sort((p, q) => p - q);
const totalLines = a.results.reduce((s, r) => s + r.lines, 0);
console.log(JSON.stringify({hostA: a.host, hostB: b.host, n: a.results.length, logMismatches: mism, winnerMismatches: winnerMism,
  inputLogMismatches: inputMism, examples: ex, winners: {p1: stats.p1, p2: stats.p2, tie: stats.tie, tieAtCap: stats.capTies},
  turns: {median: t[t.length >> 1], p95: t[Math.floor(t.length * .95)], max: t[t.length - 1]}, forcedRequests: stats.forced,
  choiceErrors: stats.choiceErrors, totalLogLines: totalLines,
  errorsA: a.results.filter(r => r.error).length, errorsB: b.results.filter(r => r.error).length}, null, 1));
