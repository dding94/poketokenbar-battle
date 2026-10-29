// Usage: node run-node.js engine.js corpus.json out.json
const fs = require('fs'), vm = require('vm');
const [engine, corpusPath, outPath] = process.argv.slice(2);
const src = fs.readFileSync(engine, 'utf8');
const corpusText = fs.readFileSync(corpusPath, 'utf8');
const t0 = performance.now();
vm.runInThisContext(src, {filename: 'engine.js'});
const t1 = performance.now();
const res = PTBEngine.runCorpus(corpusText, {withLogs: true, now: () => performance.now(),
  replay: process.env.REPLAY === '1', serializeAtTurn: +process.env.SER || 0});
const t2 = performance.now();
res.host = 'node ' + process.version;
res.timing.evalMs = t1 - t0; res.timing.totalMs = t2 - t0;
fs.writeFileSync(outPath, JSON.stringify(res));
const r = res.results;
console.log(JSON.stringify({host: res.host, timing: res.timing, errors: r.filter(x => x.error).length,
  replayFail: r.filter(x => x.replayOk === false).length, stateFail: r.filter(x => x.stateOk === false).length}));
