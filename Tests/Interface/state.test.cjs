// SPDX-License-Identifier: MIT
const test = require('node:test');
const assert = require('node:assert/strict');
const {BridgeState} = require('../../Resources/interface/keybridge.js');
const setup=()=>{const ui=new BridgeState();ui.update({state:{phase:'stopped',prepared:true,client:'managed',contextVersion:'A',auto:false,autoAvailable:true,hold:true}});return ui;};
function complete(ui,request,ok,message='',state={}){return ui.update({state,feedback:{id:request.id,action:request.action,ok,message}});}
test('A new window cannot claim work or license success before a native snapshot',()=>{
 const ui=new BridgeState();assert.equal(ui.state.phase,'loading');assert.equal(ui.state.prepared,false);assert.equal(ui.state.key,false);assert.equal(ui.state.proof,'none');
});
test('Unsupported or missing capability cannot request enabling or OS permission',()=>{
 const ui=new BridgeState();assert.equal(ui.request('autostart',true),null);assert.equal(ui.request('check-permission'),null);assert.equal(ui.state.pendingAuto,null);
 ui.update({state:{auto:true,permission:'allowed',autoAvailable:false}});assert.equal(ui.request('autostart',true),null);
 const request=ui.request('autostart',false);assert.ok(request);complete(ui,request,false,'Write failed');ui.update({state:{autoAvailable:false}});assert.equal(ui.autoError,'Write failed');assert.equal(ui.state.pendingAuto,false);
});
test('Losing capability cancels stale enable feedback and permission guidance',()=>{
 const ui=setup(),request=ui.request('autostart',true);ui.state.help='permission';
 ui.update({state:{autoAvailable:false}});assert.equal(ui.state.help,'');assert.equal(ui.state.pendingAuto,null);assert.equal(ui.autoWorking,false);
 complete(ui,request,true);assert.equal(ui.autoSaved,false);assert.equal(ui.state.auto,false);
});
test('Periodic observations preserve file wizard and nested navigation',()=>{
 const ui=setup();Object.assign(ui.state,{editing:true,replacing:true,setupStep:'driver',tab:'settings',help:'manual',detailTrail:['0','1'],navigation:[{kind:'detail'}]});
 ui.update({state:{phase:'stopped',tab:'main',help:'',setupStep:'installer',detailTrail:[],auto:true},files:{installer:{name:'another-version.run',valid:true}}});
 assert.equal(ui.state.setupStep,'driver');assert.equal(ui.state.help,'manual');assert.deepEqual(ui.state.detailTrail,['0','1']);assert.equal(ui.state.auto,true);assert.equal(ui.files.installer.name,'another-version.run');
});
test('Replacing an invalid component preserves the other selected component',()=>{
 const ui=setup();ui.update({files:{installer:{name:'platform.run',valid:true,validation:'preliminary',message:'Состав проверим при установке.'},driver:{name:'arm64.deb',error:'Нужен amd64',valid:false}}});
 assert.equal(ui.state.installer,true);assert.equal(ui.state.driver,false);
 ui.update({files:{driver:{name:'driver.deb',valid:true}}});assert.equal(ui.state.driver,true);assert.equal(ui.files.installer.name,'platform.run');assert.equal(ui.files.installer.validation,'preliminary');
});
test('Requesting an action changes no factual state; completion must carry facts',()=>{
 const ui=setup(),request=ui.request('start');assert.equal(ui.state.phase,'stopped');assert.equal(ui.state.want,false);assert.equal(ui.pending.size,1);
 ui.update({state:{phase:'starting',operationPending:true}});assert.equal(ui.pending.size,1);
 complete(ui,request,true,'',{phase:'ready',want:true,hold:false,key:true,operationPending:false});assert.equal(ui.pending.size,0);assert.equal(ui.state.phase,'ready');
});
test('Stop invalidates old preparation and probe completions',()=>{
 const ui=setup(),preparation=ui.request('prepare');const stop=ui.request('stop');
 assert.equal(complete(ui,preparation,true,'Prepared'),null);assert.equal(ui.pending.has(stop.id),true);assert.equal(ui.result('install'),'');
 complete(ui,stop,true,'Stopped',{phase:'stopped',hold:true,want:false});assert.equal(ui.result('stop'),'Stopped');
});
test('Unknown request IDs cannot change UI success or navigation',()=>{
 const ui=setup();ui.update({feedback:{id:'foreign',action:'monitor',ok:false,message:'Wrong'}});assert.equal(ui.state.help,'');assert.equal(ui.results.size,0);
});
test('Same completion is announced once, but later repeats have their own identity',()=>{
 const ui=setup(),a=ui.request('check-client');complete(ui,a,false,'Missing');const revision=ui.feedbackRevision;
 complete(ui,a,false,'Missing');assert.equal(ui.feedbackRevision,revision);
 const b=ui.request('check-client');complete(ui,b,false,'Missing');assert.equal(ui.feedbackRevision,revision+1);
});
test('An old negative key check cannot overwrite a new connection context',()=>{
 const ui=setup(),request=ui.request('check-key');
 complete(ui,request,false,'Ключ не обнаружен',{contextVersion:'B',phase:'ready',key:true});assert.equal(ui.result('key'),'');assert.equal(ui.state.key,true);
});
test('Context changes remove earlier negative observations without clearing the route',()=>{
 const ui=setup();ui.state.help='manual';const request=ui.request('check-key');complete(ui,request,false,'No key');assert.equal(ui.result('key'),'No key');
 ui.update({state:{contextVersion:'B',key:true,phase:'ready'}});assert.equal(ui.result('key'),'');assert.equal(ui.state.help,'manual');
});
test('Autostart failure preserves persisted choice and exposes pending choice',()=>{
 const ui=setup(),request=ui.request('autostart',true);assert.equal(ui.state.auto,false);assert.equal(ui.autoWorking,true);
 complete(ui,request,false,'Повторите сохранение.');assert.equal(ui.state.auto,false);assert.equal(ui.state.hold,true);assert.equal(ui.state.pendingAuto,true);assert.equal(ui.autoSaved,false);assert.equal(ui.autoWorking,false);
 const retry=ui.request('autostart',true);complete(ui,retry,true,'',{auto:true,hold:false});assert.equal(ui.state.pendingAuto,null);assert.equal(ui.autoSaved,true);assert.equal(ui.state.auto,true);assert.equal(ui.state.hold,false);
});
test('Cancelling failed autostart removes only the pending request',()=>{
 const ui=setup();ui.state.auto=true;const r=ui.request('autostart',true);complete(ui,r,false,'Write failed');ui.cancelAuto();
 assert.equal(ui.state.pendingAuto,null);assert.equal(ui.state.auto,true);assert.equal(ui.state.hold,true);assert.equal(ui.autoError,'');
});
test('An in-flight preference cannot be optimistically cancelled',()=>{
 const ui=setup();ui.request('autostart',true);ui.cancelAuto();assert.equal(ui.state.pendingAuto,true);assert.equal(ui.autoWorking,true);
});
test('Permissions changing invalidate the previous local permission error',()=>{
 const ui=setup(),r=ui.request('check-permission');complete(ui,r,false,'Denied');assert.equal(ui.result('permission'),'Denied');ui.update({state:{permission:'allowed'}});assert.equal(ui.result('permission'),'');
});
test('Sleep and lost state leave file editing and show native interruption',()=>{
 for(const phase of ['paused','unknown','reconciling']){const ui=setup();Object.assign(ui.state,{editing:true,replacing:true,setupStep:'review',tab:'settings',help:'manual'});ui.update({state:{phase}});assert.equal(ui.state.phase,phase);assert.equal(ui.state.editing,false);assert.equal(ui.state.tab,'main');assert.equal(ui.state.help,'');}
});
test('Successful new preparation leaves wizard; host owns current selection and stop',()=>{
 const ui=setup();Object.assign(ui.state,{editing:true,selected:'previous'});const r=ui.request('prepare');complete(ui,r,true,'',{phase:'stopped',selected:'current',hold:true});assert.equal(ui.state.editing,false);assert.equal(ui.state.selected,'current');assert.equal(ui.state.hold,true);
});
test('Repeated operation submission is coalesced; unknown bridge commands are rejected',()=>{
 const ui=setup();assert.ok(ui.request('probe'));assert.equal(ui.request('probe'),null);assert.equal(ui.request('exec','rm'),null);
});
test('Resource values come only from native observations; missing is not zero',()=>{
 const ui=setup();assert.deepEqual(ui.resourceRows,[]);ui.update({resourceRows:[{label:'Память Linux',value:'Нет измерения'},{label:'Предыдущая установка',value:'0 МиБ'}]});assert.equal(ui.resourceRows[0].value,'Нет измерения');assert.equal(ui.resourceRows[1].value,'0 МиБ');
});
test('A stale monitor failure is removed even from the manual-help return route',()=>{
 const ui=setup();ui.state.phase='ready';const r=ui.request('monitor');complete(ui,r,false,'No monitor');assert.equal(ui.state.help,'monitor-error');
 ui.state.navigation.push({kind:'help',view:{help:'monitor-error',diagnosing:false,detailTrail:[]}});ui.state.help='manual';ui.update({state:{phase:'waiting',key:false,contextVersion:'B'}});
 assert.equal(ui.state.help,'manual');assert.equal(ui.state.navigation.at(-1).view.help,'');assert.equal(ui.result('monitor'),'');
});
test('Hiding a window and opening an approved URL require no result bookkeeping',()=>{
 const ui=setup();assert.ok(ui.request('hide'));assert.ok(ui.request('open-url','https://releases.1c.ru/project/Platform85'));assert.equal(ui.pending.size,0);
});
test('Stop cancels an in-flight UI preference without inventing a saved value',()=>{
 const ui=setup(),a=ui.request('autostart',true);ui.request('stop');assert.equal(ui.autoWorking,false);assert.equal(ui.state.pendingAuto,null);assert.equal(ui.state.auto,false);complete(ui,a,true);assert.equal(ui.autoSaved,false);
});
