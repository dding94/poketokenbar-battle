import {engine, roundTrip} from '../src/index.js';
import {sha256} from '../src/hash.js';
const call=(method,...args)=>JSON.parse(engine[method](...args.map(JSON.stringify)));
function run(config,restore=false) {
  const created=call('createBattle',config);if(!created.ok)throw new Error(JSON.stringify(created));
  const id=created.id;let restored=false,forced=0,rejected=0;
  try {
    for(let n=0;n<402&&call('request',id,'p1').kind!=='none';n++) {
      for(const side of ['p1','p2']) {
        const req=call('request',id,side);if(req.kind==='none'||req.kind==='wait')continue;
        if(req.kind==='forced')forced++;
        let r;
        for(let retry=0;retry<5;retry++){r=call('choose',id,side,{type:'auto'});if(r.ok)break;
          if(r.error!=='rejected')break;rejected++;}
        if(!r.ok)throw new Error(JSON.stringify({r,req,n,side,config}));
        if(restore&&!restored){roundTrip(id);restored=true;}
      }
    }
    const r=call('result',id);if(!r.ended)throw new Error('runaway');
    return {...r,restored,forced,rejected};
  } finally {call('destroy',id);}
}
globalThis.PTBCorpus={run:json=>JSON.stringify(JSON.parse(json).map((config,i)=>{
  const baseline=run(config),restored=run(config,true),replay=call('replay',baseline.inputLog);
  if(replay.logHash!==baseline.logHash||restored.logHash!==baseline.logHash||replay.winner!==baseline.winner||!restored.restored)
    throw new Error(`corpus ${i}: replay/state mismatch ${JSON.stringify({baseline,restored,replay})}`);
  return {i,winner:baseline.winner,turns:baseline.turns,hash:baseline.logHash,
    inputHash:sha256(JSON.stringify(baseline.inputLog)),replay:true,state:true,forced:baseline.forced,rejected:baseline.rejected};
}))};
