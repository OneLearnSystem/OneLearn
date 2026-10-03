export const cfg=window.ONELEARN_CONFIG;
export const params=new URLSearchParams(location.search),slug=params.get('school')||'',demo=params.get('demo')==='1';
export const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const safeURL=v=>{try{const u=new URL(v);return u.protocol==='https:'?u.href:''}catch{return ''}};
export const imageURL=v=>/^data:image\/(png|jpeg|webp);base64,[a-zA-Z0-9+/=]+$/.test(v||'')?v:safeURL(v);
export const link=(product,file='index.html',school=slug,isDemo=demo)=>{const base=cfg.apps[product]||'./';const u=new URL(file,new URL(base,location.href));if(school)u.searchParams.set('school',school);if(isDemo)u.searchParams.set('demo','1');return u.href};
let session;try{session=JSON.parse(sessionStorage.getItem('onelearn-staff')||'null')}catch{}
export const identity=()=>session?.user;
const store=s=>{session={...s,expires_at:Date.now()/1000+(s.expires_in||3600)};sessionStorage.setItem('onelearn-staff',JSON.stringify(session))};
let refreshing;
async function request(path,body,auth=false){if(!/^https:\/\/[^/]+\.supabase\.co$/.test(cfg.supabaseUrl)||!cfg.supabaseKey)throw Error('Deployment setup is needed. Add the NEW Supabase project URL and publishable key to config.js.');if(auth){if(!session)throw Error('Please sign in first.');if(session.expires_at<Date.now()/1000+60){refreshing||=(request('/auth/v1/token?grant_type=refresh_token',{refresh_token:session.refresh_token}).then(store).finally(()=>refreshing=null));try{await refreshing}catch{signOut();throw Error('Your session expired. Please sign in again.')}}}const headers={apikey:cfg.supabaseKey,'Content-Type':'application/json'};if(auth)headers.Authorization='Bearer '+session.access_token;let r;try{r=await fetch(cfg.supabaseUrl+path,{method:'POST',headers,body:JSON.stringify(body)})}catch{throw Error('Connection unavailable. Please try again; changes may need refreshing.')}const d=await r.json().catch(()=>null);if(!r.ok)throw Error(d?.message||d?.msg||d?.error_description||'Request could not be completed.');return d}
export const central=(name,args={},auth=true)=>request('/rest/v1/rpc/'+name,args,auth);
export async function login(email,password){store(await request('/auth/v1/token?grant_type=password',{email,password}));return central('ol_me')}
export async function signup(email,password){if(password.length<12)throw Error('Use a password of at least 12 characters.');const d=await request('/auth/v1/signup',{email,password});if(d.access_token)store(d);return !!d.access_token}
export const resetPassword=email=>request('/auth/v1/recover',{email});
const callback=new URLSearchParams(location.hash.slice(1));
export const recovery=callback.get('type')==='recovery'&&!!callback.get('access_token');
let recoveryToken=recovery?callback.get('access_token'):null;
if(callback.has('access_token'))history.replaceState(null,'',location.pathname+location.search);
export async function finishRecovery(password){if(!recoveryToken||password.length<12)throw Error('Use your email recovery link and a password of at least 12 characters.');const r=await fetch(cfg.supabaseUrl+'/auth/v1/user',{method:'PUT',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+recoveryToken,'Content-Type':'application/json'},body:JSON.stringify({password})});const d=await r.json();if(!r.ok)throw Error(d.message||d.msg||'The recovery link has expired. Request a fresh link.');recoveryToken=null;signOut()}
export function signOut(){const token=session?.access_token;session=null;sessionStorage.removeItem('onelearn-staff');if(token)fetch(cfg.supabaseUrl+'/auth/v1/logout',{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+token}}).catch(()=>{})}
export async function appRPC(name,args={}){if(demo){const {demoRPC}=await import('./demo.mjs');return demoRPC(name,args)}return central('ol_call',{p_slug:slug,p_method:name,p_args:args},!['oe_student_portal','oe_hub_student_action','oh_student','oh_open','oh_save','ss_student','ss_choose'].includes(name))}
export async function school(){if(demo)return {name:'Example Academy',slug:'demo',settings:{name:'Example Academy',colour:'#17695c'}};if(!slug)return null;return central('ol_school',{p_slug:slug},false)}
export function bar(s){const b=document.createElement('div');b.className='platform-bar';b.innerHTML=`<a href="${esc(link('OneLearn'))}"><img src="platform-logo.svg" alt="">OneLearn</a><span>${s?.settings?.logo&&imageURL(s.settings.logo)?`<img src="${esc(imageURL(s.settings.logo))}" alt="School logo">`:''}${esc(s?.name||'The school software family')}${demo?' · DEMO — sample data only':''}</span><a href="${esc(new URL('setup.html'+(slug?'?school='+encodeURIComponent(slug):demo?'?demo=1':''),location.href))}">School setup</a></div>`;document.body.prepend(b)}
export const run=async(fn)=>{try{await fn()}catch(e){alert(e.message)}};
export const download=(name,text,type='text/plain')=>{const u=URL.createObjectURL(new Blob([text],{type})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000)};
