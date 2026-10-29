import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';
const context=vm.createContext({});vm.runInContext(readFileSync('dist/battle-engine.js','utf8'),context);
const call=(name,...args)=>JSON.parse(context.PTBEngine[name](...args.map(JSON.stringify)));
import {Battle,Dex,toID} from '@pkmn/sim';
import {speciesFor,forms} from '../src/input.js';
const reference=JSON.parse(readFileSync('.cache/compat-input.json'));
const stats={hp:'hp',attack:'atk',defense:'def','special-attack':'spa','special-defense':'spd',speed:'spe'};
const differences=[];
for(const p of reference.pokemon){const s=speciesFor(p.num,null);
  for(const [k,v] of Object.entries(stats))if(s.baseStats[v]!==p.stats[k])differences.push({num:p.num,field:k,app:p.stats[k],engine:s.baseStats[v]});
  if(JSON.stringify(p.types.map(toID).sort())!==JSON.stringify(s.types.map(toID).sort()))differences.push({num:p.num,field:'types',app:p.types,engine:s.types});
  if(JSON.stringify(p.abilities.map(toID).sort())!==JSON.stringify(Object.values(s.abilities).map(toID).sort()))differences.push({num:p.num,field:'abilities',app:p.abilities,engine:Object.values(s.abilities)});
}
let formCount=0;
for(const [num,list] of Object.entries(forms))for(const form of list){const s=speciesFor(Number(num),form);assert.ok(s.exists);assert.equal(s.num,Number(num));formCount++;}
const swift=readFileSync('../Sources/PokeTokenBar/Core/PokemonForm.swift','utf8');
const swiftForms={201:'abcdefghijklmnopqrstuvwxyz'.split('').concat(['exclamation','question'])};
for(const match of swift.matchAll(/(\d+): \[([\s\S]*?)\](?=,?\n)/g)){
  const names=[...match[2].matchAll(/\.init\("([a-z-]+)", formID:/g)].map(m=>m[1]);
  if(names.length)swiftForms[match[1]]=names;
}
assert.deepEqual(forms,swiftForms,'every species/form pair must match the app catalog');
const set=(species,move)=>({species,moves:[move],ability:'Pressure',level:100,evs:{hp:0,atk:0,def:0,spa:0,spd:0,spe:0},nature:'Hardy'});
let expectedFailures=0;
for(const move of reference.moves){assert.ok(Dex.moves.get(move).exists,move);
  const input=(speciesNum,moves)=>({speciesNum,form:null,level:100,gender:'genderless',nature:'hardy',ability:'pressure',moves,
    ivs:{hp:31,attack:31,defense:31,'special-attack':31,'special-defense':31,speed:31},shiny:false});
  const created=call('createBattle',{seed:[9,8,7,6],policySeed:1,p1:{name:'p1',set:input(151,[move])},p2:{name:'p2',set:input(242,['splash'])}});
  assert.equal(created.ok,true,move);const id=created.id;
  assert.equal(call('choose',id,'p1',{type:'move',slot:1}).ok,true,move);
  assert.equal(call('choose',id,'p2',{type:'move',slot:1}).ok,true,move);
  assert.ok(call('drainLog',id,'spectator').some(l=>l.startsWith('|move|p1a:')&&toID(l.split('|')[3])===Dex.moves.get(move).id),move);
  call('destroy',id);
  const b=new Battle({formatid:'gen9customgame@@@Terastal Clause',seed:[9,8,7,6],
    p1:{name:'p1',team:[set('Mew',move)]},p2:{name:'p2',team:[set('Blissey','splash')]}});
  assert.equal(b.gen,9);b.choose('p1','team 1');b.choose('p2','team 1');
  assert.ok(b.choose('p1','move 1'),move);assert.ok(b.choose('p2','move 1'),move);
  assert.ok(b.log.some(l=>l.startsWith('|move|p1a:')&&toID(l.split('|')[3])===Dex.moves.get(move).id),move);
  if(b.log.some(l=>l.startsWith('|-fail|p1a:')))expectedFailures++;
  assert.ok(!b.log.some(l=>l.startsWith('|error|')),move);b.destroy();
}
const report={reference:'PokeAPI/pokeapi@2bf639e5572812a67d2b94903fdcb9d095f5aeb2',engine:'@pkmn/sim@0.10.12',
  species:reference.pokemon.length,forms:formCount,levelUpMoves:reference.moves.length,conditionalMoveFailures:expectedFailures,differences};
writeFileSync('out/compatibility.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
assert.equal(differences.length,0,'latest PokeAPI and gen9 differ: requires an explicit mapping decision');
