import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { readFile, writeFile, rename, unlink, mkdir } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';

const dir=process.env.RUNNER_TEMP+'/margin-evidence', ipc=process.env.RUNNER_TEMP+'/margin-ipc';
await mkdir(dir,{recursive:true}); await mkdir(ipc,{recursive:true});
const url='https://arxiv.org/pdf/2506.01844#page=4&zoom=150,0,298';
const source=await readFile('Sources/Margin/Resources/PDFViewport.js','utf8');
const profile=process.env.RUNNER_TEMP+'/margin-chrome';
await mkdir(profile+'/Default',{recursive:true});
await writeFile(profile+'/Default/Preferences',JSON.stringify({browser:{allow_javascript_apple_events:true}}));
const browser=await chromium.launchPersistentContext(profile,{channel:'chrome',headless:false,viewport:null,args:['--no-first-run','--no-default-browser-check','--force-renderer-accessibility','--window-size=1300,850']});
let child;
try {
  const p=await browser.newPage(); await p.bringToFront();
  await p.route('https://arxiv.org/pdf/2506.01844',r=>r.fulfill({path:process.env.RUNNER_TEMP+'/smolvla.pdf',contentType:'application/pdf'}));
  const response=await p.goto(url,{timeout:30000,waitUntil:'commit'});
  console.log('HTTP',response.status(),await response.headerValue('content-type'),await p.evaluate(()=>document.contentType));
  if(response.status()!==200||await p.evaluate(()=>document.contentType)!=='application/pdf') throw Error('paper unavailable');
  await delay(3500);
  async function snapshot(name) {
    try {await p.screenshot({path:dir+'/'+name+'.png',timeout:4500})}
    catch (error) { console.warn('Chrome screenshot:',String(error));const cp=spawn('/usr/sbin/screencapture',['-x',dir+'/'+name+'-desktop.png'],{stdio:'inherit'});const watchdog=setTimeout(()=>cp.kill(),3000);await once(cp,'exit');clearTimeout(watchdog); }
  }
  await snapshot('before');
  child=spawn('swift',['test','--skip-build','--filter','HostedPDFInteraction'],{stdio:'inherit',env:{...process.env,MARGIN_HOSTED_INTERACTION:'1',MARGIN_IPC:ipc}});
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
