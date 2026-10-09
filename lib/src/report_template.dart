/// Bundled report UI. All values are inserted through textContent or escaped JSON.
/// Keep this template free of remote scripts, fonts, and other network requests.
const reportHtmlTemplate = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>Runalong · Performance report</title>
<style>

:root {
  --bg:#0b1020;
  --panel:#151d31;
  --ink:#edf2ff;
  --muted:#a9b8d5;
  --line:#31405f;
  --build:#6de4c5;
  --raster:#9faaff;
  --bad:#ffad99;
  --good:#70dbb5;
  --focus:#ffdc8a}
* {
  box-sizing:border-box}
body {
  margin:0;
  background:var(--bg);
  color:var(--ink);
  font:15px/1.6 system-ui,sans-serif}
main {
  max-width:1240px;
  margin:auto;
  padding:32px 24px 80px}
a {
  color:var(--build)}
h1 {
  font-size:clamp(30px,5vw,46px);
  letter-spacing:-.04em;
  line-height:1.15;
  margin:10px 0}
h2 {
  font-size:21px;
  margin:0 0 8px}
h3 {
  font-size:16px;
  margin:0}
p {
  margin:8px 0}
.eyebrow {
  font:700 12px/1.4 ui-monospace,monospace;
  letter-spacing:.16em;
  text-transform:uppercase;
  color:var(--build)}
.muted,small {
  color:var(--muted)}
.hero {
  display:flex;
  justify-content:space-between;
  gap:20px;
  align-items:center;
  margin-bottom:24px}
.badge {
  display:inline-flex;
  border:1px solid var(--line);
  border-radius:30px;
  padding:5px 12px;
  font-size:12px}
.badge.pass,.badge.complete,.badge.succeeded {
  color:var(--good)}
.badge.fail,.badge.failed,.badge.partial {
  color:var(--bad)}
.grid {
  display:grid;
  grid-template-columns:repeat(3,1fr);
  gap:14px}
.card,section {
  background:var(--panel);
  border:1px solid var(--line);
  border-radius:14px;
  padding:20px}
.card strong {
  display:block;
  font-size:28px;
  margin-top:6px}
.card .status {
  margin-top:12px}
section {
  margin-top:18px}
.row {
  display:flex;
  gap:16px;
  align-items:center;
  justify-content:space-between;
  flex-wrap:wrap}
.legend {
  display:flex;
  gap:16px;
  font-size:13px}
.build {
  color:var(--build)}
.raster {
  color:var(--raster)}
svg {
  display:block;
  width:100%;
  height:auto;
  margin-top:18px;
  overflow:visible}
.controls {
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:20px;
  margin-top:16px}
input[type=range] {
  width:100%;
  accent-color:var(--build)}
input,select,button {
  font:inherit;
  color:var(--ink);
  background:var(--bg);
  border:1px solid var(--line);
  border-radius:6px;
  padding:6px 10px}
button {
  cursor:pointer}
button:disabled {
  opacity:.4;
  cursor:default}
:focus-visible {
  outline:3px solid var(--focus);
  outline-offset:3px}
table {
  border-collapse:collapse;
  width:100%;
  text-align:left;
  font-size:13px}
th,td {
  padding:11px 8px;
  border-bottom:1px solid var(--line);
  white-space:nowrap}
th {
  color:var(--muted);
  font-weight:500}
td:first-child {
  font-weight:600}
.table-scroll {
  overflow-x:auto}
details {
  margin-top:14px}
summary {
  cursor:pointer;
  color:var(--build)}
pre {
  white-space:pre-wrap;
  overflow-wrap:anywhere;
  font-size:12px;
  max-height:400px;
  overflow:auto}
.notice {
  border-left:3px solid var(--bad);
  padding:8px 14px;
  margin:14px 0;
  background:var(--bg);
  border-radius:4px}
.mono {
  font-family:ui-monospace,monospace}
.split {
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:18px}
.pagination {
  display:flex;
  gap:12px;
  align-items:center;
  margin-top:16px}
.navlist {
  max-height:260px;
  overflow:auto;
  padding-left:22px}
.skip {
  position:absolute;
  top:-50px}
.skip:focus {
  top:0;
  background:var(--bg);
  padding:10px}
footer {
  margin-top:28px;
  font-size:12px;
  color:var(--muted)}
@media(max-width:700px) {
  main {
  padding:22px 14px 40px}
.grid,.split {
  grid-template-columns:1fr}
.hero {
  display:block}
.hero .badge {
  margin-top:12px}
.controls {
  grid-template-columns:1fr}
.card {
  padding:16px}
.card strong {
  font-size:22px}
}
@media(prefers-color-scheme:light) {
  :root {
  --bg:#f4f6fc;
  --panel:#fff;
  --ink:#17213b;
  --muted:#52617c;
  --line:#d2dbea;
  --build:#00765c;
  --raster:#5550be;
  --bad:#a83c24;
  --good:#007754;
  --focus:#956000}
}


</style>
</head>
<body>
<a class="skip" href="#timeline">Skip to frame timeline</a>
<main>
<header class="hero">
<div>
<div class="eyebrow">Runalong / Run report</div>
<h1>Make smoothness measurable.</h1>
<p class="muted" id="run-meta">
</p>
</div>
<span class="badge">Offline · local data</span>
</header>
<div class="grid" id="statuses">
</div>
<section id="coverage">
<h2>Capture confidence</h2>
<p id="coverage-description">
</p>
<div id="warnings">
</div>
<details>
<summary>Environment and coverage details</summary>
<pre id="metadata">
</pre>
</details>
</section>
<section id="timeline">
<div class="row">
<div>
<h2>Frame timeline</h2>
<p class="muted">Select an interval to inspect individual frames. Build and raster are separate phases.</p>
</div>
<div class="legend">
<span class="build">● Build</span>
<span class="raster">● Raster</span>
</div>
</div>
<label for="segment">Capture segment / isolate</label> <select id="segment">
</select>
<svg id="chart" viewBox="0 0 1000 260" role="img" aria-label="Build and raster frame durations with refresh-rate budget">
</svg>
<div class="controls">
<label for="start">First frame <output id="start-label">
</output>
<input id="start" type="range" min="0" value="0" step="1">
</label>
<label for="end">Last frame <output id="end-label">
</output>
<input id="end" type="range" min="0" value="0" step="1">
</label>
</div>
<p id="selection" aria-live="polite" class="muted">
</p>
</section>
<section>
<h2>Rendering distributions</h2>
<p class="muted">Nearest-rank percentiles for the selected interval. A frame exceeds the budget when either phase exceeds it.</p>
<div class="table-scroll">
<table>
<thead>
<tr>
<th scope="col">Phase</th>
<th scope="col">p50</th>
<th scope="col">p90</th>
<th scope="col">p95</th>
<th scope="col">p99</th>
<th scope="col">Max</th>
</tr>
</thead>
<tbody id="distribution">
</tbody>
</table>
</div>
</section>
<section>
<div class="row">
<div>
<h2>Frame inspector</h2>
<p class="muted">Sorted by selected interval order. Detailed rows are paginated.</p>
</div>
<label>
<input type="checkbox" id="slow-only"> Only over-budget frames</label>
</div>
<div class="table-scroll">
<table>
<thead>
<tr>
<th scope="col">Frame</th>
<th scope="col">Since segment start</th>
<th scope="col">Build</th>
<th scope="col">Raster</th>
<th scope="col">Budget</th>
</tr>
</thead>
<tbody id="frame-table">
</tbody>
</table>
</div>
<div class="pagination">
<button id="previous" type="button">Previous</button>
<span id="page" aria-live="polite">
</span>
<button id="next" type="button">Next</button>
</div>
</section>
<div class="split">
<section>
<h2>Navigation hints</h2>
<p class="muted">Approximate host receive times, shown separately from engine frame timestamps. These are not exact action boundaries.</p>
<ol id="navigation" class="navlist">
</ol>
</section>
<section>
<h2>Budget and baseline</h2>
<p id="gate-status">
</p>
<div id="gate-reasons">
</div>
<div id="comparison">
</div>
</section>
</div>
<section>
<h2>Inspect the evidence</h2>
<p class="muted">All values come from this run. Missing measurements stay unavailable.</p>
<details>
<summary>Summary JSON (full samples are in report.json)</summary>
<pre id="raw">
</pre>
</details>
</section>
<footer>Runalong 0.1.0 preview · Frame cadence is not display presentation FPS. Idle periods are not dropped frames. Route attribution is approximate.</footer>
</main>
<script id="runalong-data" type="application/json">RUNALONG_JSON_PAYLOAD</script><script>
'use strict';
const report=JSON.parse(document.getElementById('runalong-data').textContent),$=id=>document.getElementById(id),frames=report.frames||[],budget=report.metrics.budgetMs;
const fmt=v=>typeof v==='number'&&Number.isFinite(v)?v.toFixed(2):'unavailable';
const text=(id,value)=>$(id).textContent=String(value);
function element(tag,content,cls){
  const e=document.createElement(tag);
  if(content!==undefined)e.textContent=String(content);
  if(cls)e.className=cls;
  return e
}
text('run-meta',(report.id||'Run')+' · '+(report.startedAt||'Time unavailable'));
for(const [label,status,detail] of [['Automation',report.automation?.status||'not run',report.automation?.exitCode==null?'Independent capture':'Exit code '+report.automation.exitCode],['Capture',report.capture?.status||'unavailable',frames.length+' unique frames'],['Budget',report.budget?.status||'disabled',budget==null?'Refresh budget unavailable':fmt(budget)+' ms per phase']]){
  const card=element('div',undefined,'card');
  card.append(element('div',label,'muted'),element('strong',status),element('div',detail,'muted'));
  $('statuses').append(card)
}
const cap=report.capture||{
}
;
text('coverage-description','Capture: '+(cap.startedAt||'unknown')+' → '+(cap.finishedAt||'unknown')+'. '+(report.environment?.buildMode||'unknown')+' build.');
for(const warning of [...(cap.warnings||[]),...(cap.gaps||[]).map(g=>typeof g==='string'?g:JSON.stringify(g))])$('warnings').append(element('p',warning,'notice'));
if(!frames.length)$('warnings').append(element('p','No frame samples available. The report cannot establish rendering performance.','notice'));
text('metadata',JSON.stringify({
  environment:report.environment,capture:cap
}
,null,2));
const groups=new Map();
for(const frame of frames){
  const key=frame.segment+' / '+frame.isolate;
  if(!groups.has(key))groups.set(key,[]);
  groups.get(key).push(frame)
}
for(const key of groups.keys()){
  const option=element('option',key);
  option.value=key;
  $('segment').append(option)
}
let selected=[],visible=[],page=0;
const pageSize=25;
function percentile(values,p){
  return values.length?values[Math.ceil(values.length*p)-1]:null
}
function update(){
  const group=groups.get($('segment').value)||[];
  let first=+$('start').value,last=+$('end').value;
  if(first>last){
    last=first;
    $('end').value=String(last)
  }
  selected=group.slice(first,last+1);
  text('start-label',group.length?first+1:0);
  text('end-label',group.length?last+1:0);
  const over=selected.filter(f=>budget!=null&&(f.buildMicros/1000>budget||f.rasterMicros/1000>budget)).length;
  let intervals=[];
  for(let i=1;
  i<selected.length;
  i++){
    const interval=(selected[i].startTimeMicros-selected[i].vsyncOverheadMicros-selected[i-1].startTimeMicros+selected[i-1].vsyncOverheadMicros)/1000;
    if(interval>0)intervals.push(interval)
  }
  intervals.sort((a,b)=>a-b);
  const median=percentile(intervals,.5);
  text('selection',selected.length+' frames selected · '+(budget==null?'Unknown refresh budget':over+' over budget ('+fmt(selected.length?over*100/selected.length:0)+'%)')+' · Median observed cadence: '+(median==null?'unavailable':fmt(1000/median)+' Hz')+' (includes idle time; not display FPS).');
  $('distribution').replaceChildren();
  for(const [label,key] of [['Build','buildMicros'],['Raster','rasterMicros']]){
    const values=selected.map(f=>f[key]/1000).sort((a,b)=>a-b),row=document.createElement('tr');
    for(const value of [label,...[.5,.9,.95,.99].map(p=>fmt(percentile(values,p))+' ms'),fmt(values.at(-1))+' ms'])row.append(element('td',value));
    $('distribution').append(row)
  }
  draw(selected);
  visible=$('slow-only').checked?selected.filter(f=>budget!=null&&(f.buildMicros/1000>budget||f.rasterMicros/1000>budget)):selected;
  page=0;
  renderTable()
}
function renderTable(){
  const group=groups.get($('segment').value)||[],origin=group[0]?.startTimeMicros||0;
  $('frame-table').replaceChildren();
  for(const f of visible.slice(page*pageSize,(page+1)*pageSize)){
    const row=document.createElement('tr'),over=budget!=null&&(f.buildMicros/1000>budget||f.rasterMicros/1000>budget);
    for(const value of [f.number,fmt((f.startTimeMicros-origin)/1000)+' ms',fmt(f.buildMicros/1000)+' ms',fmt(f.rasterMicros/1000)+' ms',budget==null?'Unknown':over?'Exceeded':'Within'])row.append(element('td',value));
    $('frame-table').append(row)
  }
  const pages=Math.max(1,Math.ceil(visible.length/pageSize));
  text('page',(page+1)+' / '+pages+' · '+visible.length+' frames');
  $('previous').disabled=page===0;
  $('next').disabled=page>=pages-1
}
function svgElement(tag,attrs,content){
  const e=document.createElementNS('http://www.w3.org/2000/svg',tag);
  for(const [k,v]of Object.entries(attrs))e.setAttribute(k,String(v));
  if(content!==undefined)e.textContent=content;
  return e
}
function draw(data){
  const svg=$('chart');
  svg.replaceChildren();
  if(!data.length){
    svg.append(svgElement('text',{
      x:50,y:110,fill:'currentColor'
    }
    ,'No frames in this interval'));
    return
  }
  const width=Math.max(240,svg.clientWidth-90),height=185,x0=65,y0=20,origin=data[0].startTimeMicros,span=Math.max(1,data.at(-1).startTimeMicros-origin);
  svg.setAttribute('viewBox','0 0 '+(width+90)+' 260');
  let peak=budget||0;
  for(const f of data)peak=Math.max(peak,f.buildMicros/1000,f.rasterMicros/1000);
  peak=Math.max(1,peak*1.12);
  for(let tick=0;
  tick<=4;
  tick++){
    const val=peak*tick/4,y=y0+height-height*tick/4;
    svg.append(svgElement('line',{
      x1:x0,y1:y,x2:x0+width,y2:y,stroke:'var(--line)'
    }
    ),svgElement('text',{
      x:0,y:y+4,fill:'var(--muted)','font-size':11
    }
    ,fmt(val)+' ms'))
  }
  if(budget!=null){
    const y=y0+height-budget/peak*height;
    svg.append(svgElement('line',{
      x1:x0,y1:y,x2:x0+width,y2:y,stroke:'var(--bad)','stroke-dasharray':'5 5'
    }
    ),svgElement('text',{
      x:x0+width,y:y-6,fill:'var(--bad)','font-size':11,'text-anchor':'end'
    }
    ,'Budget '+fmt(budget)+' ms'))
  }
  const step=Math.max(1,Math.ceil(data.length/2000));
  for(const [key,color]of [['buildMicros','var(--build)'],['rasterMicros','var(--raster)']]){
    const points=[];
    for(let i=0;
    i<data.length;
    i+=step){
      let worst=data[i];
      for(let j=i+1;
      j<Math.min(i+step,data.length);
      j++)if(data[j][key]>worst[key])worst=data[j];
      points.push((x0+(worst.startTimeMicros-origin)/span*width)+','+(y0+height-worst[key]/1000/peak*height))
    }
    if(points.length===1){
      const [cx,cy]=points[0].split(',');
      svg.append(svgElement('circle',{
        cx,cy,r:4,fill:color
      }
      ))
    }
    else svg.append(svgElement('polyline',{
      points:points.join(' '),fill:'none',stroke:color,'stroke-width':1.6
    }
    ))
  }
  svg.append(svgElement('text',{
    x:x0,y:238,fill:'var(--muted)','font-size':12
  }
  ,'0 ms'),svgElement('text',{
    x:x0+width,y:238,fill:'var(--muted)','font-size':12,'text-anchor':'end'
  }
  ,fmt(span/1000)+' ms · '+(step>1?'peak-preserving preview':'all selected samples')))
}
window.addEventListener('resize',()=>draw(selected));
function selectGroup(){
  const length=(groups.get($('segment').value)||[]).length;
  $('start').max=$('end').max=String(Math.max(0,length-1));
  $('start').value='0';
  $('end').value=String(Math.max(0,length-1));
  $('start').disabled=$('end').disabled=!length;
  update()
}
$('segment').addEventListener('change',selectGroup);
$('start').addEventListener('input',update);
$('end').addEventListener('input',()=>{
  if(+$('end').value<+$('start').value)$('start').value=$('end').value;
  update()
}
);
$('slow-only').addEventListener('change',update);
$('previous').addEventListener('click',()=>{
  page--;
  renderTable()
}
);
$('next').addEventListener('click',()=>{
  page++;
  renderTable()
}
);
selectGroup();
for(const event of report.navigation||[])$('navigation').append(element('li',(event.receivedAt||'Unknown time')+' · '+(event.routeName||'Unnamed route')));
if(!report.navigation?.length)$('navigation').append(element('li','No named navigation events captured.'));
text('gate-status','Budget status: '+report.budget.status);
for(const reason of report.budget.reasons||[])$('gate-reasons').append(element('p',reason,'notice'));
for(const check of report.budget.checks||[])$('gate-reasons').append(element('p',check.metric+': '+fmt(check.actual)+' / '+fmt(check.limit)+' · '+check.status));
if(report.comparison){
  $('comparison').append(element('h3','Baseline comparison'),element('p','Status: '+report.comparison.status));
  for(const [name,value]of Object.entries(report.comparison.metrics||{
  }
  ))$('comparison').append(element('p',name+' p95: '+fmt(value.baselineP95)+' → '+fmt(value.candidateP95)+' ms ('+fmt(value.changePercent)+'%)'));
  for(const reason of report.comparison.reasons||[])$('comparison').append(element('p',reason,'muted'))
}
const {
  frames:rawFrames,navigation:rawNavigation,...summary
}
=report;
text('raw',JSON.stringify(summary,null,2));
</script></body></html>''';
