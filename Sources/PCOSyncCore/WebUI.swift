// The dashboard page, served at /. One self-contained file: no external
// scripts, fonts or images, so it works with no internet connection.

let dashboardHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PCOSync</title>
<link rel="icon" href="data:,">
<style>
:root {
  --bg: #f5f5f7; --panel: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7;
  --accent: #0a66d8; --armed: #d70015; --ok: #1a7f37; --warn: #b25000; --chip: #ececf0;
  --live: #fff3c4; --live-line: #e0a800;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161618; --panel: #232326; --text: #f2f2f7; --muted: #a1a1a6; --line: #3a3a3e;
    --accent: #4c9bff; --armed: #ff5a5f; --ok: #3fbf5f; --warn: #ffa53d; --chip: #2f2f33;
    --live: #4a3d0a; --live-line: #e0a800;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
header { display: flex; align-items: center; gap: 12px; padding: 12px 20px; background: var(--panel);
  border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 2; flex-wrap: wrap; }
header h1 { font-size: 18px; margin: 0; }
nav { display: flex; gap: 4px; margin-left: auto; flex-wrap: wrap; }
nav button { background: none; border: 0; color: var(--muted); padding: 6px 12px; border-radius: 8px; font: inherit; cursor: pointer; }
nav button.on { background: var(--chip); color: var(--text); font-weight: 600; }
main { max-width: 1100px; margin: 0 auto; padding: 16px 20px 40px; }
.badge { font-weight: 700; font-size: 13px; letter-spacing: .04em; padding: 3px 10px; border-radius: 999px; background: var(--chip); color: var(--muted); }
.badge.armed { background: var(--armed); color: #fff; }
.badge.dry { background: var(--accent); color: #fff; }
.state { color: var(--muted); font-size: 14px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
.card h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 0 0 6px; font-weight: 600; }
.big { font-size: 22px; font-weight: 650; overflow-wrap: anywhere; }
.sub { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
.dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; background: var(--muted); }
.dot.ok { background: var(--ok); } .dot.bad { background: var(--armed); }
.row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
section { margin-top: 16px; }
button.b { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel); color: var(--text); cursor: pointer; }
button.b:hover { border-color: var(--accent); }
button.b:disabled { opacity: .45; cursor: default; }
button.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
button.danger { background: var(--armed); color: #fff; border-color: var(--armed); }
.banner { padding: 10px 14px; border-radius: 10px; margin-top: 12px; border: 1px solid var(--line); background: var(--panel); }
.banner.warn { border-color: var(--warn); }
.banner.err { border-color: var(--armed); }
ol.plan { list-style: none; margin: 0; padding: 0; }
ol.plan li { display: flex; gap: 10px; padding: 7px 10px; border-radius: 8px; border: 1px solid transparent; }
ol.plan li.header { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .05em; padding-top: 12px; }
ol.plan li.live { background: var(--live); border-color: var(--live-line); font-weight: 650; }
ol.plan .seq { color: var(--muted); width: 2.2em; text-align: right; flex: none; font-variant-numeric: tabular-nums; }
ol.plan .tag { margin-left: auto; font-size: 12px; color: var(--muted); }
.events { font-size: 13px; max-height: 340px; overflow: auto; }
.events div { padding: 5px 0; border-bottom: 1px solid var(--line); overflow-wrap: anywhere; }
.events .t { color: var(--muted); margin-right: 8px; font-variant-numeric: tabular-nums; }
.a-moved, .a-in_sync { color: var(--ok); } .a-refused, .a-error { color: var(--armed); } .a-dry_run { color: var(--accent); }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; overflow-wrap: anywhere; }
th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; }
.table-wrap { overflow-x: auto; }
pre.log { font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere;
  background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px; max-height: 70vh; overflow: auto; margin: 0; }
.lv-WARNING { color: var(--warn); } .lv-ERROR { color: var(--armed); } .lv-DEBUG { color: var(--muted); }
form fieldset { border: 1px solid var(--line); border-radius: 12px; padding: 12px 16px 16px; margin: 0 0 14px; background: var(--panel); }
legend { font-weight: 650; padding: 0 6px; }
label { display: block; margin-top: 10px; font-size: 14px; }
label.inline { display: flex; gap: 8px; align-items: center; }
.hint { color: var(--muted); font-size: 12px; }
input[type=text], input[type=number], input[type=password], select, textarea {
  width: 100%; font: inherit; padding: 7px 9px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); color: var(--text); margin-top: 4px; }
textarea { min-height: 90px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
.two { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 0 16px; }
#toast { position: fixed; bottom: 18px; left: 50%; transform: translateX(-50%); background: var(--text); color: var(--bg);
  padding: 9px 16px; border-radius: 10px; font-size: 14px; opacity: 0; transition: opacity .2s; pointer-events: none; max-width: 90vw; }
#toast.show { opacity: .95; }
.hidden { display: none !important; }
@media (max-width: 600px) { header { padding: 10px 16px; } main { padding: 12px 16px 32px; } .big { font-size: 19px; } }
</style>
</head>
<body>
<header>
  <h1>PCOSync</h1>
  <span id="mode" class="badge">…</span>
  <span id="state" class="state"></span>
  <nav>
    <button data-tab="dash" class="on">Dashboard</button>
    <button data-tab="mapping">Mapping</button>
    <button data-tab="settings">Settings</button>
    <button data-tab="log">Log</button>
  </nav>
</header>
<main>
<div id="tab-dash">
  <div id="setup" class="banner warn hidden"></div>
  <div class="grid" style="margin-top:12px">
    <div class="card"><h2><span id="pp-dot" class="dot"></span>ProPresenter</h2>
      <div id="pp-item" class="big">—</div><div id="pp-sub" class="sub"></div></div>
    <div class="card"><h2><span id="pco-dot" class="dot"></span>PCO LIVE</h2>
      <div id="live-item" class="big">—</div><div id="live-sub" class="sub"></div></div>
    <div class="card"><h2>Last action</h2>
      <div id="last" class="sub" style="font-size:14px;color:var(--text)">—</div><div id="last-t" class="sub"></div></div>
  </div>

  <section class="card">
    <h2>Control</h2>
    <div class="row">
      <button class="b primary" id="btn-dry">Start dry-run</button>
      <button class="b danger" id="btn-arm">Arm (move LIVE)…</button>
      <button class="b" id="btn-stop">Stop</button>
      <span style="width:12px"></span>
      <button class="b" id="btn-pause">Pause</button>
      <button class="b" id="btn-confirm" title="Allow the next move even if it's bigger than max jump">Confirm big move</button>
      <button class="b" id="btn-reload">Reload plan</button>
    </div>
    <div class="row" style="margin-top:10px">
      <span class="sub">Service time:</span>
      <button class="b" data-cmd="prev-service">◀ Previous</button>
      <span id="svc" class="sub" style="min-width:120px;text-align:center"></span>
      <button class="b" data-cmd="next-service">Next ▶</button>
      <button class="b" data-cmd="auto-service">Follow LIVE</button>
    </div>
    <div id="cmd-out" class="sub" style="margin-top:8px"></div>
  </section>

  <div class="grid" style="margin-top:16px; align-items:start">
    <section class="card" style="margin:0"><h2>Plan <span id="plan-id" class="sub"></span></h2><ol id="plan" class="plan"></ol></section>
    <section class="card" style="margin:0"><h2>Activity</h2><div id="events" class="events"></div></section>
  </div>
</div>

<div id="tab-mapping" class="hidden">
  <div class="row"><button class="b primary" id="btn-map">Refresh mapping</button>
    <span class="sub">Click an item in the service playlist in ProPresenter first. Read-only.</span></div>
  <div id="map-msg" class="sub" style="margin:10px 0"></div>
  <div class="table-wrap card"><table><thead><tr><th>#</th><th>ProPresenter item</th><th>Type</th><th>→ PCO item</th><th>How</th></tr></thead><tbody id="map-body"></tbody></table></div>
</div>

<div id="tab-settings" class="hidden">
  <form id="creds-form" autocomplete="off">
    <fieldset><legend>Planning Center credentials</legend>
      <div class="hint">Create a Personal Access Token at api.planningcenteronline.com/oauth/applications. The user needs permission to control LIVE. Stored only on this Mac (readable by your user account only), never shown again.</div>
      <div id="creds-state" class="sub" style="margin-top:6px"></div>
      <div class="two">
        <label>Application ID<input type="text" id="c-app" spellcheck="false"></label>
        <label>Secret<input type="password" id="c-secret" spellcheck="false"></label>
      </div>
      <div class="row" style="margin-top:12px"><button class="b primary" type="submit">Save &amp; test</button>
        <button class="b" type="button" id="btn-creds-clear">Remove</button></div>
    </fieldset>
  </form>
  <form id="cfg-form">
    <fieldset><legend>Planning Center</legend>
      <div class="two">
        <label>Service type<select id="f-st"></select><span class="hint"><a href="#" id="load-st">Load from Planning Center</a></span></label>
        <label>Plan<select id="f-plan"><option value="next">Next upcoming plan (recommended)</option></select><span class="hint"><a href="#" id="load-plans">Load plans</a></span></label>
      </div>
    </fieldset>
    <fieldset><legend>ProPresenter</legend>
      <div class="hint">ProPresenter › Settings › Network: turn on Network and note the port.</div>
      <div class="two">
        <label>Host<input type="text" id="f-host"></label>
        <label>Port<input type="number" id="f-port" min="1" max="65535"></label>
        <label>Poll every (seconds)<input type="number" id="f-poll" step="0.1" min="0.1"></label>
        <label>Timeout (seconds)<input type="number" id="f-timeout" step="0.5" min="0.5"></label>
      </div>
      <label>Only sync when the playlist name contains<input type="text" id="f-plfilter" placeholder="e.g. Sunday (empty = any playlist)"></label>
      <div class="row" style="margin-top:12px"><button class="b" type="button" id="btn-test">Test connections</button><span id="test-out" class="sub"></span></div>
    </fieldset>
    <fieldset><legend>Sync safety</legend>
      <div class="two">
        <label>Debounce (seconds)<input type="number" id="f-debounce" step="0.1" min="0"><span class="hint">ProPresenter must stay on an item this long before LIVE moves.</span></label>
        <label>Max jump (items)<input type="number" id="f-maxjump" min="1"><span class="hint">Bigger moves wait for “Confirm big move”.</span></label>
        <label>Resync every (seconds)<input type="number" id="f-resync" min="0"><span class="hint">0 = only when ProPresenter changes.</span></label>
        <label>Re-fetch plan every (seconds)<input type="number" id="f-refresh" min="0"></label>
      </div>
      <label class="inline"><input type="checkbox" id="f-takeover"> Take LIVE control even if a person already has it</label>
      <label class="inline"><input type="checkbox" id="f-release"> Give LIVE control back when stopping</label>
    </fieldset>
    <fieldset><legend>Matching</legend>
      <div class="two">
        <label>Never move LIVE for (one per line)<textarea id="f-ignore" spellcheck="false"></textarea><span class="hint">Exact names (case/punctuation ignored), or <code>regex:</code> patterns.</span></label>
        <label>Aliases (ProPresenter name = PCO title)<textarea id="f-aliases" spellcheck="false" placeholder="Way Maker (Live) = Way Maker"></textarea></label>
      </div>
      <label class="inline"><input type="checkbox" id="f-positional"> Match PCO-linked playlist entries by position when titles don't match</label>
    </fieldset>
    <fieldset><legend>App</legend>
      <label class="inline"><input type="checkbox" id="f-autostart"> Start syncing when the app launches</label>
      <label class="inline"><input type="checkbox" id="f-startarmed"> …and start armed (moves LIVE without anyone pressing Arm)</label>
      <div class="two">
        <label>Log level<select id="f-loglevel"><option>DEBUG</option><option>INFO</option><option>WARNING</option><option>ERROR</option></select></label>
        <label>Dashboard port<input type="number" id="f-webport" min="1024" max="65535"></label>
      </div>
      <label class="inline"><input type="checkbox" id="f-remote"> Allow other computers to open this dashboard (password required)</label>
      <label>Dashboard password<input type="password" id="f-webpw" autocomplete="new-password" placeholder="leave empty to keep the current one"></label>
      <div id="data-dir" class="hint" style="margin-top:8px"></div>
    </fieldset>
    <div class="row"><button class="b primary" type="submit">Save settings</button><span id="save-out" class="sub"></span></div>
  </form>
</div>

<div id="tab-log" class="hidden">
  <div class="row" style="margin-bottom:8px"><span id="log-file" class="sub"></span></div>
  <pre id="log" class="log"></pre>
</div>
</main>
<div id="toast"></div>

<script>
"use strict";
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let status = null, config = null, logAfter = 0, tab = "dash";

async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (method !== "GET") { opts.headers["X-PCOSync"] = "1"; opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(body || {}); }
  const r = await fetch(path, opts);
  let j = {};
  try { j = await r.json(); } catch (e) {}
  if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
  return j;
}
function toast(msg) { const t = $("toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 3500); }
const time = (iso) => { try { return new Date(iso).toLocaleTimeString(); } catch (e) { return ""; } };

document.querySelectorAll("nav button").forEach((b) => b.onclick = () => {
  tab = b.dataset.tab;
  document.querySelectorAll("nav button").forEach((x) => x.classList.toggle("on", x === b));
  ["dash", "mapping", "settings", "log"].forEach((t) => $("tab-" + t).classList.toggle("hidden", t !== tab));
  if (tab === "settings") loadConfig();
  if (tab === "mapping") loadMapping();
  if (tab === "log") pollLog();
});

function render(s) {
  status = s;
  const mode = $("mode");
  if (!s.running) { mode.textContent = "STOPPED"; mode.className = "badge"; }
  else if (s.armed) { mode.textContent = "ARMED"; mode.className = "badge armed"; }
  else { mode.textContent = "DRY-RUN"; mode.className = "badge dry"; }
  const labels = { stopped: "Not syncing", starting: "Starting…", running: s.paused ? "Paused" : "Syncing", waiting: "Waiting to connect", needs_setup: "Needs setup", stopping: "Stopping…" };
  $("state").textContent = labels[s.state] || s.state;

  const setup = $("setup");
  if (s.state === "needs_setup" || s.state === "waiting" || !s.hasCredentials) {
    setup.classList.remove("hidden");
    setup.textContent = s.detail || "Open Settings to enter your Planning Center credentials and service type.";
  } else setup.classList.add("hidden");

  const pp = s.propresenter || {};
  $("pp-dot").className = "dot " + (s.running ? (pp.ok ? "ok" : "bad") : "");
  $("pp-item").textContent = pp.item || "—";
  $("pp-sub").textContent = pp.error ? pp.error : (pp.playlist ? "Playlist: " + pp.playlist : "");

  const live = s.live || {};
  const items = s.items || [];
  const byId = Object.fromEntries(items.map((i) => [i.id, i]));
  const times = s.planTimes || [];
  $("pco-dot").className = "dot " + (s.running ? (live.ok ? "ok" : "bad") : "");
  let liveText = "—";
  if (live.itemId && byId[live.itemId]) liveText = byId[live.itemId].title;
  else if (live.serviceStart) liveText = "Service start";
  else if (live.controller !== undefined) liveText = "Not started";
  $("live-item").textContent = liveText;
  const ctrl = { none: "nobody has control", me: "PCOSync has control", other: "someone else has control" }[live.controller] || "";
  const svcN = live.planTimeRank !== undefined && times.length > 1 ? "Service " + (live.planTimeRank + 1) + " · " : "";
  $("live-sub").textContent = live.error ? live.error : svcN + ctrl;

  const ld = s.lastDecision;
  $("last").innerHTML = ld ? '<span class="a-' + esc(ld.action) + '">' + esc(ld.text) + "</span>" : "—";
  $("last-t").textContent = ld ? time(ld.time) : "";

  $("btn-dry").disabled = s.running && !s.armed;
  $("btn-arm").disabled = s.running && s.armed;
  $("btn-stop").disabled = !s.running;
  $("btn-pause").textContent = s.paused ? "Resume" : "Pause";
  ["btn-pause", "btn-confirm", "btn-reload"].forEach((id) => $(id).disabled = s.state !== "running");
  document.querySelectorAll("[data-cmd]").forEach((b) => b.disabled = s.state !== "running");
  $("btn-confirm").textContent = s.confirmPending ? "Big move allowed once" : "Confirm big move";

  const st = s.serviceTime || {};
  const nT = Math.max(times.length, 1);
  const eff = (st.effective ?? 0);
  const lbl = (r) => times[r] && times[r].startsAt ? new Date(times[r].startsAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : String(r + 1);
  $("svc").textContent = s.running ? ((st.selected === null || st.selected === undefined) ? "Following LIVE (" + lbl(eff) + ")" : lbl(st.selected) + " (" + (st.selected + 1) + " of " + nT + ")") : "";

  $("plan-id").textContent = s.planId ? "#" + s.planId : "";
  const planEl = $("plan");
  planEl.innerHTML = items.map((i) => {
    if (i.type === "header") return '<li class="header">' + esc(i.title) + "</li>";
    const isLive = live.itemId === i.id;
    return '<li class="' + (isLive ? "live" : "") + '"><span class="seq">' + esc(i.sequence) + "</span><span>" + esc(i.title) + "</span>" + (isLive ? '<span class="tag">LIVE</span>' : "") + "</li>";
  }).join("") || '<li class="sub">Plan loads when syncing starts.</li>';

  const ev = (s.events || []).slice().reverse();
  $("events").innerHTML = ev.map((e) => '<div><span class="t">' + esc(time(e.time)) + '</span><span class="a-' + esc(e.action) + '">' + esc(e.text) + "</span></div>").join("") || '<div class="sub">Nothing yet.</div>';
}

async function poll() {
  try { render(await api("GET", "/api/status")); }
  catch (e) { $("state").textContent = "Can't reach PCOSync: " + e.message; }
}
async function cmd(c) {
  try { const r = await api("POST", "/api/command", { command: c }); $("cmd-out").textContent = r.message; poll(); }
  catch (e) { toast(e.message); }
}
$("btn-dry").onclick = async () => { try { toast((await api("POST", "/api/start", { armed: false })).message); poll(); } catch (e) { toast(e.message); } };
$("btn-arm").onclick = async () => {
  if (!confirm("Arm PCOSync?\n\nIt will take LIVE control in Planning Center and move LIVE to follow ProPresenter.\n\nReset rehearsal times in LIVE before the real service.")) return;
  try { toast((await api("POST", "/api/start", { armed: true })).message); poll(); } catch (e) { toast(e.message); }
};
$("btn-stop").onclick = async () => { try { $("btn-stop").disabled = true; toast((await api("POST", "/api/stop")).message); poll(); } catch (e) { toast(e.message); } };
$("btn-pause").onclick = () => cmd(status && status.paused ? "resume" : "pause");
$("btn-confirm").onclick = () => cmd("confirm");
$("btn-reload").onclick = () => cmd("reload");
document.querySelectorAll("[data-cmd]").forEach((b) => b.onclick = () => cmd(b.dataset.cmd));

// Mapping
async function loadMapping() {
  $("map-msg").textContent = "Loading…"; $("map-body").innerHTML = "";
  try {
    const m = await api("GET", "/api/mapping");
    $("map-msg").textContent = m.message || ("ProPresenter playlist “" + m.playlist + "” → PCO plan " + m.planId);
    $("map-body").innerHTML = m.rows.map((r) => "<tr><td>" + esc(r.index ?? "?") + (r.isPCO ? ' <span class="sub">pco</span>' : "") + "</td><td>" + esc(r.name) + "</td><td>" + esc(r.type) + "</td><td>" +
      (r.target ? esc(r.target) + ' <span class="sub">#' + esc(r.sequence) + "</span>" : '<span class="sub">— no move —</span>') + '</td><td class="sub">' + esc(r.method) + ": " + esc(r.reason) + "</td></tr>").join("");
  } catch (e) { $("map-msg").textContent = e.message; }
}
$("btn-map").onclick = loadMapping;

// Settings
function fillSelect(sel, rows, value, keep) {
  const cur = value;
  sel.innerHTML = (keep || "") + rows.map((r) => '<option value="' + esc(r.value) + '">' + esc(r.label) + "</option>").join("");
  if (cur && ![...sel.options].some((o) => o.value === cur)) sel.insertAdjacentHTML("beforeend", '<option value="' + esc(cur) + '">' + esc(cur) + "</option>");
  sel.value = cur || (sel.options[0] && sel.options[0].value) || "";
}
async function loadConfig() {
  try {
    const r = await api("GET", "/api/config");
    config = r.config;
    $("creds-state").textContent = r.credentials.saved ? "Saved (Application ID " + r.credentials.appIdHint + ")." : "Not set yet.";
    $("data-dir").textContent = "Settings are stored in " + r.dataDirectory;
    const c = config;
    fillSelect($("f-st"), [], c.pco.serviceTypeId, '<option value="">(not chosen)</option>');
    fillSelect($("f-plan"), [], c.pco.plan, '<option value="next">Next upcoming plan (recommended)</option>');
    $("f-host").value = c.propresenter.host; $("f-port").value = c.propresenter.port;
    $("f-poll").value = c.propresenter.pollInterval; $("f-timeout").value = c.propresenter.timeout;
    $("f-plfilter").value = c.sync.playlistNameContains;
    $("f-debounce").value = c.sync.debounceSeconds; $("f-maxjump").value = c.sync.maxJump;
    $("f-resync").value = c.sync.resyncSeconds; $("f-refresh").value = c.sync.planRefreshSeconds;
    $("f-takeover").checked = c.sync.takeOver; $("f-release").checked = c.sync.releaseOnExit;
    $("f-ignore").value = c.match.ignore.join("\n");
    $("f-aliases").value = Object.entries(c.match.aliases).map(([k, v]) => k + " = " + v).join("\n");
    $("f-positional").checked = c.match.positionalFallback;
    $("f-autostart").checked = c.app.autoStart; $("f-startarmed").checked = c.app.startArmed; $("f-loglevel").value = c.app.logLevel;
    $("f-webport").value = c.web.port; $("f-remote").checked = c.web.allowRemote; $("f-webpw").value = "";
    if (r.credentials.saved) { loadServiceTypes(true); }
  } catch (e) { toast(e.message); }
}
async function loadServiceTypes(quiet) {
  try {
    const r = await api("GET", "/api/pco/service-types");
    fillSelect($("f-st"), r.serviceTypes.map((t) => ({ value: t.id, label: t.name + " (" + t.id + ")" })), $("f-st").value || (config && config.pco.serviceTypeId), '<option value="">(not chosen)</option>');
    if ($("f-st").value) loadPlans(true);
  } catch (e) { if (!quiet) toast(e.message); }
}
async function loadPlans(quiet) {
  const st = $("f-st").value;
  if (!st) { if (!quiet) toast("Choose a service type first"); return; }
  try {
    const r = await api("GET", "/api/pco/plans?serviceType=" + encodeURIComponent(st));
    fillSelect($("f-plan"), r.plans.map((p) => ({ value: p.id, label: p.dates + (p.title ? " – " + p.title : "") + " (" + p.id + ")" })), $("f-plan").value || (config && config.pco.plan), '<option value="next">Next upcoming plan (recommended)</option>');
  } catch (e) { if (!quiet) toast(e.message); }
}
$("load-st").onclick = (e) => { e.preventDefault(); loadServiceTypes(false); };
$("load-plans").onclick = (e) => { e.preventDefault(); loadPlans(false); };
$("f-st").onchange = () => loadPlans(true);

$("creds-form").onsubmit = async (e) => {
  e.preventDefault();
  try {
    const r = await api("POST", "/api/credentials", { appId: $("c-app").value, secret: $("c-secret").value });
    $("c-app").value = ""; $("c-secret").value = ""; toast(r.message); loadConfig();
  } catch (err) { toast(err.message); }
};
$("btn-creds-clear").onclick = async () => {
  if (!confirm("Remove the saved Planning Center credentials?")) return;
  try { toast((await api("POST", "/api/credentials", { clear: true })).message); loadConfig(); } catch (e) { toast(e.message); }
};
$("btn-test").onclick = async () => {
  $("test-out").textContent = "Testing…";
  try {
    const r = await api("GET", "/api/test-connection");
    const pp = r.propresenter, pco = r.pco;
    $("test-out").textContent = (pp.ok ? "ProPresenter OK (" + (pp.version || pp.address) + (pp.item ? ", on “" + pp.item + "”" : "") + ")" : "ProPresenter FAILED: " + pp.error) +
      " · " + (pco.ok ? "Planning Center OK (" + pco.serviceTypes + " service types)" : "Planning Center FAILED: " + pco.error);
  } catch (e) { $("test-out").textContent = e.message; }
};
$("cfg-form").onsubmit = async (e) => {
  e.preventDefault();
  const num = (id) => Number($(id).value);
  const aliases = {};
  $("f-aliases").value.split("\n").forEach((line) => { const i = line.indexOf("="); if (i > 0) { const k = line.slice(0, i).trim(), v = line.slice(i + 1).trim(); if (k && v) aliases[k] = v; } });
  const c = {
    pco: { serviceTypeId: $("f-st").value, plan: $("f-plan").value || "next" },
    propresenter: { host: $("f-host").value.trim(), port: num("f-port"), timeout: num("f-timeout"), pollInterval: num("f-poll") },
    sync: { debounceSeconds: num("f-debounce"), maxJump: num("f-maxjump"), takeOver: $("f-takeover").checked, resyncSeconds: num("f-resync"),
            planRefreshSeconds: num("f-refresh"), playlistNameContains: $("f-plfilter").value.trim(), releaseOnExit: $("f-release").checked },
    match: { ignore: $("f-ignore").value.split("\n").map((s) => s.trim()).filter(Boolean), aliases, positionalFallback: $("f-positional").checked },
    app: { autoStart: $("f-autostart").checked, startArmed: $("f-startarmed").checked, logLevel: $("f-loglevel").value },
    web: { port: num("f-webport"), allowRemote: $("f-remote").checked, password: $("f-webpw").value },
  };
  try { const r = await api("PUT", "/api/config", c); $("save-out").textContent = r.message; toast(r.message); }
  catch (err) { $("save-out").textContent = err.message; toast(err.message); }
};

// Log
async function pollLog() {
  if (tab !== "log") return;
  try {
    const r = await api("GET", "/api/logs?after=" + logAfter);
    const el = $("log");
    const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 30;
    r.entries.forEach((e) => {
      logAfter = Math.max(logAfter, e.seq);
      const line = document.createElement("div");
      line.className = "lv-" + e.level;
      line.textContent = new Date(e.time).toLocaleTimeString() + "  " + e.level.padEnd(7) + "  " + e.message;
      el.appendChild(line);
    });
    while (el.childNodes.length > 2000) el.removeChild(el.firstChild);
    if (atBottom) el.scrollTop = el.scrollHeight;
    if (status) $("log-file").textContent = "Log file: " + status.logFile;
  } catch (e) {}
}

poll();
setInterval(poll, 1000);
setInterval(pollLog, 1500);
</script>
</body>
</html>
"""#
