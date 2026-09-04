const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname,'../MultiChatViewer/alert-queue.js'),'utf8');
let now=0, clock=[], order=0;
const events=[], waiting=[];
let owner=null;
function page(host) {
  const context=vm.createContext({
    location:{hostname:host},
    setTimeout(fn,delay,...args) {clock.push({at:now+Number(delay||0),fn:()=>fn(...args),order:++order});return order},
    clearTimeout(id) {clock=clock.filter(t=>t.order!==id)},
    mcAlertBridge:{postMessage(raw) {
      const e=JSON.parse(raw);events.push([host,e.type,e.sequence,now]);
      if(e.type==='request') {waiting.push({context,host,seq:e.sequence});drain();vm.runInContext(`__mcAlertQueue.accepted(${e.sequence})`,context)}
      if(e.type==='done') {assert.equal(owner.host,host);assert.equal(owner.seq,e.sequence);owner=null;drain()}
    }}
  });
  vm.runInContext(`window=globalThis;top=window;
    class HTMLMediaElement {constructor(){this.paused=true;this.ended=false}play(){this.paused=false;return Promise.resolve()}}
    class AudioBufferSourceNode {addEventListener(_,fn){this.end=fn}start(){setTimeout(()=>this.end(),1500)}}
    class XMLHttpRequest {
      addEventListener(_,fn){this.end=fn}
      send(){setTimeout(()=>{this.end();this.onload?.()},6000)}
    }
    let box={hidden:true,classList:{contains(){return box.hidden}}};
    document={getElementById(){return {contentDocument:{getElementById(){return box},querySelectorAll(){return []}}}}};
  `,context);
  vm.runInContext(script,context);
  return context;
}
function drain() {
  if(owner || !waiting.length)return;
  owner=waiting.shift();const item=owner;
  clock.push({at:now,order:++order,fn:()=>vm.runInContext(`__mcAlertQueue.grant(${item.seq})`,item.context)});
}
async function until(end) {
  while(true) {
    await Promise.resolve();await Promise.resolve();
    clock.sort((a,b)=>a.at-b.at||a.order-b.order);
    if(!clock.length || clock[0].at>end)break;
    const t=clock.shift();now=t.at;t.fn();
  }
  now=end;await Promise.resolve();
}
(async()=>{
  const se=page('streamelements.com'),sl=page('streamlabs.com'),don=page('doneru.jp');
  vm.runInContext(`
    const service={queue:[],playing:[],getQueue(){return this},isAnimating(id,on){this.playing=on?[id]:[]},
      push(){this.queue.push(1);setTimeout(()=>{this.queue.shift();this.isAnimating('a',true);new AudioBufferSourceNode().start();setTimeout(()=>this.isAnimating('a',false),700)},3000)}};
    const component={};component.eventQueueService=service;service.push('follower-latest',{});
  `,se);
  vm.runInContext(`
    class Widget {
      constructor(){this.alertQueue=[];this.sounds=[];this.audioPlayer={isPlaying:false,getQueueLength(){return 0}}}
      addAlertToQueue(){}
      onDisplay(type,event,settings){box.hidden=false;setTimeout(()=>box.hidden=true,settings.duration);this.playTTS()}
      playTTS(){setTimeout(()=>{const xhr=new XMLHttpRequest();xhr.onload=()=>{this.audioPlayer.isPlaying=true;setTimeout(()=>this.audioPlayer.isPlaying=false,2000)};xhr.send()},500)}
    }
    const widget=new Widget();widget.onDisplay('follow',{}, {duration:1000});
  `,sl);
  vm.runInContext(`class Alertbox {
    constructor(){this.resolver=null}push(){}clear(){}
    startEvent(){return new Promise(resolve=>setTimeout(resolve,400))}
  }const alerts=new Alertbox();alerts.startEvent();`,don);
  await until(3500);
  assert.equal(events.filter(e=>e[1]==='done').length,0,'SE asset loading must not finish early');
  await until(5000);
  assert.equal(events.filter(e=>e[1]==='done').length,1);
  assert.equal(owner.host,'streamlabs.com');
  await until(12000);
  assert.equal(owner.host,'streamlabs.com','pending TTS/audio holds global ownership');
  await until(15000);
  assert.deepEqual(events.filter(e=>e[1]==='done').map(e=>e[0]),['streamelements.com','streamlabs.com','doneru.jp']);
  assert.equal(owner,null);
  for(const [ctx,key] of [[se,'eventQueueService'],[sl,'alertQueue'],[don,'resolver']])
    assert.equal(vm.runInContext(`Object.hasOwn(Object.prototype,'${key}')`,ctx),false,'constructor trap restored');
  const unknown=page('example.invalid');await until(15001);
  assert(events.some(e=>e[0]==='example.invalid' && e[1]==='fault'));
  const pressure=page('doneru.jp');
  vm.runInContext(`
    const requests=[];mcAlertBridge.postMessage=raw=>{const e=JSON.parse(raw);if(e.type==='request')requests.push(e.sequence)};
    class Box {constructor(){this.resolver=null}push(){}clear(){}startEvent(){return Promise.resolve()}}
    const boxQueue=new Box();boxQueue.startEvent();boxQueue.startEvent();boxQueue.startEvent();
  `,pressure);
  assert.equal(vm.runInContext('requests.join()',pressure),'1');
  vm.runInContext('__mcAlertQueue.accepted(1);__mcAlertQueue.retry(2)',pressure);
  await until(16000);
  assert.equal(vm.runInContext('requests.join()',pressure),'1,2,2');
  vm.runInContext('__mcAlertQueue.accepted(2)',pressure);
  assert.equal(vm.runInContext('requests.join()',pressure),'1,2,2,3','capacity retry cannot reorder later notifications');
  await vm.runInContext('new HTMLMediaElement().play().then(()=>{throw Error("unowned audio played")},()=>{})',pressure);
  assert.equal(vm.runInContext('__mcAlertQueue.allowsMedia()',pressure),false);
  console.log('PASS: three-service FIFO, delayed assets/TTS, HTML/WebAudio guards, audio tail, capacity retry ordering, constructor restoration and unsupported host');
})().catch(error=>{console.error(error);process.exitCode=1});
