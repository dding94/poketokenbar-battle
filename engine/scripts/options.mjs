// Battle execution uses explicit moves. Legality/learnset lookup is outside this adapter.
export const options = (trim=true) => ({bundle:true,minify:true,keepNames:true,format:'iife',platform:'neutral',
  target:'es2020',mainFields:['module','main'],conditions:['import'],alias:{path:'./probe/empty-path.js'},
  plugins:trim?[{name:'omit-learnsets',setup(build){
    build.onLoad({filter:/\/legality\.mjs$/},()=>({contents:'export const Legality = {};',loader:'js'}));
    build.onLoad({filter:/\/learnsets\.mjs$/},()=>({contents:'export const Learnsets = {};',loader:'js'}));
  }}]:[]});
