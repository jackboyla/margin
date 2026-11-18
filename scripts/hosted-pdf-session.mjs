import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { readFile, writeFile, rename, unlink, mkdir } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
import { openSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const dir=process.env.RUNNER_TEMP+'/margin-evidence', ipc=process.env.RUNNER_TEMP+'/margin-ipc';
await mkdir(dir,{recursive:true}); await mkdir(ipc,{recursive:true});
const url='https://arxiv.org/pdf/2506.01844#page=4&zoom=150,0,298';
const source=await readFile('Sources/Margin/Resources/PDFViewport.js','utf8');
const profile=process.env.RUNNER_TEMP+'/margin-chrome';
await mkdir(profile+'/Default',{recursive:true});
await writeFile(profile+'/Default/Preferences',JSON.stringify({browser:{allow_javascript_apple_events:true}}));
const local=pathToFileURL(process.env.RUNNER_TEMP+'/smolvla.pdf').href+'#page=4&zoom=150,0,298';
const args=['--no-first-run','--no-default-browser-check','--use-mock-keychain','--password-store=basic','--disable-background-networking','--disable-component-update','--force-renderer-accessibility','--remote-debugging-port=0','--user-data-dir='+profile,'--window-size=1300,850',local];
const trace = async msg => {
  console.log(msg);
  const {appendFile}=await import('node:fs/promises');
  await appendFile(dir+'/phases.txt',new Date().toISOString()+' '+msg+'\n');
};
const log=openSync(dir+'/chrome.log','w');
const program='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome=spawn(program,args,{detached:true,stdio:['ignore',log,log]});
chrome.unref();
process.env.MARGIN_CHROME_PID=String(chrome.pid);
await trace('spawned Chrome PID '+chrome.pid);
await delay(5000);
const localShot=spawn('/usr/sbin/screencapture',['-x',dir+'/local.png'],{stdio:'inherit'});localShot.unref();
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
    if(p.url()!==url) throw Error('top-level document changed: '+p.url());
    if(request.action==='reset') {
      await p.reload({waitUntil:'commit'});
      await p.bringToFront();
      await delay(4000);
      reply='ok';
    } else if(request.action==='interaction') {
      if(request.step===1) {
        await p.mouse.click(390,210);
        await p.mouse.move(690,290);
        await p.mouse.wheel(0,96);
        await delay(500);
      }
      await snapshot('before-'+request.step);
      reply='ok';
    } else if(request.action==='evidence') {
      await delay(350);
      await snapshot('after-'+request.step);
      reply=await p.evaluate(()=>{
        const active=[...document.querySelectorAll('iframe[title="PDF with saved highlights"]')].filter(f=>f.isConnected&&getComputedStyle(f).opacity==='1');
        return active.length===1?active[0].src:'';
      });
      if(request.step===0 && reply){
        const files=await Promise.all([dir+'/before-0.png',dir+'/after-0.png'].map(async f=>(await readFile(f)).toString('base64')));
        const diff=await p.evaluate(async images=>{
          async function frame(data){
            const image=new Image();image.src='data:image/png;base64,'+data;await image.decode();
            const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;
            const d=canvas.getContext('2d');d.drawImage(image,0,0);
            return d.getImageData(330,205,image.width-360,image.height-310);
          }
          const [a,b]=await Promise.all(images.map(frame));let minY=a.height,maxY=-1,changed=0,yellow=0;
          const rows=Array(a.height).fill(0);
          for(let i=0;i<a.data.length;i+=4){
            const y=Math.floor(i/4/a.width);
            if(a.data[i]!==b.data[i]||a.data[i+1]!==b.data[i+1]||a.data[i+2]!==b.data[i+2]){
              rows[y]++;changed++;
              if(b.data[i]>175 && b.data[i+1]>145 && b.data[i+2]+35<b.data[i+1]){
                minY=Math.min(minY,y);maxY=Math.max(maxY,y);yellow++;
              }
            }
          }
          const outside=rows.reduce((n,v,y)=>n+((y<minY-2||y>maxY+2)?v:0),0);
          return {minY,maxY,changed,yellow,outside};
        },files);
        console.log('FIRST MARK PIXELS',diff);await writeFile(dir+'/pixel-report.json',JSON.stringify(diff));
        if(diff.outside>0){const {copyFile}=await import('node:fs/promises');await copyFile(process.env.RUNNER_TEMP+'/margin-native-annotated.pdf',dir+'/first-staged.pdf')}
      }
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
