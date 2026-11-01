// Test-only native bridge. This file is never copied into the application bundle.
'use strict';
const fixture=document.querySelector('#fixture'),frame=document.querySelector('#application'),output=document.querySelector('#request');
const empty={phase:'ready',prepared:true,client:'managed',clientRestored:false,key:true,want:true,hold:false,auto:false,autoAvailable:true,permission:'allowed',proof:'none',saved:true,selected:'current',step:0,updated:false,previousAvailable:false,updateProblem:false,previousValid:false,backupAvailable:false,pendingQuit:false,errorMessage:'',accessError:null,safetyBlock:null,contextVersion:'fixture-A',operationPending:false,fault:null};
const scenes={
 autostart_unavailable:['Автозапуск недоступен в сборке',{phase:'stopped',want:false,autoAvailable:false,permission:'unsupported'}],
 ready:['Работает',{}],first:['Первый запуск',{phase:'first',prepared:false,client:'missing',key:false,want:false}],
 missing:['Клиент не найден',{phase:'stopped',client:'missing',want:false}],client_unknown:['Клиент неизвестен',{phase:'stopped',client:'unknown',want:false}],
 unconfigured:['Нужна настройка',{phase:'stopped',client:'unconfigured',want:false}],external:['Чужие настройки',{phase:'stopped',client:'external',want:false}],
 space:['Недостаточно места',{phase:'first',prepared:false,want:false,fault:'space'}],waiting:['Нет ключа',{phase:'waiting',key:false}],
 unconfirmed:['Проба неподтверждена',{proof:'unconfirmed'}],success:['Подтверждённая проба',{proof:'success'}],failure:['Ошибка пробы',{proof:'failure'}],probe_timeout:['Таймаут пробы',{proof:'timeout'}],stale:['Старая проба',{proof:'stale'}],probing:['Проверка выполняется',{phase:'probing'}],
 update_failed:['Проблема обновления',{phase:'update-error',updated:true,updateProblem:true,previousAvailable:true,want:false,hold:true}],
 preparing:['Установка',{phase:'preparing',step:1,prepared:false,want:false}],starting:['Включение',{phase:'starting'}],stopping:['Выключение',{phase:'stopping'}],recovering:['Восстановление',{phase:'recovering'}],exhausted:['Попытки закончились',{phase:'exhausted',hold:true,want:false}],
 install_failed:['Ошибка установки',{phase:'install-error',prepared:false,want:false}],start_failed:['Ошибка включения',{phase:'start-error',want:false}],
 unsafe:['Защита неизвестна',{phase:'unsafe',hold:true,safetyBlock:'unsafe'}],multiple:['Несколько ключей',{phase:'multiple',key:false,hold:true,safetyBlock:'multiple'}],unknown:['Состояние неизвестно',{phase:'unknown',safetyBlock:'unknown'}],
 unsaved:['Stop не сохранён',{phase:'stopped',want:false,saved:false}],stopped:['Выключен',{phase:'stopped',want:false,hold:true}],
 permission:['Нет разрешения ОС',{phase:'stopped',want:false,auto:true,permission:'denied'}],permission_unknown:['Разрешение неизвестно',{phase:'stopped',want:false,auto:true,permission:'unknown'}],inhibited:['Автозапуск приостановлен',{phase:'stopped',want:false,auto:true,hold:true}],
 configuring:['Запрос разрешения настройки',{phase:'configuring',want:false}],restoring:['Запрос разрешения возврата',{phase:'restoring',want:false}],access_denied:['ОС отказала',{phase:'stopped',want:false,client:'unconfigured',accessError:'configuring',errorMessage:'macOS не разрешила изменить настройки 1С. Повторите запрос или отмените настройку.'}],
 rollback_damaged:['Повреждена предыдущая установка',{phase:'rollback-error',want:false,hold:true,previousAvailable:true,previousValid:false}],backup_missing:['Копия настроек отсутствует',{phase:'restore-error',want:false,hold:true,backupAvailable:false}],
 sleeping:['Сон',{phase:'paused',proof:'stale'}],agent_restart:['Перезапуск',{phase:'reconciling',proof:'stale',resumeReason:'restart'}],login:['Вход',{phase:'reconciling',auto:true,want:false,resumeReason:'login'}],
 invalid_installer:['Непригодный установщик',{phase:'first',prepared:false,want:false}],invalid_driver:['Непригодный драйвер',{phase:'first',prepared:false,want:false}]
};
for(const [value,[title]] of Object.entries(scenes)){const option=document.createElement('option');option.value=value;option.textContent=title;fixture.append(option);}
let state={...empty},files={},request=null;
const resourceRows=[['Память для работы с ключом','128 МиБ · 1 vCPU'],['Время замера','12:45 · исторический'],['Всего занято на Mac','1,2 ГиБ'],['Основа Alpine','64 МиБ'],['Текущая установка','240 МиБ'],['Предыдущая установка','240 МиБ'],['Другие сохранённые установки','640 МиБ'],['Незавершённые установки','0 МиБ'],['Виртуальная ёмкость диска','5 ГиБ'],['Занято внутри Linux','Нет измерения'],['Память процесса на Mac','Нет измерения']].map(([label,value])=>({label,value}));
function snapshot(feedback){frame.contentWindow.KeyBridge.update({state,files,keyLabel:'Sentinel HL Pro',componentLabel:'1С 8.5.4.1878 · драйвер HASP 10.33',proofTime:'12:40',resourceRows,...(feedback?{feedback}:{})});}
function select(){
 request=null;state={...empty,...scenes[fixture.value][1]};files={installer:{name:'',valid:false},driver:{name:'',valid:false}};
 if(fixture.value==='invalid_installer')files.installer={name:'client-only.run',valid:false,error:'В установщике нет менеджера лицензий. Выберите полную поставку 1С.'};
 if(fixture.value==='invalid_driver'){files.installer={name:'setup-full-…-x86_64.run',valid:true,validation:'preliminary',message:'Формат подходит. Состав проверим при установке.'};files.driver={name:'aksusbd_arm64.deb',valid:false,error:'Архитектура arm64 не подходит. Выберите пакет amd64.'};}
 snapshot();frame.contentWindow.KeyBridge.navigate(['permission','permission_unknown','inhibited','autostart_unavailable'].includes(fixture.value)?'settings':['unconfirmed','success','failure','probe_timeout','stale','probing'].includes(fixture.value)?'diagnosis':'main');output.textContent='Запросов нет';
}
frame.addEventListener('load',()=>{frame.contentWindow.webkit={messageHandlers:{keybridge:{postMessage(value){request=value;output.textContent=value.action;}}}};select();});
fixture.addEventListener('change',select);
function complete(ok){
 if(!request)return;const current=request;request=null;
 if(ok){
  if(current.action==='autostart'){state.auto=current.value;if(current.value)state.hold=false;}
  if(current.action==='start'){state.phase='ready';state.want=true;state.hold=false;}
  if(['stop','quit'].includes(current.action)){state.phase='stopped';state.want=false;state.hold=true;state.saved=true;}
  if(current.action==='prepare'){state.phase='stopped';state.prepared=true;state.selected='current';}
  if(current.action==='configure'||current.action==='repair'){state.client='managed';state.phase='stopped';state.accessError=null;state.errorMessage='';}
  if(current.action==='probe'){state.proof='unconfirmed';state.phase='ready';}
  if(current.action==='check-permission')state.permission='allowed';
  if(current.action==='check-client')state.client='unconfigured';
  if(current.action==='check-key'){state.key=true;state.phase='ready';}
  if(['installer','driver'].includes(current.action))files[current.action]={name:current.action==='installer'?'setup-full-selected-x86_64.run':'aksusbd_selected_amd64.deb',valid:true,validation:current.action==='installer'?'preliminary':'complete',message:current.action==='installer'?'Формат подходит. Состав проверим при установке.':'Файл выбран и проверен'};
 }
 snapshot({id:current.id,action:current.action,ok,message:ok?'':'Запись не завершилась. Повторите действие или отмените изменение.'});output.textContent=(ok?'Успех: ':'Отказ: ')+current.action;
}
document.querySelector('#complete-ok').addEventListener('click',()=>complete(true));document.querySelector('#complete-error').addEventListener('click',()=>complete(false));
