// SPDX-License-Identifier: MIT
// Native observations are the source of truth. This store owns only navigation,
// pending UI requests and feedback; it never starts a VM or fabricates a result.
(function (global) {
'use strict';
const initial = {phase:'loading',tab:'main',prepared:false,client:'unknown',clientRestored:false,key:false,want:false,hold:false,auto:false,autoAvailable:false,permission:'unknown',proof:'none',saved:true,selected:'current',step:0,updated:false,previousAvailable:false,updateProblem:false,previousValid:false,backupAvailable:false,pendingQuit:false,pendingAuto:null,errorMessage:'',accessError:null,safetyBlock:null,contextVersion:'',operationPending:false,installationOpen:false,help:'',setupStep:'installer',diagnosing:false,detailTrail:[],navigation:[],editing:false,replacing:false,reviewSettings:false,dismissedError:null};
const localKeys=new Set(['tab','help','setupStep','diagnosing','detailTrail','navigation','installationOpen','editing','replacing','reviewSettings','dismissedError','pendingAuto']);
const domainKeys=Object.keys(initial).filter(k=>!localKeys.has(k));
const scopes={'check-key':'key','check-space':'space','check-permission':'permission','check-client':'client',recheck:'safety',stop:'stop',quit:'stop',prepare:'install',monitor:'monitor',configure:'config',repair:'config',restore:'config',rollback:'config',measure:'resources'};
const commands=new Set(['installer','driver','prepare','start','stop','quit','configure','repair','restore','rollback','probe','monitor','check-key','check-client','check-space','recheck','check-permission','measure','autostart','open-url','hide']);
const emptyFile=()=>({name:'',valid:false,checking:false,error:'',message:'',validation:''});
class BridgeState {
 constructor(){this.state={...initial,detailTrail:[],navigation:[]};this.files={installer:emptyFile(),driver:emptyFile()};this.keyLabel='';this.componentLabel='';this.proofTime='';this.resourceRows=[];this.resourcesNote='';this.results=new Map();this.pending=new Map();this.seen=new Set();this.sequence=0;this.epoch=0;this.autoSaved=false;this.autoError='';this.autoWorking=false;this.feedbackRevision=0;}
 signature(scope){const s=this.state;const values={key:[s.key,s.phase,s.contextVersion],space:[s.fault,s.contextVersion],permission:[s.permission,s.autoAvailable],client:[s.client],install:[s.phase,this.files.installer.name,this.files.driver.name],stop:[s.phase,s.saved,s.hold],safety:[s.phase,s.safetyBlock,s.key,s.contextVersion],config:[s.client,s.phase,s.accessError,s.hold],monitor:[s.phase,s.contextVersion],resources:[s.contextVersion]};return JSON.stringify(values[scope]||[]);}
 result(scope){const item=this.results.get(scope);if(item&&item.signature===this.signature(scope))return item.text;this.results.delete(scope);return '';}
 record(scope,text){if(scope&&text)this.results.set(scope,{text:String(text),signature:this.signature(scope)});}
 clearResults(){this.results.clear();this.autoSaved=false;}
 request(action,value){
  if(!commands.has(action))return null;
  if(!this.state.autoAvailable&&((action==='autostart'&&value===true)||action==='check-permission'))return null;
  const duplicate=[...this.pending.values()].find(p=>p.action===action);
  if(duplicate&&action!=='open-url'&&action!=='hide')return null;
  if(action==='stop'||action==='quit'){this.epoch++;this.pending.clear();this.autoWorking=false;this.state.pendingAuto=null;this.autoError='';this.clearResults();}
  else if(['prepare','start','configure','repair','restore','rollback','probe'].includes(action))this.clearResults();
  const id=(global.crypto?.randomUUID?.()||('ui-'+Date.now().toString(36)+'-'+(++this.sequence))) ;
  const req={id,action,...(value===undefined?{}:{value})};
  if(!['hide','open-url'].includes(action))this.pending.set(id,{...req,epoch:this.epoch,context:this.state.contextVersion,signature:this.signature(scopes[action])});
  if(scopes[action])this.record(scopes[action],action==='stop'||action==='quit'?'Сохраняем выключение…':action==='monitor'?'Открываем монитор…':'Проверяем…');
  if(action==='autostart'){this.state.pendingAuto=!!value;this.autoWorking=true;this.autoSaved=false;this.autoError='';}
  return req;
 }
 cancelAuto(){if(this.autoWorking)return;this.state.pendingAuto=null;this.autoError='';this.autoSaved=false;}
 update(payload={}){
  const oldPhase=this.state.phase,oldContext=this.state.contextVersion,oldAutoAvailable=this.state.autoAvailable;
  for(const k of domainKeys)if(Object.prototype.hasOwnProperty.call(payload.state||{},k))this.state[k]=payload.state[k];
  if(!this.state.autoAvailable){
   for(const [id,request] of this.pending)if((request.action==='autostart'&&request.value===true)||request.action==='check-permission')this.pending.delete(id);
   if(this.state.pendingAuto===true){this.state.pendingAuto=null;this.autoWorking=false;}
   if(oldAutoAvailable){this.autoSaved=false;this.autoError='';}
   if(this.state.help==='permission')this.state.help='';
   this.state.navigation=this.state.navigation.map(entry=>entry.view?.help==='permission'?{...entry,view:{...entry.view,help:''}}:entry);
  }
  if(payload.state&&Object.prototype.hasOwnProperty.call(payload.state,'fault'))this.state.fault=payload.state.fault;
  if(payload.state&&Object.prototype.hasOwnProperty.call(payload.state,'resumeReason'))this.state.resumeReason=payload.state.resumeReason;
  for(const kind of ['installer','driver'])if(payload.files?.[kind])this.files[kind]={...emptyFile(),...payload.files[kind]};
  for(const key of ['keyLabel','componentLabel','proofTime','resourcesNote'])if(typeof payload[key]==='string')this[key]=payload[key];
  if(Array.isArray(payload.resourceRows))this.resourceRows=payload.resourceRows.filter(r=>r&&typeof r.label==='string'&&typeof r.value==='string');
  this.state.installer=!!this.files.installer.valid;this.state.driver=!!this.files.driver.valid;
  if(oldContext!==this.state.contextVersion||oldPhase!==this.state.phase){
   if(oldContext!==this.state.contextVersion)this.results.clear();
   if(this.state.help==='monitor-error')this.state.help='';
   this.state.navigation=this.state.navigation.map(entry=>entry.view?.help==='monitor-error'?{...entry,view:{...entry.view,help:''}}:entry);
  }
  const interrupted=['unknown','unsafe','multiple','paused','reconciling','stopping'];
  if(oldPhase!==this.state.phase&&interrupted.includes(this.state.phase)){this.state.editing=false;this.state.reviewSettings=false;this.state.dismissedError=null;this.state.tab='main';this.clearRoute();}
  if(this.state.errorMessage==='')this.state.dismissedError=null;
  let feedback=payload.feedback,accepted=null;
  if(feedback?.id&&!this.seen.has(feedback.id)){
   this.seen.add(feedback.id);if(this.seen.size>200)this.seen.delete(this.seen.values().next().value);
   const request=this.pending.get(feedback.id);this.pending.delete(feedback.id);
   if(request&&request.epoch===this.epoch&&!(!feedback.ok&&['check-key','check-client','recheck','measure','monitor'].includes(request.action)&&(request.context!==this.state.contextVersion||request.signature!==this.signature(scopes[request.action])))){
    accepted={...feedback,action:request.action};this.feedbackRevision++;
    const message=String(feedback.message||'');
    if(request.action==='autostart'){
     this.autoWorking=false;
     if(feedback.ok){this.state.pendingAuto=null;this.autoError='';this.autoSaved=true;}
     else this.autoError=message||'Не удалось сохранить выбор. Повторите сохранение или отмените изменение.';
    }else if(request.action==='monitor'){
     if(feedback.ok){if(this.state.help==='monitor-error'){this.state.help='';this.state.navigation=this.state.navigation.filter(n=>n.view?.help!=='monitor-error');}this.record('monitor',message||'Монитор лицензий открыт.');}
     else {this.state.navigation.push({kind:'help',view:{help:this.state.help,diagnosing:this.state.diagnosing,detailTrail:[...this.state.detailTrail]}});this.state.help='monitor-error';this.record('monitor',message);}
    }else if(request.action==='prepare'){
     this.state.editing=false;this.state.replacing=false;this.state.tab='main';this.clearRoute();this.record('install',message);
    }else if(['configure','repair','restore','rollback'].includes(request.action)){
     this.state.reviewSettings=false;this.state.tab='main';this.clearRoute();this.record('config',message);
    }else if(scopes[request.action])this.record(scopes[request.action],message);
   }
  }
  // An ordinary status refresh must never reset a selected file, wizard step,
  // nested help page, pending autostart preference or the user's scroll route.
  if(oldPhase!==this.state.phase&&oldPhase==='preparing'&&this.state.phase==='stopped'){this.state.editing=false;this.state.replacing=false;this.clearRoute();}
  return accepted;
 }
 clearRoute(){this.state.help='';this.state.diagnosing=false;this.state.detailTrail=[];this.state.navigation=[];}
 navigate(tab){this.clearRoute();this.state.tab=tab==='settings'?'settings':'main';this.state.diagnosing=tab==='diagnosis';}
 view(){return {...this.state};}
}
if(typeof module!=='undefined'&&module.exports)module.exports={BridgeState,initial,commands};
if(typeof document==='undefined')return;
const model=new BridgeState();
const root=document.getElementById('keybridge-app'),content=root.querySelector('#kb-content'),dock=root.querySelector('#kb-dock'),panel=root.querySelector('.kb-footer'),backSlot=root.querySelector('#kb-back');
let s=model.state,rememberedFocus=null,pendingReturn=null,lastScreen='';
const e=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const result=scope=>e(model.result(scope));
const busy=()=>[...model.pending.values()].some(p=>['prepare','start','stop','quit','configure','repair','restore','rollback','probe'].includes(p.action))||s.operationPending||['loading','preparing','starting','probing','stopping','recovering','configuring','restoring','restoring-version','reconciling'].includes(s.phase);
const active=()=>['ready','starting','waiting','probing','recovering','paused','reconciling'].includes(s.phase);
const pendingAction=action=>[...model.pending.values()].some(p=>p.action===action);
const button=(text,action,primary=false,disabled=false,label='')=>`<button class="${primary?'kb-primary':'kb-secondary'}" data-action="${action}" ${label?`aria-label="${e(label)}"`:''} ${disabled?'disabled':''} ${pendingAction(action)?'aria-disabled="true" aria-busy="true"':''}>${e(text)}</button>`;
const row=(name,value,caption='')=>`<div class="kb-row"><div><strong>${e(name)}</strong>${caption?`<small>${e(caption)}</small>`:''}</div><span class="kb-value">${value}</span></div>`;
function clearResults(){model.clearResults();}
function clearRoute(){model.clearRoute();pendingReturn=null;}
function send(action,value){
 const message=model.request(action,value);if(!message)return;
 try{if(!global.webkit?.messageHandlers?.keybridge)throw new Error('bridge');global.webkit.messageHandlers.keybridge.postMessage(message);}
 catch{model.update({state:{phase:'unknown',errorMessage:'Не удалось связаться с приложением. Закройте и снова откройте KeyBridge.'},feedback:{id:message.id,action,ok:false,message:'Не удалось связаться с приложением. Закройте и снова откройте KeyBridge.'}});}
 render();
}
function lead(title,body,tone=''){return `<div class="kb-lead"><h2 class="kb-state-title"><span class="kb-dot ${tone}" aria-hidden="true"></span>${title}</h2><p>${body}</p></div>`;}
function proof(){
 const values={none:['Проверьте лицензию в 1С','Проверка ещё не запускалась.'],success:['1С получила лицензию','Проверка подтвердила получение лицензии от этого USB-ключа через KeyBridge.'],unconfirmed:['Получение лицензии не подтверждено','1С выполнила проверку, но её результат не позволяет определить, получена ли лицензия от этого USB-ключа через KeyBridge.'],failure:['1С не завершила проверку','Проверочное приложение завершилось с ошибкой. Её причину пока не удалось установить. KeyBridge продолжает работать.'],timeout:['Проверка не завершилась','1С не ответила за время ожидания. Почему она не ответила, пока неизвестно. KeyBridge продолжает работать.'],stale:['Проверьте лицензию ещё раз','После изменений в работе KeyBridge прежний результат проверки больше не подтверждает получение лицензии.']};
 const [title,body]=s.phase==='probing'?['Проверяем лицензию в 1С','1С выполняет проверку. Результата пока нет.']:(values[s.proof]||values.none);
 const problem=['unconfirmed','failure','timeout'].includes(s.proof)&&s.phase!=='probing';
 const needsSource=s.proof==='unconfirmed'&&s.phase!=='probing';
 let probeButton=button('Проверить в 1С','probe',!needsSource,!s.key||busy()&&s.phase!=='probing').replace('<button','<button aria-describedby="kb-probe-explain"'+(s.phase==='probing'?' aria-disabled="true" aria-busy="true"':''));
 return `<section class="kb-proof"><div><div class="kb-proof-result"><h3 class="${s.proof==='success'&&s.phase!=='probing'?'kb-green':''}">${title}</h3><p>${body}</p>${s.proof!=='none'?'<p class="kb-meta">Результат проверки'+(model.proofTime?' · '+e(model.proofTime):'')+'</p>':''}</div><div class="kb-proof-control">${probeButton}<p id="kb-probe-explain" class="kb-explain">Откроется пустая база.</p></div></div>${problem?'<section class="kb-manual-check">'+(needsSource?'<h3>Теперь посмотрите лицензию в своей базе</h3><p>Это поможет выяснить, какую лицензию использует ваша 1С.</p>':'<p>Можно также проверить лицензию в своей рабочей базе 1С.</p>')+'<div class="kb-actions">'+button('Как проверить в своей базе','manual-license',needsSource)+'</div>'+(needsSource?'<p class="kb-explain">Повторите проверку после изменения настроек поиска лицензии или подключения ключа. Без изменений результат может остаться прежним.</p>':'')+'</section>':''}${s.updateProblem?'<p class="kb-explain">Если проблема появилась после обновления, выключите KeyBridge — можно будет вернуть предыдущую версию.</p>':''}</section>`;
}
function fileChoice(kind){
 const installer=kind==='installer',file=model.files[kind],selected=!!file.valid,invalid=!!file.error,name=installer?'Установщик 1С':'Драйвер HASP';
 const example=installer?'setup-full-…-x86_64.run':'aksusbd_…_amd64.deb';
 const source=installer?'1С':'Thales',url=installer?'https://releases.1c.ru/project/Platform85':'https://supportportal.thalesgroup.com/csm?_runtime_packages=&amp;id=kb_search&amp;query=kbcat_drivers_%26_runtime_packages&amp;u_products_available_in_portal_search=50303b92db852e00d298728dae96199d';
 const instruction=installer?'Потребуется учётная запись 1С. Скачайте полную поставку для Linux x86-64 с менеджером лицензий — файл .run. Версия может отличаться; KeyBridge проверит состав файла.':'Выберите Sentinel LDK Run-time для Linux: Debian/Ubuntu, 64-bit Intel (amd64), пакет DEB. Если скачался архив, распакуйте его и найдите файл aksusbd_…_amd64.deb. Версия может отличаться.';
 const pick=button((file.name?'Заменить ':'Выбрать ')+(installer?'установщик…':'драйвер…'),kind,false,file.checking||pendingAction(kind),(file.name?'Заменить ':'Выбрать ')+(installer?'установщик 1С':'драйвер HASP')).replace('<button',`<button id="kb-pick-${kind}"`);
 const status=file.checking?'Проверяем файл…':file.error||file.message||(selected?'Файл выбран':'Файл ещё не выбран');
 return `<section class="kb-file-choice"><div class="kb-file-heading"><strong>${name}</strong><a class="kb-download" href="${url}">Скачать с сайта ${source} ↗</a></div><p class="kb-file-instruction">${instruction}</p><div class="kb-row kb-file-row"><div><small title="${e(file.name)}">${e(file.name||('Пример имени: '+example))}</small><small class="kb-file-status ${selected?'kb-green':''}" ${invalid?'role="alert"':''}>${e(status)}</small></div>${pick}</div></section>`;
}
function first(){
 const step=['installer','driver','review'].includes(s.setupStep)?s.setupStep:'installer',number=step==='installer'?1:step==='driver'?2:3;
 const titles={installer:'Выберите установщик 1С',driver:'Выберите драйвер USB-ключа',review:'Проверьте файлы перед установкой'};
 const intro={installer:'Сначала выберите два файла и установите программы для ключа. Затем настроим поиск лицензии в 1С на этом Mac.',driver:'Установщик 1С уже выбран. Добавьте драйвер USB-ключа.',review:s.client==='managed'?'KeyBridge установит программы из выбранных файлов. Сохранённые настройки поиска лицензии в 1С останутся.':'KeyBridge установит программы из выбранных файлов. После установки останется настроить поиск лицензии в 1С — для этого понадобится разрешение macOS.'};
 let body=`<div class="kb-lead"><h2>${titles[step]}</h2><p>${intro[step]}</p><p class="kb-setup-progress">Подготовка файлов: шаг ${number} из 3</p></div>`;
 if(s.fault==='space')return issue('Установка не началась: не хватает места','На Mac недостаточно свободного места для установки выбранных программ.','Освободите место, затем нажмите «Проверить место». После проверки можно будет продолжить выбор файлов.',button('Как освободить место','storage-help')+button('Проверить место','check-space',true)+(s.replacing?button('Отмена','back',false,false,'Отменить переустановку'):''),'space');
 if(step==='installer')body+=`${fileChoice('installer')}<div class="kb-actions">${button('Продолжить','setup-next',true,!s.installer)}</div>`;
 else if(step==='driver')body+=`${fileChoice('driver')}<div class="kb-actions">${button('Продолжить','setup-next',true,!s.driver)}${button('Назад','setup-back')}</div>`;
 else body+=`${row('Установщик 1С',s.installer?(model.files.installer.validation==='preliminary'?'Формат подходит':'Проверен'):'Не проверен',model.files.installer.name)}${row('Драйвер HASP',s.driver?(model.files.driver.validation==='preliminary'?'Формат подходит':'Проверен'):'Не проверен',model.files.driver.name)}<div class="kb-actions">${button('Изменить файлы','edit-installer')}${button('Установить программы','prepare',true,busy()||!s.installer||!s.driver)}${button('Назад','setup-back')}</div><p class="kb-explain">На этом шаге KeyBridge ещё не использует USB-ключ.</p>`;
 if(s.replacing)body+=`<div class="kb-actions">${button('Отмена','back',false,false,'Отменить переустановку')}</div>`;
 return body;
}
function operation(){const texts={preparing:['Устанавливаем программы для ключа',s.replacing?'Прежняя установка сохранится.':'Устанавливаем выбранные файлы. USB-ключ пока не используется.'],starting:['Включаем KeyBridge','Проверяем программы для ключа и его подключение.'],probing:['Проверяем лицензию в 1С','1С выполняет проверку. Результата пока нет.'],stopping:['Выключаем KeyBridge','Освобождаем USB-ключ. Дождитесь подтверждения.'],recovering:['Восстанавливаем работу','KeyBridge потерял связь с программой для выдачи лицензий. Причина пока неизвестна. Пробуем восстановить работу; вы можете выключить KeyBridge.'],configuring:['Разрешите изменить поиск лицензии','macOS запросит разрешение на изменение настроек поиска лицензии. Базы и конфигурации 1С не изменятся.'],restoring:['Нужно разрешение macOS','Разрешите вернуть настройки поиска лицензии в 1С. Базы и конфигурации не изменятся.'],'restoring-version':['Возвращаем предыдущую версию','Возвращаем программы, которые использовались до обновления. После возврата можно включить KeyBridge.']};const [title,body]=texts[s.phase];let extra='';if(s.phase==='preparing'){extra=`<ol class="kb-steps">${['Копируем файлы','Устанавливаем и настраиваем','Проверяем установку'].map((x,i)=>`<li class="${i<s.step?'done':i===s.step?'current':''}">${x}</li>`).join('')}</ol>`;}else if(s.phase==='recovering'){extra=`<p class="kb-explain">Автоматические попытки ограничены. Если они закончатся без результата, появятся действия для исправления.</p>`;}else if(s.phase==='probing')extra=`${row('KeyBridge','Продолжает работать')}${row('Проверка в 1С','Ещё не завершена')}`;return lead(title,body,'blue')+extra;}
function main(){
 if(s.phase==='loading')return lead('Проверяем состояние KeyBridge','Получаем сведения о программах и подключении ключа.','blue');
 if(s.phase==='unknown')return issue('Не удалось проверить работу KeyBridge','KeyBridge не получил ответ о работе с USB-ключом. Поэтому неизвестно, освобождён ли ключ; повторное включение заблокировано.','Повторите проверку или попробуйте выключить KeyBridge. Если ответа снова нет, сохраните работу в других программах, перезагрузите Mac и откройте KeyBridge заново.',button('Проверить состояние','recheck',true)+button('Выключить','stop'),'safety');
 if((s.editing&&!busy()&&!active())||s.phase==='first')return first();
 if(s.phase==='paused')return lead('Работа приостановлена','Mac перешёл в сон. После пробуждения KeyBridge проверит подключение и учтёт сохранённое выключение. Прежняя проверка лицензии больше не подтверждает текущую работу.');
 if(s.phase==='reconciling')return lead('Проверяем состояние KeyBridge',s.resumeReason==='restart'?'KeyBridge перезапустился. Проверяем, продолжилась ли работа с ключом. Прежние показания пока не подтверждены.':s.resumeReason==='login'?'Проверяем подключение и условия автозапуска. Сохранённое выключение имеет приоритет.':'Mac вышел из сна. Проверяем подключение перед возобновлением работы. Прежняя проверка лицензии больше не актуальна.','blue');
 if(s.phase==='rollback-error')return issue('Предыдущая версия недоступна','Не удалось прочитать файлы предыдущей установки. Переключение не выполнено; текущая установка сохранена.','Восстановите файлы из резервной копии и повторите возврат. Можно также переустановить программы из своих файлов или включить текущую установку.',button('Включить','start')+button('Переустановить…','replace')+button('Повторить возврат','rollback',true));
 if(s.phase==='restore-error')return issue('Не удалось вернуть настройки 1С',s.backupAvailable?'Возврат настроек не завершён. Причину пока не удалось определить.':'Сохранённая копия прежних настроек не найдена. Текущие настройки 1С не изменены.','Восстановите копию настроек KeyBridge из резервной копии Mac и повторите возврат. Если копии нет, вернитесь назад: работу с KeyBridge можно продолжить.',button('Повторить возврат','restore',true)+button('Назад','restore-back'));
 if(busy()&&s.phase!=='probing')return operation();
 if(['install-error','start-error'].includes(s.phase))return issue(s.phase==='install-error'?'Установка прервалась':'KeyBridge не включился',s.phase==='install-error'?'Установщик завершился с ошибкой. По имеющимся данным её причину определить не удалось.':'Программа для выдачи лицензий не ответила при запуске. Причина отсутствия ответа пока неизвестна.',s.phase==='install-error'?'Повторите установку. Если она снова прервётся, выберите другие установочные файлы.':'Повторите включение. Если ошибка повторится, переустановите программы для ключа.',s.phase==='install-error'?button('Повторить установку','retry-install',true)+button('Выбрать другие файлы','replace'):button('Включить','start',true)+(s.previousAvailable?button('Вернуть предыдущую версию','rollback'):'')+button('Переустановить…','replace'),'install');
 if(s.client==='missing')return issue('1С на этом Mac не найдена','KeyBridge не обнаружил клиентское приложение 1С для macOS. Установщик 1С для Linux, выбранный ранее, его не заменяет.','Установите клиент 1С для macOS из своего дистрибутива, затем нажмите «Проверить наличие 1С».',button('Как установить 1С','client-help')+button('Проверить наличие 1С','check-client',true),'client');
 if(s.reviewSettings)return lead('Изменить поиск лицензии в 1С?','1С будет искать лицензию через KeyBridge. Это может изменить получение лицензий от других источников.')+`<p>Текущие настройки будут сохранены перед изменением. Позже их можно вернуть в дополнительных действиях.</p><div class="kb-actions">${button('Настроить поиск лицензии','configure',true)}${button('Отмена','cancel-settings')}</div>`;
 if(s.accessError&&s.dismissedError!==s.accessError)return issue('macOS не разрешила изменить настройки 1С','Запрос разрешения был отклонён. Настройки поиска лицензии остались прежними.','Повторите запрос и разрешите изменение в окне macOS. Если разрешения нет, отмените настройку и обратитесь к администратору этого Mac.',button('Запросить разрешение снова','retry-access',true)+button('Отменить настройку','dismiss-access'));
 if(s.client==='unknown')return issue('Не удалось проверить настройки 1С','Приложение не подтвердило, как настроен поиск лицензии.','Повторите проверку. Если ошибка повторится, откройте клиент 1С и убедитесь, что он установлен на этом Mac.',button('Проверить наличие 1С','check-client',true),'client');
 if(s.client==='unconfigured')return lead('Настройте поиск лицензии в 1С',result('config')||'Программы для ключа установлены. Осталось разрешить 1С искать лицензию через KeyBridge. Базы и конфигурации не изменятся.')+`<div class="kb-actions">${button('Настроить поиск лицензии','configure',true)}</div><p class="kb-explain">Это нужно сделать один раз. macOS запросит разрешение. После настройки можно будет включить KeyBridge.</p>`;
 if(s.client==='external')return clientConflict();

 if(s.phase==='unsafe')return issue('Ключ не подключён к KeyBridge','Не удалось подтвердить запрет обновления прошивки ключа. Без этой проверки KeyBridge не подключает ключ. Причина сбоя проверки пока неизвестна.','Переподключите USB-ключ к Mac и проверьте защиту снова. Если проверка снова не пройдёт, переустановите программы для ключа.',button('Проверить защиту','recheck',true)+button('Переустановить…','replace'),'safety');
 if(s.phase==='multiple')return issue('Подключено несколько ключей HASP','KeyBridge не может определить, какой из них использовать, поэтому не подключает ни один.','Оставьте подключённым один ключ HASP, затем нажмите «Проверить подключение».',button('Проверить подключение','recheck',true),'safety');
 if(s.phase==='exhausted')return issue('Не удалось восстановить работу','Программа для выдачи лицензий не ответила после повторных запусков. Автоматические попытки закончились.','Попробуйте включить KeyBridge вручную. Если ошибка повторится, переустановите программы для ключа.',button('Включить','start',true)+(s.previousAvailable?button('Вернуть предыдущую версию','rollback'):'')+button('Переустановить…','replace'));
 if(s.phase==='waiting')return lead('Подключите USB-ключ HASP','KeyBridge не обнаружил подключённый ключ. Вставьте один ключ в USB-разъём этого Mac. Если он уже подключён, отсоедините и подключите его снова.','amber')+`${row('KeyBridge','Включён')}<div data-result-scope="key">${row('USB-ключ',result('key')||'Не найден')}</div><div class="kb-actions">${button('Проверить подключение','check-key',true)}</div>`;
 if(s.phase==='update-error'||(s.phase==='stopped'&&s.updateProblem&&s.previousAvailable))return issue('После обновления KeyBridge не заработал','Новая установка не прошла запуск или проверку лицензии. Точную причину по этим данным определить нельзя. KeyBridge сейчас выключен.','Верните предыдущую версию или повторите включение. После возврата включите KeyBridge и проверьте лицензию в 1С.',button('Вернуть предыдущую версию','rollback',true)+button('Включить','start'));
 if(s.phase==='stopped'&&!s.saved)return issue('KeyBridge выключен, но запрет запуска не сохранён','Не удалось записать настройку «выключено». Причина ошибки записи пока неизвестна. При следующем запуске KeyBridge может снова включиться.','Нажмите «Сохранить выключение». Если запись снова не удастся, проверьте свободное место на Mac и повторите сохранение. До сохранения запрета не запускайте KeyBridge заново.',button('Сохранить выключение','save-stop',true)+button('Как освободить место','storage-help'),'stop');
 if(s.phase==='stopped')return lead('KeyBridge выключен',result('config')||(s.hold?'KeyBridge больше не использует USB-ключ и не включится сам, пока вы снова не разрешите запуск.':'Всё установлено. Включите KeyBridge, чтобы 1С могла обратиться к USB-ключу.'))+`<div class="kb-actions">${button('Включить','start',true,s.client!=='managed')}</div>`;
 if(s.diagnosing)return lead('Помощь с лицензией 1С','Если 1С не получает лицензию, проверьте её подключение к KeyBridge. Работа с USB-ключом продолжается.')+proof()+`<div class="kb-actions">${button('Вернуться к ключу','close-diagnosis')}</div>`;
 if(!['ready','probing'].includes(s.phase))return issue('Не удалось проверить работу KeyBridge','Состояние работы пока не подтверждено.','Повторите проверку состояния. До её завершения включение недоступно.',button('Проверить состояние','recheck',true),'safety');
 return lead('KeyBridge работает',result('monitor')||'USB-ключ подключён.','green')+row('USB-ключ',e(model.keyLabel||'Подключён'))+`<div class="kb-actions">${button('Посмотреть занятые лицензии','monitor',true)}</div><div class="kb-status-line"><button class="kb-link" data-action="diagnose">1С не получает лицензию</button></div>`;
}
function installation(){const locked=active()||busy()||s.phase==='unknown';return `<details class="kb-installation kb-details" ${s.installationOpen?'open':''}><summary>Дополнительные действия</summary><div class="kb-installation-body"><div class="kb-row"><div><strong>Программы для ключа</strong><small>${s.prepared?e(model.componentLabel||'Программы установлены'):'Ещё не установлены'}</small></div>${button(s.prepared?'Переустановить…':'Установить…',s.prepared?'replace':'open-install',false,locked)}</div><p class="kb-explain">Если нужно выбрать другой установщик 1С или драйвер ключа. Сначала выключите KeyBridge.</p><div class="kb-row"><div><strong>Прежние настройки 1С</strong><small>${s.clientRestored?'Прежний поиск лицензии восстановлен.':'Вернуть поиск лицензии, который был до KeyBridge.'}</small></div>${button('Вернуть настройки…','restore',false,locked||s.client!=='managed')}</div><p class="kb-explain">${s.clientRestored?'1С больше не ищет лицензию через KeyBridge. Базы и конфигурации не изменены.':'1С перестанет искать лицензию через KeyBridge. Базы и конфигурации 1С не изменятся.'}</p>${resourceDetails()}</div></details>`;}
function resourceDetails(){
 const rows=model.resourceRows.length?model.resourceRows:[{label:'Память для работы с ключом',value:'Нет данных'},{label:'Время замера',value:'Измерение не проводилось'}];
 return `<details class="kb-details"><summary>Технические сведения</summary><dl class="kb-resource-list">${rows.map(r=>`<dt>${e(r.label)}</dt><dd>${e(r.value)}</dd>`).join('')}</dl>${button('Измерить','measure',false,busy()||pendingAction('measure'))}<p class="kb-explain" data-result-scope="resources">${result('resources')||e(model.resourcesNote||'Физически занятое место на Mac и виртуальная ёмкость диска — разные величины. Память Linux и процесса на Mac измеряются отдельно.')}</p></details>`;
}
function issue(title,cause,remedy,actions,scope=''){return `<section class="kb-issue" ${scope?`data-result-scope="${scope}"`:''}>${lead(title,result(scope)||(!s.help&&s.errorMessage&&(!s.accessError||s.dismissedError!==s.accessError)?e(s.errorMessage):cause),'amber')}<p class="kb-issue-remedy">${remedy}</p><div class="kb-actions">${actions}</div></section>`;}
function helpNotice(title,body,actions,download=''){return `<section class="kb-help"><h3>${title}</h3><p>${body}</p>${download}<div class="kb-actions">${actions}</div></section>`;}
function help(){
 if(s.help==='manual')return `<section class="kb-help"><h2>Посмотрите лицензию в своей базе 1С</h2><ol class="kb-guide"><li>Откройте свою рабочую базу в приложении 1С.</li><li>В меню окна 1С выберите <strong>«Сервис и настройки» → «О программе»</strong>. В старом интерфейсе — «Справка» → «О программе».</li><li>Откройте страницу <strong>«Лицензия»</strong>. Если отдельной страницы нет, найдите раздел «Лицензия» и строку <strong>«Текущая»</strong>. Смотрите клиентскую лицензию, которую 1С использует сейчас.</li></ol><section class="kb-help-section"><h3>Что означает запись</h3><p>Например, «Сетевой HASP …» означает получение лицензии от сетевого USB-ключа. Регистрационный номер и путь к файлу — локальную программную лицензию. «Выдал сервер» означает выдачу сервером 1С. Вид записи зависит от версии 1С.</p><p class="kb-explain">Надпись HASP сама по себе не подтверждает получение через KeyBridge. Результат проверки в KeyBridge от чтения этой записи не изменится.</p></section><section class="kb-help-section"><h3>Если запись непонятна или база не открывается</h3><p>Обратитесь к специалисту, который настраивает вашу 1С. Сообщите запись о текущей клиентской лицензии или текст сообщения при открытии базы. Попросите проверить поиск лицензии от USB-ключа через KeyBridge.</p></section><div class="kb-actions">${button('Назад','close-help')}</div></section>`;
 if(s.help==='permission')return helpNotice('Фоновая работа KeyBridge','В настройках macOS откройте «Основные» → «Объекты входа» и разрешите KeyBridge работать в фоне. Название раздела может отличаться в вашей версии macOS.',button('Проверить разрешение','check-permission',true)+button('Назад','close-help'))+permissionDetails();
 if(s.help==='monitor-error')return issue('Не удалось открыть монитор лицензий','Приложение 1С не подтвердило запуск монитора. Причина пока неизвестна. Работа KeyBridge продолжается.','Повторите открытие. Если монитор снова не откроется, проверьте лицензию в своей базе 1С.',button('Открыть монитор ещё раз','monitor',true)+button('Как проверить в своей базе','manual-license')+button('Назад','close-help'),'monitor');
 const pages={storage:['Освободите место на Mac','Откройте настройки macOS → «Основные» → «Хранилище». Перенесите ненужные файлы на другой диск или удалите их самостоятельно. Вернитесь в KeyBridge и повторите проверку места или сохранение настройки. KeyBridge сам ничего не удаляет.'],client:['Установите клиент 1С для macOS','Используйте дистрибутив клиента 1С для macOS, полученный в вашей организации или на портале обновлений 1С. После установки вернитесь и нажмите «Проверить наличие 1С». Файл .run для Linux предназначен для другой части KeyBridge.']};
 let out='';if(s.help&&pages[s.help]){const [title,body]=pages[s.help];const download=s.help==='client'?'<a class="kb-download" href="https://releases.1c.ru/project/Platform85" target="_blank" rel="noopener noreferrer">Скачать с сайта 1С ↗</a>':'';out=helpNotice(title,body,button('Закрыть пояснение','close-help'),download);}
 return out;
}
function clientConflict(){return lead('Настройки поиска лицензии изменились','Текущие настройки 1С отличаются от сохранённых KeyBridge. Поэтому прежняя настройка подключения больше не подтверждена.','amber')+`<p>Почему настройки изменились, определить не удалось. Чтобы настроить поиск лицензии через KeyBridge заново, нажмите «Исправить настройки».</p><div class="kb-actions">${button('Исправить настройки','review-settings',true)}</div>`;}
function autoExplanation(){
 if(model.autoWorking)return 'Сохраняем выбор… Текущая работа KeyBridge не меняется.';
 if(s.pendingAuto!==null)return (s.pendingAuto?(s.auto&&s.hold?'Возобновление':'Включение'):'Выключение')+' автозапуска не сохранено. Пока он '+(s.auto?(s.hold?'приостановлен':'включён'):'выключен')+'. '+e(model.autoError||'Повторите сохранение или отмените изменение.');
 if(!s.autoAvailable)return s.auto?'Автозапуск недоступен в этой сборке. Сохранённый выбор можно выключить.':'Автозапуск недоступен в этой сборке. Открывайте KeyBridge вручную.';
 if(!s.auto)return 'Автозапуск выключен. Текущая работа KeyBridge не меняется.';
 if(s.hold)return 'Автозапуск приостановлен. При следующем входе KeyBridge останется выключенным, пока вы не разрешите запуск.';
 if(s.permission==='denied')return 'Для запуска при входе нужно разрешение macOS. Текущая работа KeyBridge не меняется.';
 if(s.permission==='unknown')return 'Разрешение macOS неизвестно: запуск при входе пока не подтверждён.';
 if(s.safetyBlock||s.phase==='reconciling')return 'Состояние работы пока не подтверждено. Автозапуск возможен только после успешной проверки.';
 if(!s.prepared||s.client!=='managed')return 'Перед автозапуском нужно установить программы для ключа и настроить поиск лицензии в 1С.';
 return 'KeyBridge сможет включиться при следующем входе. Текущая работа KeyBridge не меняется.';
}
function permissionDetails(){
 if(!s.autoAvailable)return `<section class="kb-permission" data-result-scope="permission">${row('Запуск при входе','Недоступен в этой сборке')}<p class="kb-setting-explain">Для автозапуска нужна сборка с подписью разработчика. Пока открывайте KeyBridge вручную.</p></section>`;
 const states={allowed:'Разрешена',denied:'Запрещена',unknown:'Не удалось проверить'};
 const explanation=s.permission==='allowed'?'macOS разрешает KeyBridge работать в фоне.':s.permission==='denied'?'Разрешите KeyBridge в настройках macOS → «Основные» → «Объекты входа», затем повторите проверку.':'macOS не ответила. Проверьте разрешение в настройках macOS → «Основные» → «Объекты входа».';
 return `<section class="kb-permission" data-result-scope="permission">${row('Фоновая работа',result('permission')||states[s.permission])}<p class="kb-setting-explain">${explanation}</p></section>`;
}
function company(){
 return `<a class="kb-company" href="https://ingvar.pro/?utm_source=keybridge&amp;utm_medium=app&amp;utm_campaign=settings" target="_blank" rel="noopener noreferrer" aria-label="Ingvar Consulting — открыть сайт в браузере" aria-describedby="kb-company-description" title="https://ingvar.pro/?utm_source=keybridge&amp;utm_medium=app&amp;utm_campaign=settings"><img src="ingvar-consulting.png" width="186" height="33" alt=""><span class="kb-company-copy"><span class="kb-company-description" id="kb-company-description">Ingvar Consulting помогает 1С-командам разбирать процессы разработки: планирование, релизы, ревью, онбординг и повышает управляемость команды.</span><span class="kb-company-link" aria-hidden="true">ingvar.pro →</span></span></a>`;
}
function settings(){
 let actions='';
 if(s.pendingAuto!==null)actions=button('Сохранить выбор','retry-auto',true,model.autoWorking)+button('Отмена','cancel-auto',false,model.autoWorking);
 else if(!s.autoAvailable)actions='';
 else if(s.auto&&s.hold)actions=button('Возобновить автозапуск','resume-auto',true)+(s.permission!=='allowed'?button('Как разрешить фоновую работу','permission'):'');
 else if(s.permission!=='allowed')actions=button('Как разрешить фоновую работу','permission',true)+button('Проверить разрешение','check-permission');
 return `<div class="kb-lead"><h2>Настройки</h2></div><div class="kb-row kb-auto-row"><label class="kb-check"><input type="checkbox" id="kb-auto" ${(s.pendingAuto??s.auto)?'checked':''} ${busy()||model.autoWorking||(!s.autoAvailable&&!s.auto)?'disabled':''}><span>Включать KeyBridge при входе в macOS<small>${autoExplanation()}</small></span></label><span class="kb-auto-feedback" data-saved="${model.autoSaved||s.pendingAuto!==null}">${model.autoWorking?'Сохраняем…':s.pendingAuto!==null?'Ошибка':'Сохранено'}</span></div>${permissionDetails()}<div class="kb-actions">${actions}</div>${s.client==='external'?clientConflict():''}${installation()}${company()}`;
}
function focusKey(el){
 if(!el||!(content.contains(el)||panel.contains(el)))return null;
 if(el.id)return {id:el.id};
 if(el.dataset?.action)return {action:el.dataset.action,label:el.getAttribute('aria-label'),detailId:el.dataset.detailId||null};
 if(el.matches('a[href]'))return {href:el.getAttribute('href')};
 return null;
}
function rememberFocus(el){rememberedFocus=focusKey(el);}
function enterPage(kind,change){
 s.navigation=[...(s.navigation||[]),{kind,view:{help:s.help,diagnosing:s.diagnosing,detailTrail:[...(s.detailTrail||[])]},focus:rememberedFocus,scroll:content.scrollTop}];
 change();render();
}
function returnPage(kind,fallback){
 const entry=(s.navigation||[]).at(-1);
 if(entry?.kind===kind){s.navigation=s.navigation.slice(0,-1);Object.assign(s,entry.view);pendingReturn=entry;}
 else{fallback();}
 render();
}
function layoutScreen(previousScroll=0){
 dock.replaceChildren();backSlot.replaceChildren();
 const detailNodes=[...content.querySelectorAll('details.kb-details')];
 detailNodes.forEach((el,index)=>el.dataset.detailId=String(index));
 if(s.help){content.innerHTML=help();const oldHeading=content.querySelector('.kb-help>h3');if(oldHeading){const heading=document.createElement('h2');heading.textContent=oldHeading.textContent;oldHeading.replaceWith(heading);}}
 else if(s.detailTrail?.length){
  const selected=detailNodes[Number(s.detailTrail[s.detailTrail.length-1])];
  if(selected){const summary=selected.querySelector('summary');const heading=document.createElement('h2');heading.textContent=summary.textContent;const body=document.createElement('div');[...selected.children].filter(el=>el!==summary).forEach(el=>body.append(el.cloneNode(true)));content.replaceChildren(heading,body);}
  else s.detailTrail=[];
 }
 // Details become navigable pages, rather than expanding the current page.
 [...content.querySelectorAll('details.kb-details')].forEach(el=>{
  const summary=el.querySelector('summary');const b=document.createElement('button');b.className='kb-page-link';b.dataset.action='open-detail';b.dataset.detailId=el.dataset.detailId;b.textContent=summary.textContent+' →';el.replaceWith(b);
 });
 const backActions=['setup-back','back','close-help','close-diagnosis','cancel-settings','dismiss-access','restore-back'];
 let back=s.help?content.querySelector('[data-action="close-help"]'):s.detailTrail?.length?null:backActions.map(a=>content.querySelector('[data-action="'+a+'"]')).find(Boolean);
 if(s.detailTrail?.length&&!s.help){back=document.createElement('button');back.className='kb-secondary';back.dataset.action='detail-back';back.textContent='Назад';}
 if(back){if(!['cancel-settings','dismiss-access'].includes(back.dataset.action))back.textContent='Назад';backSlot.append(back);}
 // The unified panel keeps Stop and its menu mounted while page commands change.
 content.querySelectorAll('[data-action="stop"]').forEach(el=>el.remove());
 const commands=[...content.querySelectorAll('button[data-action]')].filter(el=>el.dataset.action!=='open-detail');
 const primary=['check-space','save-stop','probe','setup-next','prepare'].map(action=>commands.find(el=>el.dataset.action===action)).find(Boolean)||commands.find(el=>el.classList.contains('kb-primary')&&!el.disabled)||commands.find(el=>el.classList.contains('kb-primary'));
 const secondary=document.createElement('div');secondary.className='kb-dock-secondary';
 commands.filter(el=>el!==primary).forEach(el=>{el.className=el.dataset.action==='manual-license'&&s.proof==='unconfirmed'?'kb-primary':'kb-secondary';secondary.append(el);});dock.append(secondary);
 const right=document.createElement('div');right.className='kb-dock-primary';
 if(primary){right.append(primary);if(primary.dataset.action==='probe'){const explain=content.querySelector('#kb-probe-explain');if(explain)right.append(explain);}}
 dock.append(right);
 content.querySelectorAll('.kb-actions,.kb-proof-control,.kb-status-line').forEach(el=>{if(!el.children.length)el.remove();});
 const screen=[s.tab,s.phase,s.setupStep,s.diagnosing,s.help,(s.detailTrail||[]).join('/')].join(':');
 if(pendingReturn){content.scrollTop=pendingReturn.scroll;lastScreen=screen;}
 else if(screen!==lastScreen){content.scrollTop=0;lastScreen=screen;}else content.scrollTop=previousScroll;
}
function displayStatus(){
 if(s.phase==='loading'||s.phase==='reconciling')return {foot:'Проверяем состояние…'};
 if(s.phase==='paused')return {foot:'Ожидаем пробуждения.'};
 if(s.phase==='unknown')return {foot:'Статус ключа неизвестен.'};
 if(s.phase==='stopping')return {foot:'Освобождаем USB-ключ…'};
 if(s.phase==='starting'||s.phase==='recovering')return {foot:'Проверяем USB-ключ…'};
 if(s.phase==='ready'||s.phase==='probing')return {foot:'Может прервать работу 1С.'};
 if(s.phase==='waiting')return {foot:'USB-ключ не найден.'};
 return {foot:s.phase==='preparing'?'Можно отменить установку.':s.phase==='first'||s.editing?'Установка на этот Mac.':'USB-ключ не используется.'};
}
function render(){
 const previousScroll=content.scrollTop,previousFocus=document.activeElement;
 if(content.contains(previousFocus)||panel.contains(previousFocus))rememberFocus(previousFocus);
 root.querySelectorAll('[data-tab]').forEach(b=>{if(b.dataset.tab===s.tab)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});
 content.innerHTML=s.tab==='settings'?settings():main();layoutScreen(previousScroll);
 const stop=root.querySelector('#kb-stop');
 stop.hidden=!!dock.querySelector('[data-action="save-stop"]');
 stop.disabled=s.phase==='loading'||s.phase==='stopping'||pendingAction('stop')||pendingAction('quit')||(s.saved&&!busy()&&!active()&&s.phase!=='unknown'&&!(s.editing&&s.replacing));
 stop.textContent=s.phase==='stopping'?'Выключаем…':s.phase==='stopped'&&!s.saved?'Сохранить выключение':s.phase==='preparing'?'Отменить установку':'Выключить';
 root.querySelector('#kb-footnote').textContent=displayStatus().foot;
 const autoAnnouncement=content.querySelector('#kb-auto')?(model.autoSaved?'Выбор автозапуска сохранён.':model.autoError?content.querySelector('#kb-auto').closest('label').textContent:''):'';
 const localAnnouncements=[...content.querySelectorAll('[data-result-scope]')].map(el=>model.result(el.dataset.resultScope));
 const announcement=[...content.querySelectorAll('h2,h3,.kb-file-status')].map(el=>el.textContent).concat(localAnnouncements,autoAnnouncement).filter(Boolean).join('. ');
 const live=root.querySelector('#kb-announcement');
 // A completed repeat with the same wording is still a distinct accessible result.
 if(live.textContent!==announcement||live.dataset.revision!==String(model.feedbackRevision)){live.textContent=announcement;live.dataset.revision=String(model.feedbackRevision);}
 const focus=pendingReturn?.focus||rememberedFocus;
 if(focus&&(pendingReturn||!previousFocus?.isConnected||document.activeElement===document.body)){
  const controls=[...content.querySelectorAll('button,input,select,a[href]'),...panel.querySelectorAll('button,summary')];
  const same=controls.find(el=>!el.hidden&&(focus.id?el.id===focus.id:focus.href?el.getAttribute('href')===focus.href:el.dataset.action===focus.action&&el.getAttribute('aria-label')===focus.label&&(el.dataset.detailId||null)===focus.detailId));
  const available=el=>!el.disabled&&!el.hidden&&el.getAttribute('aria-disabled')!=='true';
  const tasks=[...dock.querySelectorAll('.kb-dock-secondary button,.kb-dock-primary button')];
  // The picker is temporarily disabled while NSOpenPanel/validation is active.
  // Keep its identity instead of moving focus to a download link. If the user
  // focuses another control, rememberFocus above replaces this identity.
  const target=same?(same.disabled?null:same):tasks.find(el=>el.classList.contains('kb-primary')&&available(el))||tasks.find(available)||controls.find(el=>available(el)&&!['stop','quit'].includes(el.dataset.action));
  target?.focus({preventScroll:true});
 }
 pendingReturn=null;
}
function chooseAuto(value){
 model.autoSaved=false;
 if(value===s.auto&&!(value&&s.hold)){model.cancelAuto();render();return;}
 send('autostart',value);
}
function action(a){
 model.autoSaved=false;
 if(a==='detail-back'){returnPage('detail',()=>{s.detailTrail=s.detailTrail.slice(0,-1);});return;}
 if(a==='diagnose'){enterPage('diagnosis',()=>{s.diagnosing=true;s.help='';});return;}
 if(a==='close-diagnosis'){returnPage('diagnosis',()=>{s.diagnosing=false;s.help='';});return;}
 if(a==='close-help'){returnPage('help',()=>{s.help='';});return;}
 if(a==='manual-license'){enterPage('help',()=>{s.help='manual';});return;}
 if(a==='permission'&&!s.autoAvailable)return;
 if(a==='storage-help'||a==='client-help'||a==='permission'){enterPage('help',()=>{s.help=a==='storage-help'?'storage':a==='client-help'?'client':'permission';});return;}
 if(a==='retry-auto'){if(s.pendingAuto!==null)send('autostart',s.pendingAuto);return;}
 if(a==='cancel-auto'){model.cancelAuto();render();return;}
 if(a==='resume-auto'){chooseAuto(true);return;}
 if(a==='setup-next'){if(s.setupStep==='installer'&&s.installer)s.setupStep='driver';else if(s.setupStep==='driver'&&s.driver)s.setupStep='review';model.clearResults();}
 else if(a==='setup-back'){s.setupStep=s.setupStep==='review'?'driver':'installer';model.clearResults();}
 else if(a==='edit-installer'||a==='edit-driver'){s.setupStep=a==='edit-installer'?'installer':'driver';}
 else if(a==='review-settings'){clearRoute();s.tab='main';s.reviewSettings=true;s.dismissedError=s.accessError;}
 else if(a==='cancel-settings'||a==='dismiss-access'){clearRoute();s.reviewSettings=false;s.dismissedError=s.accessError;}
 else if(a==='retry-access'){send(s.accessError==='restoring'?'restore':s.client==='external'?'repair':'configure');return;}
 else if(a==='restore-back'){clearRoute();s.tab='settings';s.detailTrail=['0'];s.dismissedError=s.accessError;}
 else if(a==='open-install'||a==='replace'){
  if(active()||busy()||s.phase==='unknown')return;
  clearRoute();model.clearResults();s.editing=true;s.replacing=s.prepared;s.setupStep='installer';s.tab='main';
 }
 else if(a==='back'){clearRoute();model.clearResults();s.editing=false;s.replacing=false;s.tab='settings';s.detailTrail=['0'];}
 else if(a==='prepare'||a==='retry-install'){
  if(!s.installer||!s.driver||busy()||active())return;
  clearRoute();s.tab='main';send('prepare');return;
 }
 else if(a==='configure'){const repair=s.reviewSettings&&s.client==='external';s.reviewSettings=false;send(repair?'repair':'configure');return;}
 else if(a==='save-stop'){send('stop');return;}
 else if(commands.has(a)){if(['start','restore','rollback','probe'].includes(a)&&busy())return;send(a);return;}
 render();
}
root.addEventListener('click',event=>{
 const link=event.target.closest('a[href]');
 if(link){event.preventDefault();rememberFocus(link);send('open-url',link.href);return;}
 const button=event.target.closest('[data-action],[data-tab]');
 if(!button||button.disabled||button.getAttribute('aria-disabled')==='true')return;
 rememberFocus(button);
 if(button.dataset.action==='open-detail'){enterPage('detail',()=>{s.detailTrail=[...s.detailTrail,button.dataset.detailId];});return;}
 if(button.dataset.tab){model.navigate(button.dataset.tab);rememberedFocus=null;model.autoSaved=false;render();}
 else action(button.dataset.action);
});
root.addEventListener('change',event=>{if(event.target.id==='kb-auto'){rememberFocus(event.target);chooseAuto(event.target.checked);}});
root.addEventListener('keydown',event=>{if(event.key==='Escape'){const more=root.querySelector('.kb-more');if(more.open){more.open=false;root.querySelector('#kb-more-toggle').focus();}}});
global.KeyBridge={
 update(payload){model.update(payload);s=model.state;render();},
 navigate(tab){if(!['main','settings','diagnosis'].includes(tab))return;model.navigate(tab);s=model.state;render();}
};
render();
// Handshake is a non-mutating request for the current native snapshot.
try{global.webkit?.messageHandlers?.keybridge?.postMessage({id:global.crypto?.randomUUID?.()||('ready-'+Date.now()),action:'ready'});}catch{}
})(typeof window==='undefined'?globalThis:window);
