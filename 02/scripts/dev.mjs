import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const env={...process.env};
const dotenv=path.join(root,'.env');
if(existsSync(dotenv)) for(const line of readFileSync(dotenv,'utf8').split(/\r?\n/)){
 const match=line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
 if(!match)continue;
 let value=match[2];
 if((value.startsWith('"')&&value.endsWith('"'))||(value.startsWith("'")&&value.endsWith("'")))value=value.slice(1,-1);
 else value=value.replace(/\s+#.*$/,'');
 // Intentionally no shell evaluation, interpolation or logging of secrets.
 env[match[1]]=value;
}
const win=process.platform==='win32';
const children=[];let stopping=false;
function stop(code=0){if(stopping)return;stopping=true;
 for(const c of children){if(!c.pid)continue;try{if(win)spawnSync('taskkill',['/pid',String(c.pid),'/t','/f'],{stdio:'ignore'});else process.kill(-c.pid,'SIGTERM');}catch{}}
 setTimeout(()=>process.exit(code),150);
}
function start(command,args,cwd){const c=spawn(command,args,{cwd,env,stdio:'inherit',detached:!win,shell:win});children.push(c);c.on('error',e=>{console.error('Could not start process:',e.message);stop(1);});c.on('exit',code=>{if(!stopping)stop(code??1);});}
console.log('Coffee Lab: UI http://localhost:5173, API http://localhost:8080. Ctrl+C stops both.');
start(win?'gradlew.bat':'./gradlew',['--console=plain','quarkusDev'],root);
start(win?'npm.cmd':'npm',['run','dev','--','--strictPort'],path.join(root,'frontend'));
process.on('SIGINT',()=>stop());process.on('SIGTERM',()=>stop());
