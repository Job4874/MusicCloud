const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const shapes = {
 library:'<rect x="3" y="4" width="6" height="16" rx="1"/><path d="M13 4v16M18 4l3 16"/>',
 disc:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2"/><path d="M7 8a6 6 0 0 1 4-2"/>',
 heart:'<path d="M20.8 4.8a5.5 5.5 0 0 0-7.8 0L12 5.9l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.4a5.5 5.5 0 0 0 0-7.8Z"/>',
 usb:'<path d="M12 22V3m0 0L9 6m3-3 3 3M12 15l-6-4V8m6 11 6-4v-4"/><circle cx="6" cy="6" r="2"/><rect x="16" y="7" width="4" height="4"/>',
 plus:'<path d="M12 5v14M5 12h14"/>', search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
 play:'<path d="m8 5 11 7-11 7Z"/>',pause:'<path d="M8 5h3v14H8zM15 5h3v14h-3z"/>',
 previous:'<path d="M5 5v14m14-14L8 12l11 7Z"/>', next:'<path d="M19 5v14M5 5l11 7-11 7Z"/>',
 shuffle:'<path d="M3 6h3c6 0 6 12 12 12h3m-3-3 3 3-3 3M3 18h3c2 0 4-2 5-5m3-5c1-1 2-2 4-2h3m-3-3 3 3-3 3"/>',
 repeat:'<path d="m17 2 4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4m14-1v2a3 3 0 0 1-3 3H3"/>',
 queue:'<path d="M3 5h18M3 10h18M3 15h10M3 20h10m4-5 5 3-5 3Z"/>',
 volume:'<path d="M4 9h4l5-4v14l-5-4H4Zm13-1a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
 close:'<path d="m6 6 12 12M6 18 18 6"/>', more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
 folder:'<path d="M3 7V5h7l2 3h9v12H3Z"/>', shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
 music:'<path d="M9 18V5l11-2v13M9 9l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/>',
 clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>'
};
const icon = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${shapes[name] || shapes.music}</svg>`;
function fillIcons(root=document) { root.querySelectorAll('[data-icon]').forEach(el => el.innerHTML=icon(el.dataset.icon)); }
fillIcons();
let library={tracks:[],favorites:[],playlists:[],stats:{bytes:0}}, view='library', albumFilter=null, search='', queue=[], currentId=null, shuffle=false, repeat='off', uploading=false, exportInfo=null;
let catalogs=[],catalogId=null,catalogDetail=null,catalogLoading=false,catalogError='',catalogImporting=false,catalogPage=0,refreshGeneration=0;
let libraryLoaded=false,activeRefreshes=0,activeMutations=0,pendingStateWrites=0,mutationRevision=0,backgroundRefreshRunning=false,backgroundRefreshTimer;
const CATALOG_PAGE_SIZE=250, MAX_CATALOG_UPLOAD=100*1024*1024;
const audio=$('#audio'); audio.volume=.8;
const trackById = id => library.tracks.find(t=>t.id===id);
const time = n => Number.isFinite(n)&&n>=0 ? `${Math.floor(n/60)}:${String(Math.floor(n%60)).padStart(2,'0')}` : '—';
const bytes = n => n>1073741824 ? `${(n/1073741824).toFixed(1)} GB` : `${(n/1048576).toFixed(1)} MB`;
const hash = s => [...String(s)].reduce((n,c)=>(n*31+c.charCodeAt(0))>>>0,0);
const art = (track,cls='') => `<div class="art art-${hash(track?.album||track?.title||'MusicCloud')%6} ${cls}"><span>${esc((track?.album||track?.title||'mc').slice(0,2))}</span></div>`;
let toastTimer;
function toast(message,error=false) {const el=$('#toast');el.textContent=message;el.className=`visible${error?' error':''}`;clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.className='',error?7000:4200);}
async function api(path,options={}) {
 const mutation=!['GET','HEAD'].includes((options.method||'GET').toUpperCase());
 if(mutation){activeMutations++;mutationRevision++;}
 try{const response=await fetch(path,{...options,headers:{'X-MusicCloud':'1',...(options.body&&typeof options.body==='string'?{'Content-Type':'application/json'}:{}),...options.headers}});const result=await response.json();if(!response.ok)throw new Error(result.error||`Request failed (${response.status})`);return result;}
 finally{if(mutation)activeMutations--;}
}
async function refresh() {
 const generation=++refreshGeneration;activeRefreshes++;
 try{
  const [nextLibrary,nextCatalogs]=await Promise.all([api('/api/library'),api('/api/catalogs')]);
  if(generation!==refreshGeneration)return;
  library=nextLibrary;catalogs=nextCatalogs.catalogs;libraryLoaded=true;
  const selected=catalogId;
  if(selected){const detail=await api(`/api/catalogs/${encodeURIComponent(selected)}`);if(generation!==refreshGeneration)return;if(catalogId===selected){catalogDetail=detail;catalogError='';catalogLoading=false;}}
  render();updatePlayer();
 }finally{activeRefreshes--;}
}
let stateWrites=Promise.resolve();
function saveState(change) {pendingStateWrites++;mutationRevision++;const pending=stateWrites.catch(()=>{}).then(async()=>{const next=change(library);library=await api('/api/state',{method:'PUT',body:JSON.stringify({favorites:next.favorites??library.favorites,playlists:next.playlists??library.playlists})});render();updatePlayer();}).finally(()=>{pendingStateWrites--;});stateWrites=pending;return pending;}

function backgroundRefreshAllowed(){
 const focused=document.activeElement;
 return document.visibilityState==='visible'&&!uploading&&!catalogImporting&&!catalogLoading&&!activeRefreshes&&!activeMutations&&!pendingStateWrites&&!$('#dialog').open&&$('#drop-zone').hidden
  &&!focused?.matches('input:not([type="range"]),textarea,select')&&!focused?.isContentEditable;
}
function renderBackgroundChanges(libraryChanged){
 const position={x:window.scrollX,y:window.scrollY};
 const scrolls=['#main','#playlist-nav','#content .table-wrap'].flatMap(selector=>[...document.querySelectorAll(selector)].map((element,index)=>({selector,index,left:element.scrollLeft,top:element.scrollTop})));
 const expanded=[...document.querySelectorAll('#content details')].map(element=>element.open);
 const focused=document.activeElement;
 const focusSelector=focused?.id?`#${CSS.escape(focused.id)}`:focused?.dataset.action?['data-action','data-id','data-track','data-album'].filter(name=>focused.hasAttribute(name)).map(name=>`[${name}="${CSS.escape(focused.getAttribute(name))}"]`).join(''):null;
 // The persistent audio element, its source/time, and the listening queue stay intact.
 render();if(libraryChanged)updatePlayer();
 document.querySelectorAll('#content details').forEach((element,index)=>{if(index<expanded.length)element.open=expanded[index];});
 if(focused&&!focused.isConnected&&focusSelector)document.querySelector(focusSelector)?.focus({preventScroll:true});
 for(const entry of scrolls){const element=document.querySelectorAll(entry.selector)[entry.index];if(element){element.scrollLeft=entry.left;element.scrollTop=entry.top;}}
 window.scrollTo(position.x,position.y);
}
async function refreshInBackground(){
 if(backgroundRefreshRunning||!backgroundRefreshAllowed())return;
 backgroundRefreshRunning=true;
 const generation=refreshGeneration,revision=mutationRevision,selected=view==='catalogs'?catalogId:null;
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),8000);
 try{
  const options={signal:controller.signal};
  const [nextLibrary,nextCatalogs]=await Promise.all([api('/api/library',options),api('/api/catalogs',options)]);
  if(!backgroundRefreshAllowed()||generation!==refreshGeneration||revision!==mutationRevision)return;
  const libraryChanged=!libraryLoaded||JSON.stringify(nextLibrary)!==JSON.stringify(library);
  const catalogsChanged=JSON.stringify(nextCatalogs.catalogs)!==JSON.stringify(catalogs);
  let detail=null;
  if(selected&&(libraryChanged||catalogsChanged||catalogError))detail=await api(`/api/catalogs/${encodeURIComponent(selected)}`,options);
  if(!backgroundRefreshAllowed()||generation!==refreshGeneration||revision!==mutationRevision||selected!==(view==='catalogs'?catalogId:null))return;
  const detailChanged=detail&&(catalogError||JSON.stringify(detail)!==JSON.stringify(catalogDetail));
  if(!libraryChanged&&!catalogsChanged&&!detailChanged)return;
  ++refreshGeneration;library=nextLibrary;catalogs=nextCatalogs.catalogs;libraryLoaded=true;
  if(detail){catalogDetail=detail;catalogError='';}
  renderBackgroundChanges(libraryChanged);
 }catch{/* Keep the current music and view; retry on the next visible poll or focus. */}
 finally{controller.abort();clearTimeout(timeout);backgroundRefreshRunning=false;}
}
function scheduleBackgroundRefresh(){clearTimeout(backgroundRefreshTimer);backgroundRefreshTimer=setTimeout(refreshInBackground,200);}
function filteredTracks() {
 let tracks=library.tracks;
 if(view==='favorites')tracks=tracks.filter(t=>library.favorites.includes(t.id));
 if(view.startsWith('playlist:')){const p=library.playlists.find(p=>p.id===view.slice(9));tracks=(p?.trackIds||[]).map(trackById).filter(Boolean);}
 if(albumFilter)tracks=tracks.filter(t=>t.album===albumFilter);
 if(search)tracks=tracks.filter(t=>`${t.title} ${t.artist} ${t.album}`.toLowerCase().includes(search));
 return tracks;
}
function albums(tracks=library.tracks) {const map=new Map();for(const t of tracks){const key=t.album||'Unsorted';if(!map.has(key))map.set(key,{name:key,artist:t.artist,tracks:[]});map.get(key).tracks.push(t);}return [...map.values()];}
function titleForView(){return view==='library'?'Library':view==='albums'?'Albums':view==='favorites'?'Favorites':view==='transfer'?'USB transfer':view==='catalogs'?'YouTube playlists':library.playlists.find(p=>`playlist:${p.id}`===view)?.name||'Playlist';}
function render(){
 $('#nav-count').textContent=library.tracks.length;$('#crumb').textContent=titleForView();
 $('#catalog-count').textContent=catalogs.length;
 $('#search').placeholder=view==='catalogs'?'Search playlist metadata':'Search your music';
 $('#drop-zone h2').textContent=view==='catalogs'?'Bring your playlist report.':'Bring your music home.';
 $('#drop-zone p').textContent=view==='catalogs'?'Drop one generated playlist JSON report. Keep authentication files private.':'Drop audio files to add them to your local library.';
 $('#navigation').querySelectorAll('button').forEach(b=>b.classList.toggle('active',b.dataset.view===view));
 $('#playlist-nav').innerHTML=library.playlists.length?library.playlists.map(p=>`<button class="playlist-nav-item ${view===`playlist:${p.id}`?'active':''}" data-action="playlist" data-id="${esc(p.id)}">${esc(p.name)}</button>`).join(''):'<p class="empty-nav">Make a mix of your own.</p>';
 if(view==='transfer'){renderTransfer();return;}
 if(view==='catalogs'){renderCatalogs();return;}
 const tracks=filteredTracks();let html='';
 if(view==='library'&&!search&&!albumFilter){
 html=`<section class="hero"><div class="hero-copy"><div class="eyebrow">YOUR MUSIC. YOUR RULES.</div><h1>A little less cloud.<br>A lot more <em>yours.</em></h1><p>A home for the music you keep. No feeds, no subscriptions. Just press play.</p><div class="hero-buttons"><button class="button primary" data-action="add">${icon('plus')} Add your music</button><button class="button secondary" data-action="${library.tracks.length?'play-all':'demo'}">${icon('play')} ${library.tracks.length?'Play library':'Try a soundcheck'}</button></div></div><div class="hero-art" aria-hidden="true"><div class="sleeve"><span>the personal<br>collection.</span><small>SIDE A / ONLY YOURS</small></div><div class="vinyl"></div><span class="art-caption">GOOD MUSIC. KEPT CLOSE.</span></div></section><div class="summary-bar"><div class="summary-item">${icon('music')} <strong>${library.tracks.length}</strong> tracks in your library</div><div class="summary-item">${icon('disc')} <strong>${albums().length}</strong> albums</div><div class="summary-item">${icon('folder')} <strong>${bytes(library.stats?.bytes||0)}</strong> on this computer</div><div class="summary-item">${icon('shield')} No cloud connection needed</div></div>`;
 const recent=albums().slice(-4).reverse();if(recent.length)html+=`<section><div class="section-heading"><div><h2>From your collection</h2><p>Some good company for whatever comes next.</p></div><button class="text-button" data-action="view-albums">View all ↗</button></div>${albumCards(recent)}</section>`;
 }else{
 html=`<div class="page-heading"><div class="eyebrow">YOUR PERSONAL COLLECTION</div><h1>${esc(albumFilter||titleForView())}</h1><p>${search?`Results for “${esc($('#search').value)}”`:view==='favorites'?'The tracks you keep coming back to.':view.startsWith('playlist:')?'Made by you. Played your way.':'Every record has a place here.'}</p><div class="controls-row"><button class="button primary small" data-action="play-all" ${tracks.length?'':'disabled'}>${icon('play')} Play ${view.startsWith('playlist:')?'playlist':'all'}</button>${view.startsWith('playlist:')?'<button class="button secondary small" data-action="edit-playlist">Edit playlist</button>':''}${albumFilter?'<button class="text-button" data-action="clear-album">← All albums</button>':''}</div></div>`;
 }
 if(view==='albums'&&!albumFilter){html+=tracks.length?albumCards(albums(tracks)):emptyState(search?'No matching albums':'Your collection starts here',search?'Try another title, artist or album.':'Add your own audio files to start collecting albums.');}
 else{html+=`<section><div class="section-heading"><div><h2>${search?'Search results':view.startsWith('playlist:')?'In this playlist':view==='favorites'?'Saved with love':albumFilter?'Tracks':'All tracks'}</h2></div><span class="muted">${tracks.length} ${tracks.length===1?'track':'tracks'}</span></div>${tracks.length?trackTable(tracks):emptyState(search?'Nothing here by that name':view==='favorites'?'Keep your favorites close':view.startsWith('playlist:')?'A new mix, waiting for you':'Your music belongs here',search?'Try another title, artist or album.':view==='favorites'?'Tap the heart beside any track to save it here.':view.startsWith('playlist:')?'Edit this playlist to choose tracks from your library.':'Add MP3, M4A, WAV or other audio files from your computer. They stay on this computer until you copy them over USB.')}</section>`;}
 $('#content').innerHTML=html;
}

function completeness(value){return value===true?'Counts match':value===false?'Partial report':'Completeness unverified';}
function catalogStats(item){
 const counts=item.counts||{};
 return `<div class="catalog-match-counts"><span class="matched">${counts.matched||0} matched</span><span>${counts.missing||0} missing</span><span>${counts.ambiguous||0} ambiguous</span><span>${counts.unavailable||0} unavailable</span></div>`;
}
function catalogImportControls(){
 return `<button class="button primary small" data-action="import-catalog" ${catalogImporting?'disabled':''}>${icon('plus')} ${catalogImporting?'Importing report…':'Import playlist JSON'}</button>`;
}
function renderCatalogs(){
 let html=`<div class="page-heading catalog-heading"><div><div class="eyebrow">YOUR PLAYLISTS. EVERY RETURNED ENTRY.</div><h1>YouTube playlists</h1><p>Keep an ordered report of your playlists here. Play the songs you have as local audio.</p></div>${catalogImportControls()}</div>`;
 if(!catalogId){
  html+='<div class="note catalog-note"><strong>Import a metadata report, then add your audio.</strong> Choose a JSON file generated by the included YouTube Music importer. It contains playlist entries, not audio. Your authentication file stays outside this app; never choose auth.json or a token file.</div>';
  const items=catalogs.filter(item=>!search||`${item.title} ${item.playlistId}`.toLowerCase().includes(search));
  html+=`<div class="section-heading catalog-section-heading"><h2>${search?'Matching reports':'Imported reports'}</h2><span class="muted">${items.length} of ${catalogs.length}</span></div>`;
  if(items.length){
   html+=`<div class="catalog-grid">${items.map(item=>`<button class="catalog-card" data-action="open-catalog" data-id="${esc(item.id)}"><div class="catalog-card-top">${icon('queue')}<span class="catalog-completeness ${item.complete===false?'partial':''}">${completeness(item.complete)}</span></div><h3>${esc(item.title||'Untitled playlist')}</h3><p>${item.extractedCount} extracted <span>/</span> ${item.reportedCount===null?'unknown':item.reportedCount} reported</p>${catalogStats(item)}<small>View ordered entries →</small></button>`).join('')}</div>`;
  }else{
   html+=`<div class="empty-state"><div class="empty-icon">${icon('queue')}</div><h3>${search?'No matching reports':'Bring your playlist list with you'}</h3><p>${search?'Search by playlist name or ID.':'Generate a playlist JSON with the included importer, then import it here. Every returned occurrence stays in the report, including duplicates and unavailable entries.'}</p>${search?'':catalogImportControls()}</div>`;
  }
 }else{
  html+='<button class="text-button catalog-back" data-action="catalog-list">← All imported reports</button>';
  if(catalogLoading)html+='<div class="empty-state" role="status"><h3>Opening playlist report…</h3></div>';
  else if(catalogError)html+=`<div class="empty-state"><h3>Report could not be opened</h3><p>${esc(catalogError)}</p><button class="button secondary" data-action="reload-catalog">Try again</button></div>`;
  else if(catalogDetail){
   const item=catalogDetail;
   const matched=matchedCatalogIds(item,library);
   const rows=item.entries.filter(entry=>!search||`${entry.title} ${entry.artists.join(' ')} ${entry.videoId||''}`.toLowerCase().includes(search));
   const pages=Math.max(1,Math.ceil(rows.length/CATALOG_PAGE_SIZE));
   catalogPage=Math.min(catalogPage,pages-1);
   const start=catalogPage*CATALOG_PAGE_SIZE, visible=rows.slice(start,start+CATALOG_PAGE_SIZE);
   html+=`<section class="catalog-report"><div class="catalog-report-header"><div><span class="catalog-completeness ${item.complete===false?'partial':''}">${completeness(item.complete)}</span><h2>${esc(item.title||'Untitled playlist')}</h2><p class="catalog-identity">Playlist ID <code>${esc(item.playlistId)}</code></p></div><div class="catalog-report-totals"><strong>${item.extractedCount}</strong><span>extracted entries</span><small>${item.reportedCount===null?'Total not reported':`${item.reportedCount} reported by YouTube`}</small></div></div>${catalogStats(item)}<p class="catalog-count-explanation">${item.complete===true?'The returned count matches the reported total. Hidden source entries may still be unavailable.':item.complete===false?'The extracted count differs from the reported total. Missing entries have not been invented.':'The report cannot establish whether every source entry was returned.'}</p>${item.warnings.length?`<details class="catalog-warnings" ${item.complete===false?'open':''}><summary>${item.warnings.length} import ${item.warnings.length===1?'note':'notes'}</summary><ul>${item.warnings.map(warning=>`<li>${esc(warning)}</li>`).join('')}</ul></details>`:''}<div class="controls-row catalog-controls"><button class="button primary small" data-action="catalog-playlist" ${matched.length?'':'disabled'}>${icon('plus')} Create local playlist</button><button class="button secondary small" data-action="download-catalog">${icon('download')} Download JSON report</button><button class="text-button" data-action="reload-catalog">Refresh matches</button></div><p class="catalog-playlist-note">Only uniquely matched local audio is added to a playable playlist. Missing, ambiguous and unavailable entries stay in this report. Duplicate report rows remain here; a local playlist uses each audio file once.</p></section>`;
   html+=`<div class="section-heading catalog-section-heading"><h2>${search?'Matching entries':'Ordered entries'}</h2><span class="muted">${rows.length} of ${item.entries.length} entries</span></div>`;
   if(visible.length){
    html+=`<div class="table-wrap"><table class="track-table catalog-table"><thead><tr><th>#</th><th>TITLE / ARTISTS</th><th>LOCAL AUDIO</th><th>SOURCE</th></tr></thead><tbody>${visible.map(entry=>{
     const local=entry.matchStatus==='matched'?trackById(entry.matchedTrackId):null;
     const label={matched:'Matched local file',missing:'Local audio missing',ambiguous:'Multiple local matches',unavailable:'Unavailable entry'}[entry.matchStatus]||'Local audio missing';
     return `<tr><td>${entry.position}</td><td class="catalog-entry-title"><strong>${esc(entry.title||'Untitled entry')}</strong><small>${esc(entry.artists.join(', ')||'Artist not supplied')}</small></td><td><span class="catalog-status ${esc(entry.matchStatus)}">${esc(label)}</span>${local?`<button class="catalog-local-play" data-action="catalog-play" data-id="${esc(local.id)}" aria-label="Play local audio ${esc(entry.title)}">${icon('play')} Play local file</button>`:''}</td><td class="catalog-source"><small>${entry.available===false?'Unavailable':entry.available===true?'Listed by source':'Availability unknown'}</small><code>${esc(entry.videoId||'No video ID returned')}</code></td></tr>`;
    }).join('')}</tbody></table></div>`;
   }else html+=`<div class="empty-state"><h3>${search?'No matching entries':'This report contains no entries'}</h3><p>${search?'Try a title, artist or video ID.':'The reported and extracted totals above describe this export.'}</p></div>`;
   if(pages>1)html+=`<div class="catalog-pagination"><button class="button secondary small" data-action="catalog-previous" ${catalogPage?'':'disabled'}>Previous entries</button><span>Showing ${start+1}–${start+visible.length} of ${rows.length} · Page ${catalogPage+1}/${pages}</span><button class="button secondary small" data-action="catalog-next" ${catalogPage+1<pages?'':'disabled'}>Next entries</button></div>`;
  }
 }
 $('#content').innerHTML=html;
}

function matchedCatalogIds(item,state){
 const available=new Set(state.tracks.map(track=>track.id));
 return [...new Set(item.entries.filter(entry=>entry.matchStatus==='matched'&&available.has(entry.matchedTrackId)).map(entry=>entry.matchedTrackId))];
}
async function openCatalog(id){
 view='catalogs';albumFilter=null;catalogId=id;catalogPage=0;catalogLoading=true;catalogError='';catalogDetail=null;search='';$('#search').value='';render();
 try{const detail=await api(`/api/catalogs/${encodeURIComponent(id)}`);if(catalogId===id)catalogDetail=detail;}
 catch(error){if(catalogId===id)catalogError=error.message;}
 finally{if(catalogId===id){catalogLoading=false;render();}}
}
function manifestForUpload(value){
 if(!value||value.schema!=='musiccloud.playlist.v1'||value.source!=='youtube-music'||!Array.isArray(value.entries)||!Array.isArray(value.warnings))throw new Error('Choose a generated MusicCloud playlist report, not an authentication or token file.');
 if(value.entries.length>100000||typeof value.playlistId!=='string'||typeof value.title!=='string'||!Number.isSafeInteger(value.extractedCount)||(value.reportedCount!==null&&!Number.isSafeInteger(value.reportedCount))||![true,false,null].includes(value.complete)||value.warnings.some(warning=>typeof warning!=='string'))throw new Error('The playlist report has invalid metadata or too many entries.');
 const entries=value.entries.map(reportEntry);
 return {schema:value.schema,source:value.source,playlistId:value.playlistId,title:value.title,reportedCount:value.reportedCount,extractedCount:value.extractedCount,complete:value.complete,warnings:value.warnings,entries};
}
function reportEntry(entry){
 if(!entry||!Number.isSafeInteger(entry.position)||typeof entry.title!=='string'||!Array.isArray(entry.artists)||entry.artists.some(artist=>typeof artist!=='string')||!(entry.videoId===null||typeof entry.videoId==='string'&&/^[A-Za-z0-9_-]{11}$/.test(entry.videoId))||entry.url!==(entry.videoId?`https://music.youtube.com/watch?v=${entry.videoId}`:null)||![true,false,null].includes(entry.available))throw new Error('The playlist report contains invalid entries.');
 return {position:entry.position,title:entry.title,artists:entry.artists,videoId:entry.videoId,url:entry.url,available:entry.available};
}
async function importCatalog(file){
 if(catalogImporting){toast('A playlist report is already being imported.');return;}
 if(!file)return;
 if(file.size>MAX_CATALOG_UPLOAD){toast('Choose a playlist JSON report no larger than 100 MB.',true);return;}
 catalogImporting=true;render();
 try{
  let value;try{value=JSON.parse(await file.text());}catch{throw new Error('This file is not valid playlist JSON. File contents were not uploaded.');}
  const clean=manifestForUpload(value);
  const imported=await api('/api/catalogs',{method:'POST',body:JSON.stringify(clean)});
  const next=await api('/api/catalogs');catalogs=next.catalogs;
  catalogId=imported.id;catalogDetail=imported;catalogLoading=false;catalogError='';catalogPage=0;view='catalogs';albumFilter=null;
  search='';$('#search').value='';toast(`Imported ${imported.extractedCount} playlist entries. ${completeness(imported.complete)}.`);
 }catch(error){toast(error.message,true);}
 finally{catalogImporting=false;$('#catalog-file-input').value='';render();}
}
function downloadCatalog(){
 if(!catalogDetail)return;
 const item=catalogDetail, report={...manifestForUpload(item),importedAt:item.importedAt,counts:{...item.counts},entries:item.entries.map(entry=>({...reportEntry(entry),matchStatus:entry.matchStatus,matchedTrackId:entry.matchedTrackId}))};
 const url=URL.createObjectURL(new Blob([`${JSON.stringify(report,null,2)}\n`],{type:'application/json'}));
 const link=document.createElement('a');link.href=url;link.download=`MusicCloud-${item.playlistId}.json`;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
function createCatalogPlaylist(){
 const item=catalogDetail;if(!item)return;
 const ids=matchedCatalogIds(item,library), matchedRows=item.entries.filter(entry=>entry.matchStatus==='matched'&&trackById(entry.matchedTrackId)).length;
 openDialog('Create a playable local playlist',`<form id="catalog-playlist-form"><label for="playlist-name">Playlist name</label><input id="playlist-name" type="text" maxlength="120" value="${esc((item.title||'Imported playlist').slice(0,120))}" required><p><strong>${ids.length} unique local audio ${ids.length===1?'file':'files'}</strong> can be added in source order. ${item.entries.length-matchedRows} unmatched or unavailable ${item.entries.length-matchedRows===1?'entry is':'entries are'} omitted. ${matchedRows-ids.length} repeated matched ${matchedRows-ids.length===1?'row is':'rows are'} kept in the report and added only once to the local playlist.</p>${buttons('Create local playlist')}<div class="form-error" role="alert"></div></form>`);
 $('#catalog-playlist-form').onsubmit=async event=>{
  event.preventDefault();const form=event.currentTarget,name=$('#playlist-name').value.trim();if(!name)return;
  const submit=form.querySelector('[type=submit]');submit.disabled=true;
  try{
   const fresh=await api(`/api/catalogs/${encodeURIComponent(item.id)}`),id=crypto.randomUUID();let count=0;
   await saveState(state=>{const trackIds=matchedCatalogIds(fresh,state);if(!trackIds.length)throw new Error('No matched local audio is currently available. Add audio or refresh the report first.');count=trackIds.length;return {playlists:[...state.playlists,{id,name,trackIds}]};});
   view=`playlist:${id}`;search='';$('#search').value='';closeDialog();render();toast(`Created a playlist with ${count} unique local audio files. The full report is preserved.`);
  }catch(error){form.querySelector('.form-error').textContent=error.message;submit.disabled=false;}
 };
}
function albumCards(items){return `<div class="album-grid">${items.map(a=>`<button class="album-card" data-action="album" data-album="${esc(a.name)}">${art(a.tracks[0])}<strong>${esc(a.name)}</strong><small>${esc(a.artist)} · ${a.tracks.length} ${a.tracks.length===1?'track':'tracks'}</small></button>`).join('')}</div>`;}
function emptyState(title,description){return `<div class="empty-state"><div class="empty-icon">${icon(view==='favorites'?'heart':'music')}</div><h3>${esc(title)}</h3><p>${esc(description)}</p>${search||view==='favorites'?'':`<button class="button primary" data-action="${view.startsWith('playlist:')?'edit-playlist':'add'}">${icon('plus')} ${view.startsWith('playlist:')?'Choose tracks':'Add music'}</button>${view==='library'?'<button class="button secondary" data-action="demo">Try original soundcheck</button>':''}`}</div>`;}
function trackTable(tracks){return `<div class="table-wrap"><table class="track-table"><thead><tr><th>#</th><th>TITLE</th><th>ALBUM</th><th class="duration-cell">${icon('clock')}</th><th aria-label="Track actions"></th></tr></thead><tbody>${tracks.map((t,i)=>`<tr class="${t.id===currentId?'is-playing':''}"><td class="row-index">${currentId===t.id?'♫':String(i+1).padStart(2,'0')}</td><td class="track-title"><button class="track-play ${currentId===t.id?'playing':''}" data-action="play" data-id="${esc(t.id)}" aria-label="Play ${esc(t.title)}">${art(t)}<span><strong>${esc(t.title)}</strong><small>${esc(t.artist)}${t.isDemo?' · Original demo':''}</small></span></button></td><td class="muted">${esc(t.album)}</td><td class="duration-cell">${t.duration?time(t.duration):'—'}</td><td><div class="row-tools"><button class="icon-button ${library.favorites.includes(t.id)?'active':''}" data-action="favorite" data-id="${esc(t.id)}" aria-label="${library.favorites.includes(t.id)?'Unfavorite':'Favorite'} ${esc(t.title)}">${icon('heart')}</button><button class="icon-button track-tools" data-action="track-menu" data-id="${esc(t.id)}" aria-label="Options for ${esc(t.title)}">${icon('more')}</button></div></td></tr>`).join('')}</tbody></table></div>`;}
function renderTransfer(){
 $('#content').innerHTML=`<div class="page-heading"><div class="eyebrow">FROM YOUR COMPUTER. TO YOUR POCKET.</div><h1>Good music travels by cable.</h1><p>Prepare your collection here, then copy it into the iPhone app over USB.<br>Your phone keeps the files and plays them offline.</p></div><div class="transfer-grid"><section class="info-card warm"><div class="step-number">01 / PREPARE YOUR MUSIC</div><h2>Your next listening session, packed.</h2><p>Prepare ${library.tracks.length} audio ${library.tracks.length===1?'file':'files'}, a playlist backup, and a transfer report on this computer. Your originals stay in the library.</p><p><span class="badge">${bytes(library.stats?.bytes||0)} · LOCAL FILES</span></p><button class="button primary" data-action="export" ${library.tracks.length?'':'disabled'}>${icon('folder')} Prepare USB folder</button><div class="export-result" id="export-result">${exportInfo?exportMarkup():''}</div></section><section class="info-card"><div class="step-number">02 / COPY TO YOUR IPHONE</div><h2>Plug in. Copy over. Press play.</h2><ol><li>Connect your iPhone using a USB data cable and unlock it.</li><li>Open <strong>Apple Devices → your iPhone → Files → MusicCloud</strong> (or iTunes File Sharing).</li><li>Copy the prepared audio files and the named playlist backup into MusicCloud. Keep their filenames and wait for copying to finish.</li><li>Open MusicCloud on your iPhone and tap <strong>Rescan</strong>.</li><li>In the phone’s Transfer tab, choose <strong>Restore playlist backup</strong>, select the copied JSON, and review the replacement confirmation. Disconnect and listen offline.</li></ol></section></div><div class="note"><strong>Install the iPhone app first.</strong> The native app source is included in this project. Windows needs a remotely compiled IPA and a free signing tool such as AltServer to install it over USB. Free Apple signing must be renewed every seven days. Apple Devices transfers songs after installation; it does not install an IPA. Restoring this backup replaces the phone’s saved playlists and favorites. Export the phone’s backup first if you want to keep its current lists.</div><div class="info-card separated"><h2>Your computer is the source.</h2><p>There is no hosted app download, network music upload, subscription or streaming account. This tool prepares files; it cannot detect or control your USB connection. Installation and file sharing are handled by Apple’s tools. Cable transfer is a workflow, not protection against someone copying a file.</p></div>`;
}
function exportMarkup(){return `<strong>${exportInfo.count} audio files prepared</strong><code>${esc(exportInfo.path)}</code><button class="button secondary small" data-action="open-export">${icon('folder')} Open transfer folder</button><p>Copy the prepared audio and <strong>${esc(exportInfo.backupFile||'MusicCloud-playlists.json')}</strong>. This backup contains ${exportInfo.playlistCount??0} playlists and ${exportInfo.favoriteCount??0} favorites.</p><p>Source playlists include available local matches in their original order. ${exportInfo.repeatedRows??0} repeated rows are included once; ${exportInfo.omittedRows??0} missing, unavailable or ambiguous rows remain in <strong>${esc(exportInfo.reportFile||'the transfer report')}</strong>. Previously exported files may also be present; use the backup named above and keep the audio filenames.</p>`;}
async function playTrack(id,ids){const track=trackById(id);if(!track)return;if(ids)queue=ids.filter(x=>trackById(x));if(!queue.includes(id))queue.push(id);currentId=id;audio.src=`/audio/${encodeURIComponent(id)}`;audio.load();updatePlayer();render();try{await audio.play();}catch(e){toast(`Could not play “${track.title}”. The file may be damaged or unsupported by this browser.`,true);}}
function updatePlayer(){const t=trackById(currentId);$('#playing-title').textContent=t?.title||'Make room for your music';$('#playing-artist').textContent=t?.artist||'Choose a track to start listening';$('#player-art').className=`art mini-art art-${hash(t?.album||t?.title||'mc')%6}`;$('#player-art').innerHTML=`<span>${t?esc(t.title.slice(0,2)):'♪'}</span>`;$('#player-favorite').disabled=!t;$('#player-favorite').classList.toggle('active',!!t&&library.favorites.includes(t.id));$('#play-toggle').innerHTML=icon(audio.paused?'play':'pause');$('#play-toggle').setAttribute('aria-label',audio.paused?'Play':'Pause');$('#shuffle').classList.toggle('active',shuffle);$('#shuffle').setAttribute('aria-pressed',String(shuffle));$('#repeat').classList.toggle('active',repeat!=='off');$('#repeat').setAttribute('aria-label',`Repeat ${repeat}`);$('#repeat').title=`Repeat: ${repeat}${repeat==='one'?' (current track)':''}`;if(t&&'mediaSession'in navigator){navigator.mediaSession.metadata=new MediaMetadata({title:t.title,artist:t.artist,album:t.album});navigator.mediaSession.playbackState=audio.paused?'paused':'playing';}}
async function togglePlay(){if(!currentId){const t=filteredTracks()[0]||library.tracks[0];if(t)await playTrack(t.id,filteredTracks().map(t=>t.id));else toast('Add music or try an original soundcheck first.');return;}if(audio.paused){try{await audio.play();}catch{toast('Your browser could not play this file. Try MP3, M4A or WAV.',true);}}else audio.pause();}
async function advance(direction=1,ended=false){queue=queue.filter(trackById);if(!queue.length)return;if(direction<0&&audio.currentTime>3){audio.currentTime=0;return;}if(ended&&repeat==='one'){audio.currentTime=0;await audio.play();return;}let index=queue.indexOf(currentId),next=index+direction;if(shuffle&&direction>0&&queue.length>1){const pool=queue.filter(id=>id!==currentId);await playTrack(pool[Math.floor(Math.random()*pool.length)]);return;}if(next>=queue.length){if(repeat==='all')next=0;else{audio.pause();updatePlayer();return;}}if(next<0)next=queue.length-1;await playTrack(queue[next]);}
async function favorite(id){if(!trackById(id))return;await saveState(state=>({favorites:state.favorites.includes(id)?state.favorites.filter(x=>x!==id):[...state.favorites,id]}));}
function openDialog(title,html){$('#dialog-title').textContent=title;$('#dialog-body').innerHTML=html;if(!$('#dialog').open)$('#dialog').showModal();}
function closeDialog(){$('#dialog').close();}
function buttons(primary='Save'){return `<div class="dialog-actions"><button type="button" class="button secondary" data-action="close">Cancel</button><button type="submit" class="button primary">${primary}</button></div>`;}
function createPlaylist(){openDialog('Make a mix of your own',`<form id="playlist-form"><label for="playlist-name">Playlist name</label><input id="playlist-name" name="name" type="text" maxlength="120" placeholder="Sunday, on repeat" required>${buttons('Create playlist')}<div class="form-error" role="alert"></div></form>`);$('#playlist-form').onsubmit=async e=>{e.preventDefault();const name=$('#playlist-name').value.trim();if(!name)return;try{const p={id:crypto.randomUUID(),name,trackIds:[]};await saveState(state=>({playlists:[...state.playlists,p]}));view=`playlist:${p.id}`;closeDialog();render();editPlaylist();}catch(e){$('#dialog .form-error').textContent=e.message;}};}
function editPlaylist(){const p=library.playlists.find(p=>`playlist:${p.id}`===view);if(!p)return;openDialog('Edit playlist',`<form id="edit-playlist-form"><label for="playlist-name">Playlist name</label><input id="playlist-name" name="name" type="text" maxlength="120" value="${esc(p.name)}" required><p>Select the music for this mix. Existing track order is preserved.</p><div class="playlist-tracks">${library.tracks.map(t=>`<label><input type="checkbox" value="${esc(t.id)}" ${p.trackIds.includes(t.id)?'checked':''}>${esc(t.title)} <span class="muted">· ${esc(t.artist)}</span></label>`).join('')||'<p>Add music to your library first.</p>'}</div>${buttons()}<button type="button" class="text-button delete-playlist" data-action="delete-playlist">Delete this playlist</button><div class="form-error" role="alert"></div></form>`);$('#edit-playlist-form').onsubmit=async e=>{e.preventDefault();const name=$('#playlist-name').value.trim();if(!name)return;const selected=[...$('#edit-playlist-form').querySelectorAll('input[type=checkbox]:checked')].map(el=>el.value);const ids=[...p.trackIds.filter(id=>selected.includes(id)),...selected.filter(id=>!p.trackIds.includes(id))];try{await saveState(state=>({playlists:state.playlists.map(x=>x.id===p.id?{...x,name,trackIds:ids}:x)}));closeDialog();}catch(e){$('#dialog .form-error').textContent=e.message;}};}
function trackMenu(id){const t=trackById(id);if(!t)return;openDialog(t.title,`<p>${esc(t.artist)} · ${esc(t.album)}</p><div class="dialog-menu"><button class="button" data-action="edit-track" data-id="${esc(id)}">Edit track details</button><button class="button" data-action="add-to-playlist" data-id="${esc(id)}">Add to playlist</button><button class="button" data-action="queue-track" data-id="${esc(id)}">Add to play queue</button><a class="button" href="/api/download/${encodeURIComponent(id)}" download>Save audio file</a><button class="button delete-playlist" data-action="delete-track" data-id="${esc(id)}">Remove from computer library</button></div>`);}
function editTrack(id){const t=trackById(id);openDialog('Edit track details',`<form id="edit-track-form">${['title','artist','album'].map(field=>`<label for="edit-${field}">${field[0].toUpperCase()+field.slice(1)}</label><input id="edit-${field}" type="text" maxlength="200" value="${esc(t[field])}" required>`).join('')}<p>These details are saved in the computer library. Original audio tags remain unchanged.</p>${buttons()}<div class="form-error" role="alert"></div></form>`);$('#edit-track-form').onsubmit=async e=>{e.preventDefault();try{const values=Object.fromEntries(['title','artist','album'].map(f=>[f,$(`#edit-${f}`).value.trim()]));await api(`/api/tracks/${id}`,{method:'PATCH',body:JSON.stringify(values)});await refresh();closeDialog();}catch(e){$('#dialog .form-error').textContent=e.message;}};}
function addToPlaylist(id){openDialog('Add to playlist',library.playlists.length?`<div class="dialog-menu">${library.playlists.map(p=>`<button class="button" data-action="choose-playlist" data-id="${esc(p.id)}" data-track="${esc(id)}">${esc(p.name)} ${p.trackIds.includes(id)?'· already added':''}</button>`).join('')}</div>`:'<p>Create a playlist from the + beside Playlists, then add this track.</p>');}
function confirmDeleteTrack(id){const t=trackById(id);openDialog('Remove this track?',`<p>This removes <strong>${esc(t.title)}</strong>, its stored audio copy, and its entries in computer playlists. Your original upload and any USB copies are unaffected.</p><div class="dialog-actions"><button class="button secondary" data-action="close">Keep track</button><button class="button danger" data-action="confirm-delete-track" data-id="${esc(id)}">Remove track</button></div>`);}
function showQueue(){openDialog('Up next',`<p>${queue.length} tracks in this listening session.</p><div class="playlist-tracks">${queue.map((id,i)=>{const t=trackById(id);return t?`<div class="queue-item"><span>${currentId===id?'♫':i+1}</span><button data-action="queue-play" data-id="${esc(id)}">${esc(t.title)}<br><span>${esc(t.artist)}</span></button></div>`:'';}).join('')||'<p>Play a track to start a queue.</p>'}</div>`);}
function about(){openDialog('Made for your own collection',`<p>MusicCloud is a local music manager and native iPhone app project. No advertisements, analytics, remote music services or paid runtime dependencies.</p><p><strong>Maintain it yourself:</strong> all editable source is in the MusicCloud folder. Back up <code>desktop/data</code> to preserve your computer library, music, favorites and playlists. See the included docs for installation, backups and updates.</p><p>The iPhone app needs a macOS build and free Apple signing. A remote macOS builder and AltServer on Windows can provide that route. Free signing expires after seven days; renew by USB. Initial building, signing and downloading tools require internet.</p><p>No commercial songs or artwork are bundled. The optional soundcheck is an original synthesized melody. Import audio you are allowed to use. Formats supported by the computer browser and by the iPhone can differ.</p><p><strong>Your version:</strong> MusicCloud 1.0 · Local personal edition</p>`);}
async function upload(files){if(uploading){toast('An import is already running.');return;}const list=[...files];if(!list.length)return;uploading=true;let added=0,duplicates=0,failed=0;$('#add-top').disabled=true;for(let i=0;i<list.length;i++){toast(`Importing ${i+1}/${list.length}: ${list[i].name}`);try{const result=await api('/api/tracks',{method:'POST',headers:{'X-File-Name':encodeURIComponent(list[i].name),'Content-Type':'application/octet-stream'},body:list[i]});if(result.duplicate)duplicates++;else added++;}catch(e){failed++;toast(`${list[i].name}: ${e.message}`,true);}}uploading=false;$('#add-top').disabled=false;$('#file-input').value='';await refresh();toast(`${added} added${duplicates?`, ${duplicates} duplicates skipped`:''}${failed?`, ${failed} failed`:''}.`,failed>0);}
async function action(name,el){
 switch(name){
 case'import-catalog':$('#catalog-file-input').click();break;
 case'open-catalog':await openCatalog(el.dataset.id);break;
 case'catalog-list':catalogId=null;catalogDetail=null;catalogError='';catalogPage=0;search='';$('#search').value='';render();break;
 case'reload-catalog':await refresh();toast('Playlist matches refreshed against your current local audio.');break;
 case'catalog-play':await playTrack(el.dataset.id,matchedCatalogIds(catalogDetail,library));break;
 case'catalog-playlist':createCatalogPlaylist();break;
 case'download-catalog':downloadCatalog();break;
 case'catalog-previous':catalogPage=Math.max(0,catalogPage-1);renderCatalogs();break;
 case'catalog-next':catalogPage++;renderCatalogs();break;
 case'add':$('#file-input').click();break;
 case'demo':{const result=await api('/api/demo',{method:'POST'});await refresh();await playTrack(result.track.id,[result.track.id]);toast('Playing an original synthesized soundcheck.');break;}
 case'play':await playTrack(el.dataset.id,filteredTracks().map(t=>t.id));break;
 case'play-all':{const list=filteredTracks();if(list.length)await playTrack(list[0].id,list.map(t=>t.id));break;}
 case'favorite':await favorite(el.dataset.id);break;
 case'playlist':view=`playlist:${el.dataset.id}`;albumFilter=null;render();break;
 case'view-albums':view='albums';render();break;
 case'album':view='albums';albumFilter=el.dataset.album;render();break;
 case'clear-album':albumFilter=null;render();break;
 case'track-menu':trackMenu(el.dataset.id);break;
 case'edit-track':editTrack(el.dataset.id);break;
 case'add-to-playlist':addToPlaylist(el.dataset.id);break;
 case'choose-playlist':await saveState(state=>({playlists:state.playlists.map(p=>p.id===el.dataset.id&&!p.trackIds.includes(el.dataset.track)?{...p,trackIds:[...p.trackIds,el.dataset.track]}:p)}));closeDialog();toast('Added to playlist.');break;
 case'queue-track':if(!queue.includes(el.dataset.id))queue.push(el.dataset.id);closeDialog();toast('Added to queue.');break;
 case'queue-play':await playTrack(el.dataset.id);closeDialog();break;
 case'edit-playlist':editPlaylist();break;
 case'delete-playlist':{const p=library.playlists.find(p=>`playlist:${p.id}`===view);openDialog('Delete playlist?',`<p>Delete “${esc(p?.name)}”? Audio files stay in your library.</p><div class="dialog-actions"><button class="button secondary" data-action="close">Keep playlist</button><button class="button danger" data-action="confirm-delete-playlist">Delete playlist</button></div>`);break;}
 case'confirm-delete-playlist':{const deletedView=view;await saveState(state=>({playlists:state.playlists.filter(p=>`playlist:${p.id}`!==deletedView)}));view='library';closeDialog();render();break;}
 case'delete-track':confirmDeleteTrack(el.dataset.id);break;
 case'confirm-delete-track':if(currentId===el.dataset.id){audio.pause();audio.removeAttribute('src');audio.load();currentId=null;}await api(`/api/tracks/${el.dataset.id}`,{method:'DELETE'});queue=queue.filter(id=>id!==el.dataset.id);await refresh();closeDialog();toast('Track removed from the computer library.');break;
 case'export':el.disabled=true;try{exportInfo=await api('/api/export',{method:'POST'});renderTransfer();toast('USB folder prepared on your computer.');}finally{if(el.isConnected)el.disabled=false;}break;
 case'open-export':await api('/api/open-export',{method:'POST'});break;
 case'close':closeDialog();break;
 }
}
document.addEventListener('click',e=>{const button=e.target.closest('[data-action]');if(button)action(button.dataset.action,button).catch(e=>toast(e.message,true));});
$('#navigation').addEventListener('click',e=>{const el=e.target.closest('[data-view]');if(el){view=el.dataset.view;albumFilter=null;if(view==='catalogs'){catalogId=null;catalogDetail=null;catalogError='';search='';$('#search').value='';}render();}});
$('#search').addEventListener('input',e=>{search=e.target.value.toLowerCase().trim();catalogPage=0;if(view==='transfer')view='library';render();});
$('#add-top').onclick=()=>$('#file-input').click();$('#file-input').onchange=e=>upload(e.target.files).catch(e=>toast(e.message,true));
$('#catalog-file-input').onchange=e=>importCatalog(e.target.files[0]).catch(()=>toast('The playlist report could not be imported.',true));
$('#new-playlist').onclick=createPlaylist;$('#about-button').onclick=about;$('#dialog-close').onclick=closeDialog;
$('#dialog').addEventListener('click',e=>{if(e.target===$('#dialog')){const r=$('#dialog').getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeDialog();}});
$('#play-toggle').onclick=()=>togglePlay().catch(e=>toast(e.message,true));$('#next').onclick=()=>advance().catch(e=>toast(e.message,true));$('#previous').onclick=()=>advance(-1).catch(e=>toast(e.message,true));
$('#player-favorite').onclick=()=>favorite(currentId).catch(e=>toast(e.message,true));$('#queue-button').onclick=showQueue;$('#shuffle').onclick=()=>{shuffle=!shuffle;updatePlayer();toast(`Shuffle ${shuffle?'on':'off'}.`);};$('#repeat').onclick=()=>{repeat={off:'all',all:'one',one:'off'}[repeat];updatePlayer();toast(`Repeat ${repeat}.`);};
$('#volume').oninput=e=>audio.volume=Number(e.target.value);$('#seek').oninput=e=>{if(Number.isFinite(audio.duration)&&audio.duration>0)audio.currentTime=Number(e.target.value)/1000*audio.duration;};
audio.addEventListener('timeupdate',()=>{$('#elapsed').textContent=time(audio.currentTime);$('#seek').value=Number.isFinite(audio.duration)&&audio.duration>0?Math.round(audio.currentTime/audio.duration*1000):0;});
audio.addEventListener('loadedmetadata',()=>{$('#duration').textContent=time(audio.duration);const t=trackById(currentId);if(t&&Number.isFinite(audio.duration)&&Math.abs((t.duration||0)-audio.duration)>.5){t.duration=audio.duration;api(`/api/tracks/${t.id}`,{method:'PATCH',body:JSON.stringify({duration:audio.duration})}).then(()=>render()).catch(()=>{});}});
audio.addEventListener('play',updatePlayer);audio.addEventListener('pause',updatePlayer);audio.addEventListener('ended',()=>advance(1,true).catch(e=>toast(e.message,true)));audio.addEventListener('error',()=>{if(currentId)toast('Unable to read this audio. Try a compatible MP3, M4A or WAV file.',true);updatePlayer();});
document.addEventListener('keydown',e=>{if(e.target.matches('input,textarea,select')||$('#dialog').open)return;if(e.key==='/'){e.preventDefault();$('#search').focus();}if(e.code==='Space'&&!e.target.closest('button,a')){e.preventDefault();togglePlay().catch(e=>toast(e.message,true));}});
let dragDepth=0;document.addEventListener('dragenter',e=>{if(e.dataTransfer?.types.includes('Files')){e.preventDefault();dragDepth++;$('#drop-zone').hidden=false;}});document.addEventListener('dragover',e=>{if(e.dataTransfer?.types.includes('Files'))e.preventDefault();});document.addEventListener('dragleave',()=>{dragDepth=Math.max(0,dragDepth-1);if(!dragDepth)$('#drop-zone').hidden=true;});document.addEventListener('drop',e=>{e.preventDefault();dragDepth=0;$('#drop-zone').hidden=true;const files=e.dataTransfer?.files;if(!files?.length)return;if(view==='catalogs'&&files.length===1&&files[0].name.toLowerCase().endsWith('.json'))importCatalog(files[0]).catch(()=>toast('The playlist report could not be imported.',true));else upload(files).catch(e=>toast(e.message,true));});
if('mediaSession'in navigator){for(const [name,handler]of Object.entries({play:()=>audio.play().catch(()=>{}),pause:()=>audio.pause(),previoustrack:()=>advance(-1),nexttrack:()=>advance(1),seekto:e=>{if(Number.isFinite(e.seekTime))audio.currentTime=e.seekTime;}})){try{navigator.mediaSession.setActionHandler(name,handler);}catch{}}}
setInterval(refreshInBackground,12000);
window.addEventListener('focus',scheduleBackgroundRefresh);
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')scheduleBackgroundRefresh();});
document.addEventListener('focusout',event=>{if(event.target.matches('input,textarea,select')||event.target.isContentEditable)scheduleBackgroundRefresh();});
$('#dialog').addEventListener('close',scheduleBackgroundRefresh);
refresh().catch(e=>{$('#content').innerHTML=`<div class="empty-state"><h3>MusicCloud could not load</h3><p>${esc(e.message)}. Keep the local server running and reload this page.</p></div>`;});
