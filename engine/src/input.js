import {Dex} from '@pkmn/sim';
import {POLICIES} from './policy.js';
export const fail = code => {throw new Error(code);};
export const keys = (value, allowed) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).every(k => allowed.includes(k));
const forms = {
  201: 'abcdefghijklmnopqrstuvwxyz'.split('').concat(['exclamation','question']),
  351:['normal','sunny','rainy','snowy'],386:['normal','attack','defense','speed'],
  412:['plant','sandy','trash'],413:['plant','sandy','trash'],421:['overcast','sunshine'],
  422:['west','east'],423:['west','east'],479:['normal','heat','wash','frost','fan','mow'],
  487:['altered','origin'],492:['land','sky'],
  493:['normal','fighting','flying','poison','ground','rock','bug','ghost','steel','fire','water','grass','electric','psychic','ice','dragon','dark','fairy'],
  550:['red-striped','blue-striped'],555:['standard','zen'],585:['spring','summer','autumn','winter'],
  586:['spring','summer','autumn','winter'],641:['incarnate','therian'],642:['incarnate','therian'],
  645:['incarnate','therian'],646:['normal','black','white'],647:['ordinary','resolute'],
  648:['aria','pirouette'],649:['normal','douse','shock','burn','chill'],
};
const mapped = {386:{attack:'Deoxys-Attack',defense:'Deoxys-Defense',speed:'Deoxys-Speed'},
  413:{sandy:'Wormadam-Sandy',trash:'Wormadam-Trash'},
  479:{heat:'Rotom-Heat',wash:'Rotom-Wash',frost:'Rotom-Frost',fan:'Rotom-Fan',mow:'Rotom-Mow'},
  492:{sky:'Shaymin-Sky'},550:{'blue-striped':'Basculin-Blue-Striped'},
  641:{therian:'Tornadus-Therian'},642:{therian:'Thundurus-Therian'},645:{therian:'Landorus-Therian'},
  646:{black:'Kyurem-Black',white:'Kyurem-White'},647:{resolute:'Keldeo-Resolute'}};
// Cosmetic, weather-triggered and item-dependent forms start in their unmodified base form.
const base = new Map(Dex.species.all().filter(s=>s.num>0&&s.num<=649&&!s.forme).map(s=>[s.num,s]));
export function speciesFor(num, form) {
  const species=base.get(num);if(!species)fail('invalid_species');
  if(form!=null && !forms[num]?.includes(form))fail('invalid_form');
  return Dex.species.get(mapped[num]?.[form] || species.name);
}
const stats={hp:'hp',attack:'atk',defense:'def','special-attack':'spa','special-defense':'spd',speed:'spe'};
export const slug = v => typeof v==='string'&&/^[a-z0-9-]+$/.test(v);
export function makeSet(s) {
  if(!keys(s,['speciesNum','form','level','gender','nature','ability','moves','ivs','shiny']))fail('invalid_set');
  const species=speciesFor(s.speciesNum,s.form);
  if(!Number.isInteger(s.level)||s.level<1||s.level>100)fail('invalid_level');
  if(!['male','female','genderless'].includes(s.gender))fail('invalid_gender');
  if(!slug(s.nature)||!Dex.natures.get(s.nature).exists)fail('invalid_nature');
  if(!slug(s.ability)||!Dex.abilities.get(s.ability).exists)fail('invalid_ability');
  if(!Array.isArray(s.moves)||s.moves.length<1||s.moves.length>4||new Set(s.moves.map(m=>Dex.moves.get(m).id)).size!==s.moves.length||
    s.moves.some(m=>!slug(m)||!Dex.moves.get(m).exists))fail('invalid_moves');
  if(!keys(s.ivs,Object.keys(stats))||Object.keys(s.ivs).length!==6||
    Object.values(s.ivs).some(n=>!Number.isInteger(n)||n<0||n>31))fail('invalid_ivs');
  if(typeof s.shiny!=='boolean')fail('invalid_shiny');
  return {name:species.name,species:species.name,level:s.level,gender:{male:'M',female:'F',genderless:'N'}[s.gender],
    nature:Dex.natures.get(s.nature).name,ability:Dex.abilities.get(s.ability).name,moves:s.moves.map(m=>Dex.moves.get(m).id),
    ivs:Object.fromEntries(Object.entries(stats).map(([k,v])=>[v,s.ivs[k]])),
    evs:{hp:0,atk:0,def:0,spa:0,spd:0,spe:0},item:'',shiny:s.shiny};
}
export function validateConfig(c) {
  if(!keys(c,['seed','policySeed','p1','p2']))fail('invalid_config');
  if(!Array.isArray(c.seed)||c.seed.length!==4||c.seed.some(n=>!Number.isInteger(n)||n<0||n>65535))fail('invalid_seed');
  if(!Number.isInteger(c.policySeed)||c.policySeed<0||c.policySeed>0xffffffff)fail('invalid_policy_seed');
  for(const side of ['p1','p2']) {
    if(!keys(c[side],['name','set','policy','hp'])||typeof c[side].name!=='string'||c[side].name.length>80)fail('invalid_player');
    // An omitted policy is standard. The config is kept as given, so the input log names the policy that picked.
    if('policy' in c[side]&&!POLICIES.includes(c[side].policy))fail('invalid_policy');
    // An omitted hp is full. createBattle checks the upper bound, the set's max HP, once the Pokemon exists.
    if('hp' in c[side]&&!(Number.isInteger(c[side].hp)&&c[side].hp>=1))fail('invalid_hp');
  }
  return [makeSet(c.p1.set),makeSet(c.p2.set)];
}
export {forms};
