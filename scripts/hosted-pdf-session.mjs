import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { readFile, writeFile, rename, unlink, mkdir } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';

const dir=process.env.RUNNER_TEMP+'/margin-evidence', ipc=process.env.RUNNER_TEMP+'/margin-ipc';
await mkdir(dir,{recursive:true}); await mkdir(ipc,{recursive:true});
const url='https://arxiv.org/pdf/2506.01844#page=4&zoom=150,0,298';
const source=await readFile('Sources/Margin/Resources/PDFViewport.js','utf8');
const profile=process.env.RUNNER_TEMP+'/margin-chrome';
await mkdir(profile+'/Default',{recursive:true});
await writeFile(profile+'/Default/Preferences',JSON.stringify({browser:{allow_javascript_apple_events:true}}));
const local=pathToFileURL(process.env.RUNNER_TEMP+'/smolvla.pdf').href+'#page=4&zoom=150,0,298';
const args=['-na','Google Chrome','--args','--no-first-run','--no-default-browser-check','--remote-debugging-port=0','--user-data-dir='+profile,'--window-size=1300,850',local];
const trace = async msg => {
  console.log(msg);
  const { appendFile }=await import('node:fs/promises');
  await appendFile(dir+'/phases.txt',new Date().toISOString()+' '+msg+'\n');
};
await trace('launching system Chrome');
const opener=spawn('/usr/bin/open',args,{stdio:'inherit'});
await Promise.race([once(opener,'exit'),delay(10000)]);
await trace('requested Chrome launch');
await delay(4500);
await trace('starting standalone AX measurement');
const base=spawn('swift',['test','--skip-build','--filter','HostedPDFInteraction'],{detached:true,stdio:'inherit',env:{...process.env,MARGIN_HOSTED_INTERACTION:'1',MARGIN_IPC:ipc,MARGIN_AX_ONLY:'1'}});
const baseTimer=setTimeout(()=>{try{process.kill(-base.pid,'SIGTERM')}catch{}},60000);
const localExit=await once(base,'exit');clearTimeout(baseTimer);
await trace('standalone AX exit '+localExit);

const [port]=String(await readFile(profile+'/DevToolsActivePort')).split('\n');
const browser=await chromium.connectOverCDP('http://127.0.0.1:'+port,{timeout:12000});
await trace('attached Chrome');
let child;
try {
  const context=browser.contexts()[0];
  const p=context.pages()[0]; await p.bringToFront();
  await p.route('https://arxiv.org/pdf/2506.01844',r=>r.fulfill({path:process.env.RUNNER_TEMP+'/smolvla.pdf',contentType:'application/pdf'}));
  await trace('opening original HTTPS address');
  const response=await p.goto(url,{timeout:30000,waitUntil:'commit'});
  console.log('HTTP',response.status(),await response.headerValue('content-type'),await p.evaluate(()=>document.contentType));
  if(response.status()!==200||await p.evaluate(()=>document.contentType)!=='application/pdf') throw Error('paper unavailable');
  await delay(3500);
  async function snapshot(name) {
    const cp=spawn('/usr/sbin/screencapture',['-x',dir+'/'+name+'.png'],{stdio:'inherit'});
    const watchdog=setTimeout(()=>cp.kill(),4000);
    await once(cp,'exit');clearTimeout(watchdog);
  }
  const initialSnapshot=snapshot('before');
  child=spawn('swift',['test','--skip-build','--filter','HostedPDFInteraction'],{stdio:'inherit',env:{...process.env,MARGIN_HOSTED_INTERACTION:'1',MARGIN_IPC:ipc}});
  await trace('started native painting');
  await initialSnapshot;
  let completed=false;
  const completion=once(child,'exit').then(([code])=>{completed=true; return code;});
  const deadline=Date.now()+180000;
  while(!completed && Date.now()<deadline) {
    let content;
    try{content=await readFile(ipc+'/request','utf8')}catch(e){if(e.code!=='ENOENT')throw e;await delay(25);continue}
    await unlink(ipc+'/request');
    const request=JSON.parse(content);
    let reply;
    if(request.action==='evidence') {
      await delay(350);
      await snapshot('after-'+request.step);
      reply=await p.evaluate(()=>document.querySelector('iframe[title="PDF with saved highlights"]')?.src??'');
      console.log('active',request.step,reply);
    } else {
      const result=await p.evaluate(source.replace('__MARGIN_REQUEST__',()=>JSON.stringify({...request,url})));
      reply=JSON.parse(result).status;
    }
    await writeFile(ipc+'/reply.tmp',reply); await rename(ipc+'/reply.tmp',ipc+'/reply');
  }
  if(!completed) throw Error('native test timed out');
  if(await completion!==0) throw Error('native integration failed');
} finally {if(child && child.exitCode===null) child.kill(); await browser.close()}
