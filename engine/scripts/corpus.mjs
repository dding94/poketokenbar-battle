import {Battle,Dex} from '@pkmn/sim';
import {build} from 'esbuild';
import {makeSet as engineSet} from '../src/input.js';
import {options} from './options.mjs';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const mode=process.argv[2];mkdirSync('out',{recursive:true});
if(mode==='generate') {
  let seed=0x7269;const rand=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
  const dex=Dex.forGen(9);const species=dex.species.all().filter(s=>s.num>0&&s.num<=649&&!s.forme);
  const moves=dex.moves.all().filter(m=>m.num>0&&m.gen<=5&&!m.isZ&&!m.isMax);
  const natures=dex.natures.all();
  const makeSet=()=>{const s=species[rand(species.length)];const chosen=[];
    while(chosen.length<4){const move=moves[rand(moves.length)].id;if(!chosen.includes(move))chosen.push(move);}
    return {speciesNum:s.num,form:null,level:1+rand(100),gender:s.gender==='N'?'genderless':s.gender==='F'?'female':'male',
      nature:natures[rand(natures.length)].id,ability:Object.values(s.abilities)[0].toLowerCase().replace(/[^a-z0-9]/g,''),
      moves:chosen,ivs:Object.fromEntries(['hp','attack','defense','special-attack','special-defense','speed'].map(k=>[k,rand(32)])),shiny:!!rand(2)};};
  // Each side's temperament comes from its own stream, so sets and seeds stay as before. null leaves the key out.
  let draw=0x504f4c;const policy=()=>{draw=(Math.imul(draw,1664525)+1013904223)>>>0;
    return [null,'standard','aggressive','tactical','erratic'][(draw>>>16)%5];};
  // A third of the sides get a starting HP, 1..max HP (describeSet's stats.hp), from a third stream: the rest stays put.
  const calculator=new Battle({formatid:'gen9customgame@@@Terastal Clause',seed:[0,0,0,1]});
  const maxHP=set=>{const s=engineSet(set);const sp=dex.species.get(s.species);return sp.maxHP||calculator.spreadModify(sp.baseStats,s).hp;};
  let hpDraw=0x4850;const hpRand=n=>{hpDraw=(Math.imul(hpDraw,1664525)+1013904223)>>>0;return Math.floor(hpDraw/0x100000000*n);};
  const startHP=set=>hpRand(3)?{}:{hp:1+hpRand(maxHP(set))};
  const player=(name,set,p=policy())=>({name,set,...(p&&{policy:p}),...startHP(set)});
  const corpus=Array.from({length:2200},(_,i)=>{const p1=makeSet(),p2=makeSet();
    if(i>=2000)for(const s of [p1,p2])Object.assign(s,{speciesNum:242,level:100,ability:'naturalcure',
      moves:['splash','growl','tailwhip','defensecurl'],ivs:{hp:31,attack:0,defense:31,'special-attack':0,'special-defense':31,speed:31}});
    return {seed:[rand(65536),rand(65536),rand(65536),rand(65536)],policySeed:rand(0xffffffff),p1:player('p1',p1),p2:player('p2',p2)};});
  calculator.destroy();
  const policies={},given={p1:0,p2:0};
  for(const c of corpus)for(const side of ['p1','p2']){const k=`${side}:${c[side].policy??'omitted'}`;policies[k]=(policies[k]||0)+1;if('hp' in c[side])given[side]++;}
  assert.ok(Object.keys(policies).length===10&&Object.values(policies).every(n=>n>=100),JSON.stringify(policies));
  assert.ok(given.p1>=500&&given.p2>=500,JSON.stringify(given));
  writeFileSync('out/corpus.json',JSON.stringify(corpus));
  await build({...options(process.env.PTB_FULL_ENGINE!=='1'),entryPoints:['tests/corpus-entry.js'],outfile:'out/corpus-engine.js'});
  console.log(`generated ${corpus.length} battles (2000 random + 200 long), temperaments ${JSON.stringify(policies)}, starting HP given ${JSON.stringify(given)}`);
} else if(mode==='node') {
  const context=vm.createContext({});vm.runInContext(readFileSync('out/corpus-engine.js','utf8'),context);
  const started=Date.now();const output=context.PTBCorpus.run(readFileSync('out/corpus.json','utf8'));
  writeFileSync('out/node.json',output);console.log(`Node: ${JSON.parse(output).length} replay + state checks, ${Date.now()-started}ms`);
} else if(mode==='compare') {
  const a=JSON.parse(readFileSync('out/node.json'));const b=JSON.parse(readFileSync('out/jsc.json'));
  assert.ok(a.length>=2200);assert.deepEqual(a,b);assert.ok(a.every(r=>r.replay&&r.state));
  assert.ok(a.slice(2000).every(r=>r.turns===200&&r.winner===null));
  console.log(`PASS ${a.length} battles: Node/JSC mismatches 0, replay failures 0, state failures 0; 200 cap draws`);
} else throw new Error('expected generate, node or compare');
