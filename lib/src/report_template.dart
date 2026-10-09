/// Offline report: findings first, with measurements available as evidence.
/// Collected strings are only inserted through textContent or escaped JSON.
const reportHtmlTemplate = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Runalong · Rendering review</title>
<style>
:root{--bg:#f7f8f5;--panel:#fff;--ink:#172824;--muted:#576b63;--line:#dce4dd;--accent:#176a52;--soft:#eaf3ed;--build:#176a52;--raster:#6258a0;--warn:#8b461b;--warn-bg:#fff5e8;--focus:#a3531f;--shadow:0 8px 32px #18372a06}
*{box-sizing:border-box}p,li,.pill{overflow-wrap:anywhere}html{scroll-padding-top:24px}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 system-ui,-apple-system,sans-serif}a{color:var(--accent);text-underline-offset:4px}button,input,select,textarea{font:inherit}button,select{background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:9px 14px}button{cursor:pointer;font-weight:600}button:hover{border-color:var(--accent)}button:disabled{opacity:.5;cursor:default}button.primary{background:var(--accent);color:var(--panel);border-color:var(--accent)}:focus-visible{outline:3px solid var(--focus);outline-offset:4px}h1,h2,h3,p{margin:0}h1{font-size:clamp(30px,4.2vw,48px);line-height:1.13;letter-spacing:-.045em;max-width:850px;font-weight:650}h2{font-size:23px;line-height:1.3;letter-spacing:-.025em}h3{font-size:19px;line-height:1.35;letter-spacing:-.02em}p+p{margin-top:10px}small,.muted{color:var(--muted)}.wrap{max-width:1120px;margin:auto;padding:0 32px}.topbar{border-bottom:1px solid var(--line)}.topbar .wrap{display:flex;justify-content:space-between;align-items:center;gap:20px;padding-top:22px;padding-bottom:22px}.brand{font-size:21px;font-weight:750;letter-spacing:-.04em}.brand span{color:var(--accent);margin-right:8px}.topbar nav{display:flex;gap:24px;font-size:13px}.topbar a{text-decoration:none;color:var(--muted)}main{padding-bottom:56px!important}.hero{padding:34px 0 24px}.eyebrow{font-size:11px;text-transform:uppercase;letter-spacing:.14em;font-weight:750;color:var(--accent);margin-bottom:14px}.lead{font-size:17px;line-height:1.7;max-width:850px;margin-top:18px;color:var(--muted)}.context{display:flex;gap:8px;flex-wrap:wrap;margin:20px 0 16px}.pill{display:inline-flex;align-items:center;border:1px solid var(--line);border-radius:6px;padding:3px 9px;font-size:12px;gap:6px;color:var(--muted);background:var(--panel)}.pill.caution{background:var(--warn-bg);border-color:transparent;color:var(--warn)}.pill.good{color:var(--accent);background:var(--soft);border-color:transparent}.run-meta{font-size:12px;color:var(--muted);overflow-wrap:anywhere}.scope{border-left:3px solid var(--warn);padding:15px 18px;background:var(--warn-bg);border-radius:0 10px 10px 0;margin:4px 0 30px;font-size:14px}.scope strong{display:block;margin-bottom:3px}.scope p{color:var(--muted)}.section-heading{display:flex;justify-content:space-between;gap:20px;align-items:start;margin:34px 0 16px}.section-heading p{color:var(--muted);margin-top:6px;font-size:14px}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}.actions button{font-size:13px}.findings{display:grid;gap:14px}.finding{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:24px;box-shadow:var(--shadow);scroll-margin-top:22px}.finding:first-child{border-color:var(--accent);border-top-width:3px}.finding-top{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-bottom:12px}.finding-number{font:600 12px ui-monospace,monospace;color:var(--muted)}.finding .observation{font-size:16px;margin-top:11px;max-width:850px}.finding .route{color:var(--muted);font-size:13px;margin-top:8px}.finding-grid{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:20px;border-top:1px solid var(--line);padding-top:18px}.finding-grid .label{font-size:11px;letter-spacing:.07em;text-transform:uppercase;font-weight:750;margin-bottom:5px;color:var(--muted)}.finding-grid p{font-size:14px}.finding-grid .next{border-left:2px solid var(--accent);padding-left:14px}.evidence-strip{display:flex;gap:10px;flex-wrap:wrap;margin-top:17px;font-size:12px;color:var(--muted)}.empty{padding:24px;background:var(--soft);border-radius:12px}.panel{border:1px solid var(--line);border-radius:14px;background:var(--panel);padding:24px;margin-top:24px}.outcomes{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;margin-top:20px}.outcome h3{font-size:15px}.outcome p{font-size:13px;color:var(--muted);margin-top:5px}.outcome .pill{margin-bottom:8px}.explain{display:grid;grid-template-columns:1fr 1fr;gap:28px;margin-top:20px}.explain p{font-size:14px;color:var(--muted);margin-top:5px}details{margin-top:16px}summary{cursor:pointer;color:var(--accent);font-weight:600;line-height:1.5}summary small{display:block;font-weight:400;margin:5px 0 0 18px}.technical>summary{font-size:20px;letter-spacing:-.025em}.technical[open]>summary{padding-bottom:24px;border-bottom:1px solid var(--line);margin-bottom:24px}.technical h3{margin:28px 0 7px}.row{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:12px}.legend{display:flex;gap:16px;font-size:12px}.build{color:var(--build)}.raster{color:var(--raster)}#chart{display:block;width:100%;height:auto;margin-top:20px}.controls{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin:12px 0}input[type=range]{width:100%;accent-color:var(--accent)}.controls label{font-size:13px}output{font-weight:650}#selection{font-size:13px;margin-top:12px;color:var(--muted)}.table-scroll{overflow:auto;margin-top:12px}table{border-collapse:collapse;width:100%;text-align:left;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:11px 10px;white-space:nowrap}th{color:var(--muted);font-weight:600}td.phase-over{color:var(--warn);font-weight:650}.pagination{display:flex;align-items:center;gap:12px;margin-top:16px;font-size:13px}.subtle{color:var(--muted);font-size:13px}.notice{padding:10px 14px;background:var(--warn-bg);border-left:2px solid var(--warn);font-size:13px;margin:10px 0}.navlist{padding-left:20px;max-height:260px;overflow:auto;font-size:13px;color:var(--muted)}.limits{padding-left:20px;color:var(--muted);font-size:13px}.limits li+li{margin-top:7px}pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:400px;overflow:auto;font-size:12px;background:var(--bg);padding:18px;border-radius:8px;margin-top:12px}textarea{display:block;width:100%;min-height:190px;resize:vertical;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:14px;margin-top:12px;font-size:13px}footer{border-top:1px solid var(--line);margin-top:36px;padding-top:20px;font-size:12px;color:var(--muted)}.skip{position:absolute;top:-60px;left:12px}.skip:focus{top:8px;padding:10px;background:var(--panel);z-index:2}.sr-only{position:absolute;width:1px;height:1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}[hidden]{display:none!important}
@media(max-width:700px){.wrap{padding:0 18px}.topbar .wrap{padding-top:16px;padding-bottom:16px}.topbar nav{gap:14px}.hero{padding-top:30px}.lead{font-size:15px}.finding,.panel{padding:18px}.finding-grid,.explain,.controls,.outcomes{grid-template-columns:1fr;gap:16px}.finding-grid .next{margin-top:0}.section-heading{display:block}.section-heading>button{margin-top:14px}.finding .observation{font-size:15px}.topbar nav a:last-child{display:none}h2{font-size:21px}.pagination{flex-wrap:wrap}}
@media(prefers-color-scheme:dark){:root{--bg:#111a18;--panel:#192521;--ink:#edf3ef;--muted:#adbbb3;--line:#34463d;--accent:#99d2ad;--soft:#213c2d;--build:#99d2ad;--raster:#beb0ef;--warn:#f3ba88;--warn-bg:#32291f;--focus:#f3ba88;--shadow:none}button.primary{color:#11251a}}
@media print{body{background:white;color:black}.topbar nav,.actions,button,.controls{display:none}.finding{break-inside:avoid;box-shadow:none}.wrap{max-width:none}.technical:not([open]){display:none}}
RUNALONG_JOURNEY_STYLE
</style>
</head>
<body>
<a class="skip" href="#findings-title">Skip to findings</a>
<header class="topbar"><div class="wrap"><div class="brand"><span aria-hidden="true">↗</span>runalong</div><nav aria-label="Report sections"><a href="#overview">Overview</a><a href="#journey-panel" id="journey-link" hidden>Journey</a><a href="#findings-title">Findings</a><a href="#confidence">Capture quality</a></nav></div></header>
<main class="wrap">
<section class="hero" id="overview" aria-labelledby="headline">
<div class="eyebrow">Your rendering review</div>
<h1 id="headline">Reading this run…</h1>
<p class="lead" id="lead"></p>
<div class="context" id="context"></div>
<p class="run-meta" id="run-meta"></p>
<div class="actions"><button class="primary" id="inspect-worst" type="button">Inspect the slowest frame</button><button id="copy-brief" type="button">Copy investigation brief</button></div>
<p id="copy-status" class="subtle" role="status" aria-live="polite"></p>
<div id="copy-fallback" hidden><label for="brief-text">Investigation brief — select and copy</label><textarea id="brief-text" readonly></textarea></div>
</section>
<div class="scope" id="scope"><strong id="scope-title"></strong><p id="scope-description"></p></div>
RUNALONG_JOURNEY_HTML
<section aria-labelledby="findings-title"><div class="section-heading"><div><h2 id="findings-title" tabindex="-1">Where to look first</h2><p id="findings-description"></p></div></div><div class="findings" id="findings"></div></section>
<section class="panel" id="confidence" aria-labelledby="confidence-title">
<h2 id="confidence-title">How much can this run tell you?</h2><div class="outcomes" id="outcomes"></div>
<div class="explain"><div><h3>Screen and widget context</h3><p id="screen-context"></p></div><div><h3>Why there is no FPS score</h3><p>Flutter reports time spent building and rasterizing captured frames. It does not report when every image reached the display. Idle time and missing samples would make a frames-per-second score misleading.</p></div></div>
<details><summary>Understand the capture limits</summary><ul class="limits" id="limits"></ul><div id="warnings"></div></details>
<details><summary>Environment and capture metadata</summary><pre id="metadata"></pre></details>
</section>
<details class="panel technical" id="technical"><summary>Explore the frame evidence<small>Timeline, individual samples, phase distributions, and navigation hints.</small></summary>
<section id="timeline" aria-labelledby="timeline-title"><div class="row"><div><h2 id="timeline-title" tabindex="-1">The frames behind the findings</h2><p class="subtle">Each mark is a captured sample. Empty stretches are not classified as dropped frames.</p></div><div class="legend"><span class="build">● UI / build</span><span class="raster">◇ Raster</span></div></div>
<div class="row" style="margin-top:18px"><label for="segment">Recording segment</label><select id="segment"></select><button id="reset-selection" type="button">Show entire segment</button></div>
<svg id="chart" viewBox="0 0 1000 260" role="img" aria-label="Captured build and raster durations"></svg>
<div class="controls"><label for="start">From <output id="start-label"></output><input id="start" type="range" min="0" value="0" step="1"></label><label for="end">To <output id="end-label"></output><input id="end" type="range" min="0" value="0" step="1"></label></div>
<p id="selection" aria-live="polite"></p><p class="subtle">Times start at the first captured frame within this segment and isolate, not at app launch. Frame numbers come from the engine and may have gaps.</p></section>
<section aria-labelledby="inspector-title"><div class="row"><h3 id="inspector-title">Inspect individual frames</h3><label><input type="checkbox" id="slow-only"> Only frames over budget</label><label for="sort">Order <select id="sort"><option value="worst">Slowest phase first</option><option value="time">Time order</option></select></label></div><p id="filter-note" class="subtle"></p><div class="table-scroll"><table><thead><tr><th scope="col">Frame</th><th scope="col">Segment time</th><th scope="col">UI / build</th><th scope="col">Raster</th><th scope="col">Frame budget</th></tr></thead><tbody id="frame-table"></tbody></table></div><div class="pagination"><button id="previous" type="button">Previous</button><span id="page" aria-live="polite"></span><button id="next" type="button">Next</button></div></section>
<section aria-labelledby="distribution-title"><h3 id="distribution-title">Typical work and the slower tail</h3><p class="subtle">For the selected samples. A p95 of 20 ms means at least 95% of captured values were at or below 20 ms. Build and raster are separate phases; their durations are not added.</p><div class="table-scroll"><table><thead><tr><th scope="col">Phase</th><th scope="col">p50</th><th scope="col">p90</th><th scope="col">p95</th><th scope="col">p99</th><th scope="col">Maximum</th></tr></thead><tbody id="distribution"></tbody></table></div></section>
<section><h3>Navigation hints</h3><p class="subtle">Host receipt times, not engine frame times. These events do not identify exact actions, and an unnamed event does not prove a screen change.</p><ol id="navigation" class="navlist"></ol></section>
</details>
<section class="panel" aria-labelledby="budget-title"><h2 id="budget-title">CI budgets and baseline</h2><p id="gate-status" style="margin-top:8px"></p><div id="gate-reasons"></div><div id="comparison"></div><details><summary>Report data for deeper investigation</summary><pre id="raw"></pre></details></section>
<footer>Runalong 0.1.0 preview · Generated locally from captured evidence. No AI service is needed for this review. Raw samples remain in report.json and events.jsonl.</footer>
<noscript><p class="notice">Enable JavaScript to explore this offline report, or open summary.md for the written findings.</p></noscript>
</main>
<script id="runalong-data" type="application/json">RUNALONG_JSON_PAYLOAD</script>
<script>
'use strict';
const $=id=>document.getElementById(id);
const report=JSON.parse($('runalong-data').textContent),frames=report.frames||[],metrics=report.metrics||{},budget=metrics.budgetMs;
const insights=report.insights||{},findings=insights.findings||[],cap=report.capture||{},env=report.environment||{};
const fmt=(v,digits=2)=>typeof v==='number'&&Number.isFinite(v)?v.toFixed(digits):'unavailable';
const text=(id,value)=>$(id).textContent=String(value);
function el(tag,value,cls){const node=document.createElement(tag);if(value!==undefined)node.textContent=String(value);if(cls)node.className=cls;return node;}
function addPill(parent,value,cls=''){parent.append(el('span',value,'pill '+cls));}
const finite=value=>typeof value==='number'&&Number.isFinite(value);
const over=f=>finite(budget)&&(f.buildMicros/1000>budget||f.rasterMicros/1000>budget);
const phasePeak=f=>Math.max(f.buildMicros,f.rasterMicros);
const groups=new Map();
const groupKey=f=>JSON.stringify([f.segment,f.isolate]);
for(const f of frames){const key=groupKey(f);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(f);}
for(const group of groups.values())group.sort((a,b)=>a.startTimeMicros-b.startTimeMicros||a.number-b.number);
const worst=frames.reduce((best,f)=>!best||phasePeak(f)>phasePeak(best)?f:best,null);
text('headline',insights.headline||'Explore the captured rendering evidence.');
text('lead',insights.summary||'The recorded samples are available below. Regenerate this report for written findings.');
addPill($('context'),env.buildMode==='profile'?'Profile build':env.buildMode==='debug'?'Debug build':'Build mode unknown',env.buildMode==='profile'?'':'caution');
addPill($('context'),cap.status==='complete'?'Complete capture':cap.status==='partial'?'Partial capture':'Capture unavailable',cap.status==='complete'?'':'caution');
addPill($('context'),frames.length+' captured frames');if(report.captureMode)addPill($('context'),report.captureMode==='diagnose'?'Instrumented diagnosis':'Measurement mode',report.captureMode==='diagnose'?'caution':'');
if(finite(metrics.captureDurationMs))addPill($('context'),fmt(metrics.captureDurationMs/1000,1)+' s capture window');
text('run-meta',(env.workload?'Journey: '+env.workload+' · ':'')+'Recorded '+(report.startedAt||'at an unknown time'));
const diagnostic=report.captureMode==='diagnose'||env.buildMode!=='profile'||cap.status!=='complete'||!frames.length;
text('scope-title',diagnostic?'Use this run to investigate, not to certify smoothness.':'A rendering check, with a defined capture window.');
text('scope-description',!frames.length?'No frame data was captured. A passing automation test alone cannot tell us how the interface rendered.':[
 report.captureMode==='diagnose'?'CPU collection and supported enhanced tracing can affect timings. Diagnostic captures are excluded from rendering gates.':null,
 env.buildMode==='debug'?'Debug instrumentation can change timings. Verify the same interaction in a profile build.':env.buildMode!=='profile'?'Build mode could not be verified; repeat in a profile build.':null,
 cap.status!=='complete'?'Some of the journey was outside the capture. Findings describe only the samples we received.':null,
 env.physical===false?'This target is an emulator or simulator; use a physical phone for mobile performance conclusions.':null,
 !diagnostic?'These findings concern captured frame work. They do not identify the responsible widget or measure display presentation FPS.':null
].filter(Boolean).join(' '));
text('findings-description',findings.length?'Start with these measured slow moments. Explanations suggest where to investigate; they do not claim a proven cause.':'The capture summary explains what is available. Open the evidence for the recorded samples.');
for(const [index,finding] of findings.entries()){
 const card=el('article',undefined,'finding');card.id='finding-'+index;
 const top=el('div',undefined,'finding-top');top.append(el('span',String(index+1).padStart(2,'0'),'finding-number'));
 addPill(top,index===0?'Start here':'Also worth inspecting',index===0?'good':'');
 if(finding.phase)addPill(top,finding.phase==='build'?'UI / build work':'Raster work');
 card.append(top,el('h3',finding.title),el('p',finding.observation,'observation'));
 if(finding.routeHint)card.append(el('p','Route hint: '+finding.routeHint+' · approximate, not a confirmed screen attribution.','route'));
 const grid=el('div',undefined,'finding-grid'),meaning=el('div'),next=el('div',undefined,'next');
 meaning.append(el('div','What this suggests','label'),el('p',finding.interpretation));
 next.append(el('div','Try next','label'),el('p',finding.nextStep));grid.append(meaning,next);
 if(index===0)card.append(grid);else{const explanation=el('details');explanation.append(el('summary','Interpretation and next step'),grid);card.append(explanation);}
 const e=finding.evidence;
 if(e){
  const strip=el('div',undefined,'evidence-strip');strip.append(el('span','Segment '+e.segment),el('span',(e.startMs===e.endMs?fmt(e.startMs/1000):fmt(e.startMs/1000)+'–'+fmt(e.endMs/1000))+' s from first captured frame'),el('span',e.slowFrameCount+' slow '+(e.slowFrameCount===1?'sample':'samples')+' in this moment'));card.append(strip);
  const actions=el('div',undefined,'actions'),button=el('button','Show these frames →');button.type='button';button.setAttribute('aria-label','Show frames for finding '+(index+1)+': '+finding.title);button.addEventListener('click',()=>inspectEvidence(e));actions.append(button);card.append(actions);
 }
 if(finding.attribution){const detail=el('details'),summary=el('summary','How this moment was identified');detail.append(summary,el('p',finding.attribution,'subtle'));card.append(detail);}
 $('findings').append(card);
}
if(!findings.length)$('findings').append(el('p',finite(budget)&&frames.length?(frames.some(over)?'Written findings are unavailable for these slow samples. Inspect the evidence or regenerate this report.':'No captured phase exceeded the refresh budget. This does not rule out delays outside the captured samples or in other parts of the app.'):!frames.length?'There are no frame measurements to investigate yet. Check the VM connection and rerun your existing test.':'The refresh budget is unknown, so this report cannot classify frames as over budget. Set the actual device refresh rate when recording.','empty'));
const automation=report.automation?.status||'not_started',gate=report.budget?.status||'disabled';
for(const [label,value,description,cls] of [
 ['Automation',automation==='passed'?'Tests passed':automation==='not_applicable'?'Observation only':automation==='failed'?'Tests failed':automation.replaceAll('_',' '),automation==='passed'?'Functional assertions passed. Rendering can still need attention.':automation==='not_applicable'?'No test result is claimed for this attached capture.':'Check the runner output for the functional result. Rendering findings are separate.',automation==='passed'?'good':'caution'],
 ['Capture',cap.status==='complete'?'Complete':cap.status==='partial'?'Some coverage missing':'No usable capture',cap.status==='complete'?'The recorder observed its defined window.':cap.status==='partial'?'Startup, teardown, or other gaps limit the conclusions.':'Check the VM connection before judging performance.',cap.status==='complete'?'good':'caution'],
 ['Performance gate',gate==='disabled'?'Not enabled':gate==='pass'?'Passed':gate==='fail'?'Failed':'Inconclusive',gate==='disabled'?'This is a diagnostic report; no CI performance pass is claimed.':gate==='inconclusive'?'Capture quality or configuration prevents a performance verdict.':'Configured limits are evaluated separately from the findings.',gate==='pass'?'good':gate==='fail'||gate==='inconclusive'?'caution':'']
]){const card=el('div',undefined,'outcome');addPill(card,value,cls);card.append(el('h3',label),el('p',description));$('outcomes').append(card);}
const nav=report.navigation||[],named=nav.filter(e=>typeof e.routeName==='string'&&e.routeName.trim());
text('screen-context',report.journey?.items?.length?'Explicit app and runner context is available in the journey above. Calibrated timing establishes overlap; source evidence has its own provenance and does not prove a cause.':named.length?'Named navigation events provide approximate route hints. Frame delivery is batched, so these hints cannot establish which widget, loading state, or user action caused a slow frame.':'Screen names were not included in this capture. Findings use time and frame references instead. Widget identity, loading state, and exact user actions were not recorded.');
for(const limit of insights.limitations||[])$('limits').append(el('li',limit));
for(const warning of cap.warnings||[])$('warnings').append(el('p',warning,'notice'));
for(const gap of cap.gaps||[]){const reason=typeof gap==='string'?gap:gap.reason||'Unspecified gap.';$('warnings').append(el('p','Coverage gap: '+reason,'notice'));}
text('metadata',JSON.stringify({runId:report.id,environment:env,capture:cap},null,2));
let groupIndex=0;
for(const [key,group] of groups){const option=el('option','Segment '+group[0].segment+' · stream '+(++groupIndex)+' · '+group.length+' frames');option.value=key;$('segment').append(option);}
let selected=[],visible=[],page=0;
const pageSize=20;
function percentile(values,p){return values.length?values[Math.ceil(values.length*p)-1]:null;}
function currentGroup(){return groups.get($('segment').value)||[];}
function update(){
 const group=currentGroup();let first=+$('start').value,last=+$('end').value;if(first>last){last=first;$('end').value=String(last);}
 selected=group.slice(first,last+1);
 for(const [id,index]of [['start',first],['end',last]]){const value=group[index]?'frame '+group[index].number+' (sample '+(index+1)+' of '+group.length+')':'no sample';text(id+'-label',value);$(id).setAttribute('aria-valuetext',value);}
 const count=selected.filter(over).length;
 text('selection',selected.length+' captured '+(selected.length===1?'frame':'frames')+' selected. '+(!finite(budget)?'Refresh budget unknown; over-budget classification is unavailable.':count+(count===1?' exceeds the ':' exceed the ')+fmt(budget)+' ms phase budget.'));
 $('distribution').replaceChildren();
 for(const [name,key]of [['UI / build','buildMicros'],['Raster','rasterMicros']]){const values=selected.map(f=>f[key]/1000).sort((a,b)=>a-b),row=el('tr');for(const value of [name,...[.5,.9,.95,.99].map(p=>finite(percentile(values,p))?fmt(percentile(values,p))+' ms':'—'),values.length?fmt(values.at(-1))+' ms':'—'])row.append(el('td',value));$('distribution').append(row);}
 draw(selected);visible=$('slow-only').checked?selected.filter(over):selected.slice();
 if($('sort').value==='worst')visible.sort((a,b)=>phasePeak(b)-phasePeak(a)||a.startTimeMicros-b.startTimeMicros);
 page=0;renderTable();
}
function renderTable(){
 const origin=currentGroup()[0]?.startTimeMicros||0;$('frame-table').replaceChildren();
 for(const f of visible.slice(page*pageSize,(page+1)*pageSize)){const row=el('tr',undefined,over(f)?'over':'');for(const [index,value] of [f.number,fmt((f.startTimeMicros-origin)/1e6)+' s',fmt(f.buildMicros/1000)+' ms',fmt(f.rasterMicros/1000)+' ms',!finite(budget)?'Unknown':over(f)?'Exceeded':'Within'].entries()){const cell=el('td',value);if(finite(budget)&&((index===2&&f.buildMicros/1000>budget)||(index===3&&f.rasterMicros/1000>budget)))cell.className='phase-over';row.append(cell);}$('frame-table').append(row);}
 if(!visible.length){const row=el('tr'),cell=el('td',selected.length?'No frames match this filter.':'No captured frames in this selection.');cell.colSpan=5;row.append(cell);$('frame-table').append(row);}
 const pages=Math.max(1,Math.ceil(visible.length/pageSize));text('page','Page '+(page+1)+' of '+pages+' · '+visible.length+' '+(visible.length===1?'frame':'frames'));$('previous').disabled=page===0;$('next').disabled=page>=pages-1;
}
function svgEl(tag,attrs,value){const e=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,String(v));if(value!==undefined)e.textContent=value;return e;}
function draw(data){
 const svg=$('chart');svg.replaceChildren();
 if(!data.length){svg.append(svgEl('text',{x:24,y:90,fill:'currentColor'},'No frame data in this interval.'));svg.setAttribute('aria-label','No frame data in this interval.');return;}
 const width=Math.max(230,svg.clientWidth-86),height=172,x0=58,y0=24,origin=data[0].startTimeMicros,segmentOrigin=currentGroup()[0].startTimeMicros,span=Math.max(1,data.at(-1).startTimeMicros-origin);
 svg.setAttribute('viewBox','0 0 '+(width+86)+' 250');svg.setAttribute('aria-label',data.length+' captured '+(data.length===1?'sample':'samples')+'. '+(finite(budget)?data.filter(over).length+' exceed the '+fmt(budget)+' millisecond phase budget.':'The refresh budget is unknown; no over-budget classification is available.'));
 let peak=finite(budget)?budget:0;for(const f of data)peak=Math.max(peak,phasePeak(f)/1000);peak=Math.max(1,peak*1.14);
 for(let tick=0;tick<=4;tick++){const val=peak*tick/4,y=y0+height-height*tick/4;svg.append(svgEl('line',{x1:x0,y1:y,x2:x0+width,y2:y,stroke:'var(--line)'}),svgEl('text',{x:0,y:y+4,fill:'var(--muted)','font-size':10},fmt(val,1)+' ms'));}
 if(finite(budget)){const y=y0+height-budget/peak*height;svg.append(svgEl('line',{x1:x0,y1:y,x2:x0+width,y2:y,stroke:'var(--warn)','stroke-dasharray':'5 5'}),svgEl('text',{x:x0+width,y:y-6,fill:'var(--warn)','font-size':10,'text-anchor':'end'},'Budget '+fmt(budget)+' ms'));}
 const step=Math.max(1,Math.ceil(data.length/650));
 for(const[key,color,offset]of [['buildMicros','var(--build)',-1.5],['rasterMicros','var(--raster)',1.5]]){
  for(let i=0;i<data.length;i+=step){let f=data[i];for(let j=i+1;j<Math.min(i+step,data.length);j++)if(data[j][key]>f[key])f=data[j];const x=x0+(f.startTimeMicros-origin)/span*width+offset,y=y0+height-f[key]/1000/peak*height;
   const mark=svgEl('line',{x1:x,y1:y0+height,x2:x,y2:y,stroke:color,'stroke-width':key==='buildMicros'?1.8:1.3});if(key==='rasterMicros')mark.setAttribute('stroke-dasharray','2 2');mark.append(svgEl('title',{},'Frame '+f.number+': '+(key==='buildMicros'?'build ':'raster ')+fmt(f[key]/1000)+' ms'));svg.append(mark);
  }
 }
 svg.append(svgEl('text',{x:x0,y:222,fill:'var(--muted)','font-size':11},fmt((origin-segmentOrigin)/1e6)+' s'),svgEl('text',{x:x0+width,y:222,fill:'var(--muted)','font-size':11,'text-anchor':'end'},fmt((data.at(-1).startTimeMicros-segmentOrigin)/1e6)+' s'));
 svg.append(svgEl('text',{x:x0,y:244,fill:'var(--muted)','font-size':10},'From first captured frame in this stream'+(step>1?' · peak-preserving preview':'')));
}
function selectGroup(){const length=currentGroup().length;$('start').max=$('end').max=String(Math.max(0,length-1));$('start').value='0';$('end').value=String(Math.max(0,length-1));$('start').disabled=$('end').disabled=$('segment').disabled=!length;update();}
function revealEvidence(){ $('technical').open=true;update();$('timeline-title').focus();$('timeline').scrollIntoView({block:'start',behavior:'auto'});}
function inspectEvidence(e){if(e.journeyItemId&&window.runalongSelectJourney){window.runalongSelectJourney(e.journeyItemId);return;}const key=groupKey(e),group=groups.get(key);if(!group)return;$('segment').value=key;selectGroup();const first=group.findIndex(f=>f.number===e.firstFrame),last=group.findIndex(f=>f.number===e.lastFrame);$('start').value=String(Math.max(0,first));$('end').value=String(last<0?Math.max(0,first):last);$('slow-only').checked=false;revealEvidence();}
$('inspect-worst').disabled=!worst;
$('inspect-worst').addEventListener('click',()=>{if(worst)inspectEvidence({...worst,firstFrame:worst.number,lastFrame:worst.number});});
$('technical').addEventListener('toggle',()=>{if($('technical').open)draw(selected);});
$('segment').addEventListener('change',selectGroup);$('reset-selection').addEventListener('click',selectGroup);
$('start').addEventListener('input',update);$('end').addEventListener('input',()=>{if(+$('end').value<+$('start').value)$('start').value=$('end').value;update();});
$('slow-only').disabled=!finite(budget);text('filter-note',finite(budget)?'Durations are measured separately. A sample is over budget if either phase exceeds the limit.':'The slow-frame filter is unavailable until a refresh-rate budget is known.');
$('slow-only').addEventListener('change',update);$('sort').addEventListener('change',update);
$('previous').addEventListener('click',()=>{page--;renderTable();});$('next').addEventListener('click',()=>{page++;renderTable();});
window.addEventListener('resize',()=>{if($('technical').open)draw(selected);});selectGroup();
for(const event of nav){const at=Date.parse(event.receivedAt),base=Date.parse(cap.startedAt);const time=Number.isFinite(at)&&Number.isFinite(base)&&at>=base?'Received +'+fmt((at-base)/1000)+' s':event.receivedAt||'Time unavailable';$('navigation').append(el('li',time+' · '+(event.routeName||'Unnamed navigation event')));}
if(!nav.length)$('navigation').append(el('li','No navigation events were captured.'));
text('gate-status',gate==='disabled'?'No performance gate was configured. The findings are diagnostic; they do not change the automation result.':'Configured performance gate: '+gate+'.');
for(const reason of report.budget?.reasons||[])$('gate-reasons').append(el('p',reason,'notice'));
for(const check of report.budget?.checks||[])$('gate-reasons').append(el('p',check.metric+': '+fmt(check.actual)+' / '+fmt(check.limit)+' · '+check.status,'subtle'));
if(report.comparison){$('comparison').append(el('h3','Baseline comparison'),el('p','Status: '+report.comparison.status));for(const[name,value]of Object.entries(report.comparison.metrics||{}))$('comparison').append(el('p',name+' p95: '+fmt(value.baselineP95)+' → '+fmt(value.candidateP95)+' ms ('+fmt(value.changePercent)+'%)'));for(const reason of report.comparison.reasons||[])$('comparison').append(el('p',reason,'subtle'));}
if(report.comparison?.journey){const panel=el('details');panel.append(el('summary','Compare named screens and operations'));for(const item of (report.comparison.journey.items||[]).slice(0,100)){const row=el('div',undefined,'journey-evidence-note');row.append(el('strong',item.label+' · '+item.status));for(const reason of item.reasons||[])row.append(el('p',reason));for(const[key,value]of Object.entries(item.reportingOnly||{})){if(finite(value.baseline)&&finite(value.candidate))row.append(el('p',key+': '+fmt(value.baseline)+' → '+fmt(value.candidate)+' (reporting only)'));}if(item.candidateItemId){const button=el('button','Inspect this occurrence');button.type='button';button.addEventListener('click',()=>window.runalongSelectJourney?.(item.candidateItemId));row.append(button);}panel.append(row);}$('comparison').append(panel);}
const {frames:rawFrames,navigation:rawNavigation,journey:rawJourney,sourceIndex:rawIndex,...summary}=report;if(rawJourney)summary.journey={itemCount:rawJourney.items?.length,alignedFrames:rawJourney.frames?.length,memorySamples:rawJourney.memory?.length,cpuBatches:rawJourney.cpu?.length,limitations:rawJourney.limitations};if(rawIndex)summary.sourceIndex={entries:rawIndex.entries?.length,revisionStatus:rawIndex.revisionStatus};text('raw',JSON.stringify(summary,null,2));
function investigationBrief(){return ['Investigate this Flutter rendering capture. Separate observations from possible causes.','Run: '+report.id,'Build: '+(env.buildMode||'unknown')+'; capture: '+(cap.status||'unknown')+'; automation: '+automation+'.',insights.headline||'',insights.summary||'',...(insights.limitations||[]),...findings.flatMap(f=>{const e=f.evidence;return ['',f.title,'Observed: '+f.observation,'Possible interpretation: '+f.interpretation,'Try next: '+f.nextStep,f.context?'Journey evidence: '+f.context.label+' ('+f.context.itemId+').':f.routeHint?'Approximate route hint: '+f.routeHint:'Screen/widget attribution unavailable.',e?'Evidence: segment '+e.segment+', isolate '+e.isolate+', frames '+e.firstFrame+'–'+e.lastFrame+', '+fmt(e.startMs)+'–'+fmt(e.endMs)+' ms from the first captured frame.':''];}),'','Use report.json and events.jsonl to verify these observations. Do not infer display FPS or a widget-level cause from these timings.'].join('\n');}
$('copy-brief').addEventListener('click',async()=>{const value=investigationBrief();try{await navigator.clipboard.writeText(value);text('copy-status','Investigation brief copied. It includes evidence and capture limits.');}catch(_){$('copy-fallback').hidden=false;$('brief-text').value=value;$('brief-text').focus();$('brief-text').select();text('copy-status','Automatic copying is unavailable here. Select and copy the brief below.');}});
RUNALONG_JOURNEY_SCRIPT
</script></body></html>''';
