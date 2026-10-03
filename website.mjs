// Preserve older bookmarked routes and authentication recovery links.
const hash=location.hash.slice(1);
if(location.pathname.endsWith('/')||location.pathname.endsWith('/index.html')){
 const views={blog:'blog.html',status:'status.html',control:'portal.html#control',account:'portal.html#account'};
 if(hash.includes('access_token=')||hash.includes('type=recovery'))location.replace('portal.html'+location.search+location.hash);
 else if(views[hash])location.replace(views[hash]);
}
for(const a of document.querySelectorAll('[data-app]')){const base=window.ONELEARN_CONFIG?.apps?.[a.dataset.app];if(base){try{const u=new URL('index.html',new URL(base,location.href));if(!['http:','https:','file:'].includes(u.protocol))continue;if(a.dataset.demo)u.searchParams.set('demo','1');const school=new URLSearchParams(location.search).get('school');if(school)u.searchParams.set('school',school);a.href=u.href}catch{}}}
const form=document.querySelector('#contact-form');
if(form){const selected=new URLSearchParams(location.search).get('product');for(const checkbox of form.querySelectorAll('[name=product]'))checkbox.checked=checkbox.value===selected;
 form.addEventListener('submit',async e=>{e.preventDefault();const button=form.querySelector('button[type=submit]'),result=document.querySelector('#contact-result'),f=new FormData(form);button.disabled=true;result.textContent='Sending your request…';try{if(f.get('website'))throw Error('Unable to submit this request.');if(!f.getAll('product').length)throw Error('Choose at least one product.');const {central}=await import('./shared.mjs');await central('ol_contact',{p_email:f.get('email'),p_school:f.get('school'),p_message:f.get('message'),p_products:f.getAll('product'),p_official:f.has('official')},false);form.reset();result.textContent='Your request has been received. OneLearn will review it and contact you.';}catch(err){result.textContent=err.message||'Your request could not be sent. Please try again.';}finally{button.disabled=false;}});
}
