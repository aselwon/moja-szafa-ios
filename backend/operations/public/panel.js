const byID=id=>document.getElementById(id);
let policy;
const messages={operator_authentication_required:'Your multi-factor sign-in is missing or has expired. Sign in again through the operator access portal.',
 operator_denied:'Your operator role does not allow this action.',version_conflict:'This item changed. Refresh before saving again.',
 policy_limit:'The requested values exceed the approved limits.',rate_limited:'Too many requests. Please wait a minute.',
 operations_unavailable:'Operations are temporarily unavailable. No successful change has been confirmed.'};
function element(tag,text){const value=document.createElement(tag);value.textContent=text;return value;}
function table(target,headers,rows){
 const container=byID(target);container.replaceChildren();
 if(!rows.length){container.append(element('p','No records.'));return;}
 const wrap=element('div','');wrap.className='tableWrap';const grid=element('table','');
 const head=element('thead',''),headRow=element('tr','');headers.forEach(h=>headRow.append(element('th',h)));head.append(headRow);grid.append(head);
 const body=element('tbody','');rows.forEach(row=>{const tr=element('tr','');row.forEach(value=>{const td=element('td','');
  if(value instanceof Node)td.append(value);else td.textContent=String(value??'—');tr.append(td);});body.append(tr);});grid.append(body);wrap.append(grid);container.append(wrap);
}
async function call(request){
 const response=await fetch('/api/command',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','Idempotency-Key':crypto.randomUUID()},body:JSON.stringify(request)});
 const value=await response.json();if(!response.ok||value.error)throw new Error(messages[value.error?.code]??'The request could not be completed. Refresh to check its status.');return value.data;
}
async function action(button,work){button.disabled=true;byID('notice').textContent='Working…';try{await work();byID('notice').textContent='Updated.';}
 catch(error){byID('notice').textContent=error.message;}finally{button.disabled=false;}}
async function refresh(){
 const data=await call({action:'summary'});policy=data.policy;
 byID('updated').textContent=`As of ${new Date(data.generatedAt).toLocaleString()}`;
 const health=byID('health');health.replaceChildren();
 for(const [name,state] of Object.entries({Database:data.database,...data.services})){const card=element('div',`${name}: ${state}`);card.className='card';health.append(card);}
 table('queues',['Queue','Kind / state','Count'],[
  ...(data.jobs??[]).map(x=>['AI jobs',`${x.kind} / ${x.status}`,x.count]),
  ...(data.images??[]).map(x=>['Images',x.state,x.count]),
  ...(data.deletions??[]).map(x=>['Account deletion',x.status,x.count]),
  ...(data.support??[]).map(x=>['Support',x.status,x.count])]);
 const cost=byID('cost');cost.replaceChildren(element('p',`Known usage, list-price estimate: $${data.cost.estimated_list_price_usd_for_known_usage}`),
  element('p',`Calls with known cost: ${data.cost.measured_calls}. Calls with unknown cost: ${data.cost.unknown_cost_calls}.`),element('p',data.cost.qualification));
 byID('policySummary').textContent=policy?`Text AI: ${policy.enabled?'enabled':'disabled'} · Image AI: ${policy.imageEnabled?'enabled':'disabled'} · Daily global / per-account credits: ${policy.dailyGlobalUnits} / ${policy.dailyUserUnits}`:'Controls unavailable';
 byID('policyForm').hidden=data.role!=='admin'||!policy;
 byID('supportSection').hidden=!['support','admin'].includes(data.role);byID('auditSection').hidden=data.role!=='admin';
 if(policy){byID('aiEnabled').checked=policy.enabled;byID('imageEnabled').checked=policy.imageEnabled;
  byID('globalUnits').value=policy.dailyGlobalUnits;byID('globalUnits').max=policy.maxGlobalUnits;
  byID('userUnits').value=policy.dailyUserUnits;byID('userUnits').max=policy.maxUserUnits;
  byID('ceilings').textContent=`Approved ceilings: ${policy.maxGlobalUnits} global / ${policy.maxUserUnits} per account. This panel cannot raise those ceilings.`;}
}
byID('refresh').addEventListener('click',event=>action(event.currentTarget,refresh));
byID('policyForm').addEventListener('submit',event=>{event.preventDefault();if(!policy)return;
 const request={action:'policy_update',version:policy.version,enabled:byID('aiEnabled').checked,imageEnabled:byID('imageEnabled').checked,
  dailyGlobalUnits:Number(byID('globalUnits').value),dailyUserUnits:Number(byID('userUnits').value)};
 if(!confirm(`Save AI controls? Text: ${request.enabled?'on':'off'}, images: ${request.imageEnabled?'on':'off'}, daily credits: ${request.dailyGlobalUnits} global / ${request.dailyUserUnits} per account.`))return;
 action(event.submitter,async()=>{await call(request);await refresh();});});
byID('supportLoad').addEventListener('click',event=>action(event.currentTarget,async()=>{
 const requests=await call({action:'support_list'});table('support',['Created','Subject','Status','Action'],requests.map(item=>{
  const open=element('button','Open request');open.type='button';open.addEventListener('click',()=>action(open,async()=>{
   const detail=await call({action:'support_read',id:item.id});const container=byID('supportDetail');container.replaceChildren(element('h3',detail.subject),element('pre',detail.message));
   if(detail.truncated)container.append(element('p','This long message is truncated.'));
   const label=element('label','Status '),status=element('select','');['open','in_progress','closed'].forEach(value=>{const option=element('option',value);option.value=value;status.append(option);});status.value=detail.status;label.append(status);container.append(label);
   const save=element('button','Save status');save.type='button';save.addEventListener('click',()=>action(save,async()=>{const changed=await call({action:'support_update',id:detail.id,version:detail.version,status:status.value});detail.version=changed.version;container.append(element('p',`Saved status: ${changed.status}`));}));container.append(save);
  }));return [new Date(item.created_at).toLocaleString(),item.subject,item.status,open];}));
}));
byID('auditLoad').addEventListener('click',event=>action(event.currentTarget,async()=>{
 const events=await call({action:'audit_list'});table('audit',['Time','Operator','Action','Outcome','Change'],events.map(item=>[
  new Date(item.occurred_at).toLocaleString(),item.operator_id,item.action,item.outcome,
  item.before_value||item.after_value?`${JSON.stringify(item.before_value)} → ${JSON.stringify(item.after_value)}`:'—']));
}));
action(byID('refresh'),refresh);
