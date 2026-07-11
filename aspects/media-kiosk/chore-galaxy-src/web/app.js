'use strict';
// Chore Galaxy kiosk — a thin render of backend state (INVARIANTS 2).
// All game state arrives via /api/events (SSE, full payload per push); every
// mutation is a POST. Local state is presentation only: active kid view,
// focus position, overlays, screen scale. A failed POST simply re-renders
// last good state — a kid never sees an error they can't act on.
//
// The markup/styles below are a faithful port of
// design/launcher-prototype.dc.html; interaction feel is the contract.

const ROOT = document.getElementById('root');

let server = null; // last payload pushed by the backend
const ui = {
  view: 'map', planetId: null, focus: 0, mapFocus: null, kidIdx: 0,
  battle: null, launchPending: null, scale: 1,
};
let _bt = null, _pb = [], _axLock = 0, _lpTimer = null;

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ── server wiring ───────────────────────────────────────────────────────────

function connect() {
  const es = new EventSource('/api/events');
  es.onmessage = (e) => { server = JSON.parse(e.data); onServer(); };
  // EventSource reconnects on its own; meanwhile keep rendering last good state.
}

function onServer() {
  if (ui.kidIdx >= server.kids.length) ui.kidIdx = 0;
  if (ui.mapFocus === null && server.kids.length) {
    ui.mapFocus = kid().location;
    // Dev deep-link: #planet=zorp opens straight into a planet view.
    const m = location.hash.match(/^#planet=(.+)$/);
    if (m && server.planets.some(p => p.id === m[1])) { ui.view = 'planet'; ui.planetId = m[1]; }
  }
  if (!server.planets.some(p => p.id === ui.mapFocus)) ui.mapFocus = server.planets[0] && server.planets[0].id;
  if (ui.planetId && !server.planets.some(p => p.id === ui.planetId)) { ui.view = 'map'; ui.planetId = null; }
  if (server.playing) { ui.launchPending = null; clearTimeout(_lpTimer); }
  render();
}

async function post(path, body) {
  try {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
    if (!r.ok) console.warn('api', path, r.status, await r.text());
    return r.ok;
  } catch (err) { console.warn('api', path, err); return false; }
}

function kid() { return server.kids[ui.kidIdx]; }
function currentPlanet() { return server.planets.find(p => p.id === ui.planetId); }
function overlayApp() {
  if (server && server.playing) return server.playing;
  return ui.launchPending;
}

// Travel cost display mirrors the backend formula (backend is authoritative).
function nightsTo(destId) {
  const from = server.planets.find(p => p.id === kid().location);
  const to = server.planets.find(p => p.id === destId);
  if (!from || !to) return 1;
  const d = Math.hypot(to.x - from.x, to.y - from.y);
  return Math.max(1, Math.min(4, Math.round(d / 26)));
}

// ── input (gamepad-first, keyboard parity — RATIONALE §6) ──────────────────

function handleKey(e) {
  const k = e.key;
  if (k === 'Tab') { e.preventDefault(); return input(e.shiftKey ? 'prevKid' : 'nextKid'); }
  if (k === 'q') return input('prevKid');
  if (k === 'e') return input('nextKid');
  const m = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Enter: 'confirm', ' ': 'confirm', Escape: 'back', Backspace: 'back' };
  if (m[k]) { e.preventDefault(); input(m[k]); }
}

function pollPad() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  let gp = null;
  for (const p of pads) { if (p) { gp = p; break; } }
  if (!gp) return;
  const b = gp.buttons.map(x => x.pressed);
  const press = i => b[i] && !_pb[i];
  if (press(12)) input('up'); if (press(13)) input('down');
  if (press(14)) input('left'); if (press(15)) input('right');
  if (press(0)) input('confirm'); if (press(1)) input('back');
  if (press(4)) input('prevKid'); if (press(5)) input('nextKid');
  const ax = gp.axes[0] || 0, ay = gp.axes[1] || 0;
  if (!_axLock) {
    if (ay < -0.6) { input('up'); _axLock = 1; }
    else if (ay > 0.6) { input('down'); _axLock = 1; }
    else if (ax < -0.6) { input('left'); _axLock = 1; }
    else if (ax > 0.6) { input('right'); _axLock = 1; }
  }
  if (Math.abs(ax) < 0.3 && Math.abs(ay) < 0.3) _axLock = 0;
  _pb = b;
}

function input(a) {
  if (!server || !server.kids.length) return;
  if (overlayApp()) {
    // While something is playing the TV belongs to the game. Back dismisses
    // only a pending overlay that the backend never confirmed.
    if (a === 'back' && !server.playing) { ui.launchPending = null; render(); }
    return;
  }
  if (ui.battle) { if (a === 'confirm' || a === 'back') battleAdvance(); return; }
  if (a === 'prevKid') return selectKid(Math.max(0, ui.kidIdx - 1));
  if (a === 'nextKid') return selectKid(Math.min(server.kids.length - 1, ui.kidIdx + 1));
  if (ui.view === 'map') {
    if (a === 'confirm') {
      const p = server.planets.find(x => x.id === ui.mapFocus);
      if (p && !p.undiscovered) openPlanet(p.id);
      return;
    }
    return moveMap(a);
  }
  if (a === 'back') return back();
  if (a === 'confirm') return activateFocus();
  return moveFocus(a);
}

function selectKid(i) {
  ui.kidIdx = i; ui.view = 'map'; ui.planetId = null;
  ui.mapFocus = kid().location; ui.focus = 0;
  render();
}

// Spatial map navigation: nearest planet in the pressed direction.
function moveMap(dir) {
  const cur = server.planets.find(x => x.id === ui.mapFocus) || server.planets[0];
  let best = null, bs = 1e9;
  for (const p of server.planets) {
    if (p.id === cur.id) continue;
    const dx = p.x - cur.x, dy = p.y - cur.y;
    let ok = false, sc = 0;
    if (dir === 'right' && dx > 3) { ok = true; sc = dx + 2 * Math.abs(dy); }
    if (dir === 'left' && dx < -3) { ok = true; sc = -dx + 2 * Math.abs(dy); }
    if (dir === 'down' && dy > 3) { ok = true; sc = dy + 2 * Math.abs(dx); }
    if (dir === 'up' && dy < -3) { ok = true; sc = -dy + 2 * Math.abs(dx); }
    if (ok && sc < bs) { bs = sc; best = p; }
  }
  if (best) { ui.mapFocus = best.id; render(); }
}

// Focus list in a planet: [travel banner?] then each app in a 3-col grid.
function showTravelBanner() {
  const p = currentPlanet(); if (!p) return false;
  const k = kid();
  const here = k.location === p.id && !k.transit;
  const inTransitHere = k.transit && k.transit.to === p.id;
  return !here && !inTransitHere;
}

function focusables() {
  const p = currentPlanet(); if (!p) return [];
  const list = [];
  if (showTravelBanner()) list.push({ kind: 'travel' });
  p.apps.forEach((a, i) => list.push({ kind: 'app', i }));
  return list;
}

function moveFocus(dir) {
  const list = focusables(); const n = list.length; if (!n) return;
  let i = Math.min(ui.focus, n - 1);
  const cols = 3, hasTravel = list[0] && list[0].kind === 'travel';
  if (hasTravel) {
    if (i === 0) { if (dir === 'down') i = 1; }
    else {
      let g = i - 1;
      if (dir === 'left') g = Math.max(0, g - 1);
      if (dir === 'right') g = Math.min(n - 2, g + 1);
      if (dir === 'up') g = (g - cols < 0) ? -1 : g - cols;
      if (dir === 'down') g = Math.min(n - 2, g + cols);
      i = (g < 0) ? 0 : g + 1;
    }
  } else {
    if (dir === 'left') i = Math.max(0, i - 1);
    if (dir === 'right') i = Math.min(n - 1, i + 1);
    if (dir === 'up') i = Math.max(0, i - cols);
    if (dir === 'down') i = Math.min(n - 1, i + cols);
  }
  ui.focus = i; render();
}

function activateFocus() {
  const list = focusables(); const item = list[Math.min(ui.focus, list.length - 1)];
  if (!item) return;
  if (item.kind === 'travel') return setCourse(currentPlanet().id);
  return handleApp(item.i);
}

function openPlanet(id) { ui.view = 'planet'; ui.planetId = id; ui.focus = 0; render(); }
function back() { ui.view = 'map'; ui.planetId = null; render(); }

// ── actions (every mutation goes to the backend) ────────────────────────────

function setCourse(dest) {
  const k = kid();
  if (k.location === dest && !k.transit) return;
  post('/api/travel', { kid: k.id, to: dest });
  ui.view = 'map'; ui.planetId = null; ui.mapFocus = dest;
  render();
}

function handleApp(i) {
  const p = currentPlanet(); const app = p.apps[i];
  const k = kid();
  const here = k.location === p.id && !k.transit;
  if (app.state === 'ready') {
    ui.launchPending = { app: app.id, name: app.name, icon: app.icon };
    render();
    post('/api/launch', { kid: k.id, app: app.id });
    // If the backend never confirms (launcher missing, already playing),
    // quietly drop the overlay and re-render last good state.
    clearTimeout(_lpTimer);
    _lpTimer = setTimeout(() => {
      if (ui.launchPending && !(server && server.playing)) { ui.launchPending = null; render(); }
    }, 4000);
    return;
  }
  if (!here) return; // must be here to unlock or fight
  if (app.state === 'locked') {
    if (k.coins >= app.cost) post('/api/unlock', { kid: k.id, planet: p.id, app: app.id });
    return;
  }
  if (app.state === 'stolen') return startBattle(i);
}

function simNight() {
  if (server && server.dev) post('/api/admin/tick', { days: 1 });
}

// ── on-rails Dadmonster battle (guaranteed win — INVARIANTS 3) ─────────────

function startBattle(i) {
  const p = currentPlanet(); const app = p.apps[i]; const hero = kid().name;
  const frames = [
    { msg: 'The DADMONSTER swiped ' + app.name + '! Time to get it back.', h: 100, f: 100, prompt: 'Ⓐ ▶' },
    { msg: hero + ' uses ⚔️ BROOM SLASH! It’s super effective!', h: 100, f: 58, prompt: 'Ⓐ ▶' },
    { msg: 'Dadmonster uses 😤 "DID YOU CLEAN YOUR ROOM?"… it fizzles.', h: 88, f: 58, prompt: 'Ⓐ ▶' },
    { msg: hero + ' uses 🌟 HERO SPIN ATTACK!', h: 88, f: 22, prompt: 'Ⓐ ▶' },
    { msg: hero + ' unleashes the 🔥 FINISHER!', h: 88, f: 0, prompt: 'Ⓐ ▶' },
    { msg: '★ VICTORY! ' + app.name + ' is free again — re-install it for 🪙' + app.cost + '.', h: 88, f: 0, prompt: 'Ⓐ Claim', win: true },
  ];
  ui.battle = { planetId: p.id, appId: app.id, frame: 0, frames };
  clearInterval(_bt); _bt = setInterval(battleTick, 1300);
  render();
}

function battleTick() {
  const b = ui.battle; if (!b) return;
  if (b.frames[b.frame].win) { clearInterval(_bt); return; }
  b.frame = Math.min(b.frames.length - 1, b.frame + 1);
  render();
}

function battleAdvance() {
  const b = ui.battle; if (!b) return;
  const f = b.frames[b.frame];
  if (f.win) { // claim → backend flips stolen → locked (re-buyable)
    clearInterval(_bt);
    post('/api/battle-win', { kid: kid().id, planet: b.planetId, app: b.appId });
    ui.battle = null;
    render();
    return;
  }
  clearInterval(_bt); _bt = setInterval(battleTick, 1300);
  b.frame = Math.min(b.frames.length - 1, b.frame + 1);
  render();
}

// ── render ──────────────────────────────────────────────────────────────────

function render() {
  if (!server || !server.kids.length) {
    ROOT.innerHTML = `<div style="position:relative;width:100vw;height:100vh;overflow:hidden;background:radial-gradient(120% 100% at 50% 0%,#141024 0%,#08060f 70%);display:flex;align-items:center;justify-content:center">
      <div style="font-family:'Baloo 2',cursive;font-weight:800;font-size:27px;background:linear-gradient(90deg,#ffd23f,#23e5ff,#ff5bb0);-webkit-background-clip:text;background-clip:text;color:transparent">CHORE GALAXY</div>
    </div>`;
    return;
  }
  const k = kid();
  const screenStyle = `position:absolute;top:50%;left:50%;width:1280px;height:720px;transform:translate(-50%,-50%) scale(${ui.scale});transform-origin:center center;background:radial-gradient(120% 90% at 50% -10%,#241452 0%,#0f0a2e 55%,#07050f 100%);color:#eaf6ff;font-family:'Fredoka',system-ui,sans-serif;overflow:hidden;box-shadow:inset 0 0 120px rgba(60,40,120,.25)`;

  ROOT.innerHTML = `
<div style="position:relative;width:100vw;height:100vh;overflow:hidden;background:radial-gradient(120% 100% at 50% 0%,#141024 0%,#08060f 70%)">
<div style="${screenStyle}">
  <div style="position:absolute;inset:0;z-index:40;pointer-events:none;background:repeating-linear-gradient(0deg,rgba(0,0,0,.10) 0 2px,transparent 2px 4px);border-radius:22px"></div>
  ${renderTopBar(k)}
  <div style="position:relative;z-index:10;display:flex;height:614px">
    ${renderLeftRail(k)}
    <div style="flex:1;position:relative;overflow:hidden">
      ${ui.view === 'map' ? renderMap(k) : renderPlanet(k)}
    </div>
  </div>
  ${renderHintBar()}
  ${renderLaunchOverlay()}
  ${renderBattleOverlay(k)}
</div>
</div>`;
}

function renderTopBar(k) {
  const tabs = server.kids.map((kk, i) => {
    const active = i === ui.kidIdx;
    const st = `font-family:'Fredoka';font-weight:600;font-size:14px;padding:7px 14px;border-radius:20px;cursor:pointer;background:${active ? 'rgba(255,255,255,.14)' : 'rgba(255,255,255,.04)'};border:${active ? '1px solid rgba(255,255,255,.4)' : '1px solid transparent'};color:${active ? '#fff' : 'rgba(234,246,255,.55)'}`;
    return `<div style="${st}" data-act="kid:${i}">${esc(kk.avatar)} ${esc(kk.name)}</div>`;
  }).join('');
  const nightChip = `display:flex;align-items:center;gap:6px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.15);border-radius:20px;padding:7px 13px;font-family:'Fredoka';font-size:14px;color:rgba(234,246,255,.75);cursor:${server.dev ? 'pointer' : 'default'}`;
  const sim = server.dev ? ` <span style="opacity:.6;font-size:11px">⏭ sim</span>` : '';
  return `
  <div style="position:relative;z-index:20;display:flex;align-items:center;justify-content:space-between;padding:18px 30px;border-bottom:1px solid rgba(255,255,255,.08)">
    <div style="display:flex;align-items:center;gap:16px">
      <div style="font-family:'Baloo 2',cursive;font-weight:800;font-size:27px;line-height:1;background:linear-gradient(90deg,#ffd23f,#23e5ff,#ff5bb0);-webkit-background-clip:text;background-clip:text;color:transparent">CHORE GALAXY</div>
      <div style="display:flex;gap:8px">${tabs}</div>
    </div>
    <div style="display:flex;align-items:center;gap:12px">
      <div style="${nightChip}"${server.dev ? ' data-act="sim"' : ''}>🌙 Night ${server.night}${sim}</div>
      <div style="display:flex;align-items:center;gap:6px;background:rgba(255,210,63,.14);border:1px solid rgba(255,210,63,.5);border-radius:20px;padding:7px 15px;font-weight:700;font-size:16px;color:#ffe08a">🪙 ${k.coins}</div>
    </div>
  </div>`;
}

function renderLeftRail(k) {
  const xpPct = k.xpMax > 0 ? Math.round(100 * k.xp / k.xpMax) : 0;
  const chores = k.chores.map(c => {
    const row = `display:flex;align-items:center;gap:10px;background:${c.done ? 'rgba(90,255,160,.08)' : 'rgba(255,255,255,.04)'};border:1px solid ${c.done ? 'rgba(90,255,160,.25)' : 'rgba(255,255,255,.08)'};border-radius:10px;padding:9px 11px`;
    const check = `width:20px;height:20px;flex:none;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;background:${c.done ? '#5ad17a' : 'transparent'};border:${c.done ? 'none' : '2px solid rgba(255,255,255,.3)'};color:#062b12`;
    const name = `flex:1;font-family:'Fredoka';font-weight:600;font-size:13.5px;color:${c.done ? 'rgba(234,246,255,.5)' : '#eaf6ff'};text-decoration:${c.done ? 'line-through' : 'none'}`;
    const coin = `font-family:'Fredoka';font-weight:700;font-size:12.5px;color:${c.done ? 'rgba(255,224,138,.5)' : '#ffe08a'}`;
    return `<div style="${row}"><span style="${check}">${c.done ? '✓' : '○'}</span><span style="${name}">${esc(c.name)}</span><span style="${coin}">🪙 ${c.coins}</span></div>`;
  }).join('');
  const earnedToday = k.chores.filter(c => c.done).reduce((a, c) => a + c.coins, 0);
  return `
    <div style="width:320px;flex:none;padding:22px 22px 18px;border-right:1px solid rgba(255,255,255,.08);display:flex;flex-direction:column">
      <div style="display:flex;align-items:center;gap:13px">
        <div style="width:50px;height:50px;border-radius:50%;flex:none;background:#12112a;border:3px solid ${esc(k.color)};display:flex;align-items:center;justify-content:center;font-size:25px;box-shadow:0 0 16px ${esc(k.color)}55">${esc(k.avatar)}</div>
        <div style="flex:1">
          <div style="font-family:'Baloo 2';font-weight:800;font-size:22px;line-height:1.05">${esc(k.name)}</div>
          <div style="font-family:'Fredoka';font-size:12.5px;color:${esc(k.color)}">“${esc(k.title)}” · Lv ${k.level}</div>
          <div style="height:5px;border-radius:4px;background:rgba(0,0,0,.4);overflow:hidden;margin-top:6px"><div style="width:${xpPct}%;height:100%;background:linear-gradient(90deg,${esc(k.color)},#ffffffcc)"></div></div>
        </div>
      </div>
      <div style="font-family:'Fredoka';font-weight:600;font-size:12px;letter-spacing:1px;color:rgba(234,246,255,.45);margin:22px 0 10px">TODAY'S CHORES</div>
      <div style="display:flex;flex-direction:column;gap:8px">${chores}</div>
      <div style="margin-top:auto;display:flex;flex-direction:column;gap:6px">
        <div style="display:flex;align-items:center;justify-content:space-between;background:rgba(255,210,63,.1);border:1px solid rgba(255,210,63,.3);border-radius:12px;padding:11px 14px">
          <span style="font-family:'Fredoka';font-weight:600;font-size:13px;color:rgba(234,246,255,.8)">Earned today</span>
          <span style="font-family:'Baloo 2';font-weight:800;font-size:18px;color:#ffe08a">🪙 ${earnedToday}</span>
        </div>
        <div style="font-family:'Fredoka';font-size:11px;color:rgba(234,246,255,.38);text-align:center">A grown-up checks these off — coins land here.</div>
      </div>
    </div>`;
}

// Travel lanes: faint dashed curves chaining planets in x-order (the
// prototype hardcoded these for its example layout; this generalizes).
function renderLanes() {
  const ps = [...server.planets].sort((a, b) => a.x - b.x || a.y - b.y);
  let paths = '';
  for (let i = 0; i + 1 < ps.length; i++) {
    const a = ps[i], b = ps[i + 1];
    const x1 = a.x * 7, y1 = a.y * 5.2, x2 = b.x * 7, y2 = b.y * 5.2;
    const cx = (x1 + x2) / 2 + (y1 - y2) * 0.2, cy = (y1 + y2) / 2 + (x2 - x1) * 0.1;
    paths += `<path d="M${x1} ${y1} Q${cx} ${cy} ${x2} ${y2}" fill="none" stroke="${esc(a.color)}55" stroke-width="2" stroke-dasharray="2 8"/>`;
  }
  return `<svg viewBox="0 0 700 520" style="position:absolute;inset:0;width:100%;height:100%">${paths}</svg>`;
}

function renderMap(k) {
  const planets = server.planets.map(p => {
    const focused = p.id === ui.mapFocus;
    const hasCastle = p.castleOwners.includes(k.id);
    const hasRocket = k.location === p.id && !k.transit;
    const hasEvent = p.apps.some(a => a.state === 'stolen');
    let sub, subColor;
    if (p.undiscovered) { sub = '🔒 not discovered'; subColor = 'rgba(234,246,255,.5)'; }
    else {
      const ready = p.apps.filter(a => a.state === 'ready').length;
      sub = '🎮 ' + ready + '/' + p.apps.length + ' ready'; subColor = 'rgba(234,246,255,.6)';
    }
    let marks = ''; if (hasCastle) marks += '👑'; if (hasRocket) marks += '🚀';
    const wrap = `position:absolute;left:${p.x}%;top:${p.y}%;transform:translate(-50%,-50%)${focused ? ' scale(1.12)' : ''};display:flex;flex-direction:column;align-items:center;gap:4px;cursor:${p.undiscovered ? 'default' : 'pointer'};transition:transform .12s;z-index:${focused ? 6 : 2};opacity:${p.undiscovered ? '.55' : '1'}`;
    const circle = `width:70px;height:70px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:30px;background:radial-gradient(circle at 32% 28%, rgba(255,255,255,.55), ${esc(p.color)});border:2px solid rgba(255,255,255,.25);box-shadow:${focused ? '0 0 0 5px #fff, ' : ''}0 0 26px ${esc(p.color)}aa;filter:${p.undiscovered ? 'grayscale(.5)' : 'none'}`;
    const eventBadge = hasEvent ? `<span style="background:#ff3b3b;color:#fff;font-family:'Baloo 2';font-weight:800;font-size:13px;width:20px;height:20px;border-radius:50%;display:flex;align-items:center;justify-content:center;box-shadow:0 0 12px #ff3b3b;animation:cg-pulse 1.1s infinite">!</span>` : '';
    return `
      <div style="${wrap}" data-act="planet:${esc(p.id)}" data-hov="map:${esc(p.id)}">
        <div style="display:flex;align-items:center;gap:5px;height:22px;font-size:16px"><span>${marks}</span>${eventBadge}</div>
        <div style="${circle}">${esc(p.emoji)}</div>
        <div style="font-family:'Fredoka';font-weight:700;font-size:15px;color:#fff;text-shadow:0 1px 4px #000">${esc(p.name)}</div>
        <div style="font-family:'Fredoka';font-size:11.5px;color:${subColor};text-shadow:0 1px 3px #000">${sub}</div>
      </div>`;
  }).join('');

  let transit = '';
  if (k.transit) {
    const from = server.planets.find(p => p.id === k.location);
    const to = server.planets.find(p => p.id === k.transit.to);
    if (from && to) {
      transit = `<div style="position:absolute;left:${(from.x + to.x) / 2}%;top:${(from.y + to.y) / 2}%;transform:translate(-50%,-50%);display:flex;align-items:center;font-size:22px;z-index:7;filter:drop-shadow(0 0 8px #23e5ff)">🚀<span style="font-family:'Fredoka';font-size:11px;background:rgba(0,0,0,.6);padding:2px 6px;border-radius:8px;margin-left:4px">${k.transit.nights}n</span></div>`;
    }
  }
  const hint = k.transit ? `· 🚀 you are in transit (${k.transit.nights}n left)` : '';
  return `
        <div style="position:absolute;inset:0;padding:8px 20px 20px">
          <div style="font-family:'Fredoka';font-weight:600;font-size:14px;color:rgba(234,246,255,.55);padding:10px 6px 0">The Galaxy — press Ⓐ to visit a planet ${hint}</div>
          <div style="position:relative;width:100%;height:520px">
            ${renderLanes()}
            ${planets}
            ${transit}
          </div>
        </div>`;
}

function renderPlanet(k) {
  const p = currentPlanet();
  if (!p) return '';
  const here = k.location === p.id && !k.transit;
  const inTransitHere = k.transit && k.transit.to === p.id;
  const showTravel = showTravelBanner();
  const list = focusables();
  const focus = Math.min(ui.focus, Math.max(0, list.length - 1));
  const base = showTravel ? 1 : 0;

  const owners = p.castleOwners.map(o => { const kk = server.kids.find(x => x.id === o); return kk ? kk.name : o; });
  let castle;
  if (owners.length === 0) castle = 'No castle here yet — be the first to found one';
  else if (p.castleOwners.includes(k.id)) castle = '👑 Your castle here' + (owners.length > 1 ? ' · shared with ' + owners.filter(n => n !== k.name).join(', ') : '');
  else castle = '👑 ' + owners.join(' & ') + "'s castle";

  const hereBadge = here ? '🚀 You are here' : inTransitHere ? ('🚀 Arriving in ' + k.transit.nights + 'n') : 'Not here';
  const hereBadgeStyle = `font-family:'Fredoka';font-weight:700;font-size:12px;padding:6px 12px;border-radius:20px;background:${here ? 'rgba(90,255,160,.16)' : 'rgba(255,255,255,.06)'};border:1px solid ${here ? 'rgba(90,255,160,.5)' : 'rgba(255,255,255,.15)'};color:${here ? '#8bffbe' : 'rgba(234,246,255,.6)'};white-space:nowrap`;

  let travelBanner = '';
  if (showTravel) {
    const n = nightsTo(p.id);
    const travelNights = n + (n === 1 ? ' night' : ' nights');
    const travelFocused = focus === 0;
    const st = `display:flex;align-items:center;gap:12px;margin-top:14px;background:rgba(35,229,255,.08);border:2px solid ${travelFocused ? '#fff' : 'rgba(35,229,255,.4)'};box-shadow:${travelFocused ? '0 0 0 4px rgba(255,255,255,.25)' : 'none'};border-radius:14px;padding:12px 16px;cursor:pointer;transition:transform .12s;transform:${travelFocused ? 'scale(1.02)' : 'none'}`;
    travelBanner = `
          <div style="${st}" data-act="travel" data-hov="focus:0">
            <span style="font-size:22px">🚀</span>
            <div style="flex:1"><div style="font-family:'Fredoka';font-weight:700;font-size:14px">Set course to ${esc(p.name)}</div><div style="font-family:'Fredoka';font-size:11.5px;color:rgba(234,246,255,.55)">arrives in ${travelNights} — unlock &amp; fights need you here</div></div>
            <span style="font-family:'Baloo 2';font-weight:800;font-size:13px">Fly ▶</span>
          </div>`;
  }

  const apps = p.apps.map((a, i) => {
    const focused = focus === base + i;
    let badge, badgeBg, badgeColor, action, actionColor, dim = false;
    if (a.state === 'ready') { badge = '▶ ready'; badgeBg = 'rgba(90,255,160,.18)'; badgeColor = '#8bffbe'; action = 'Launch'; actionColor = '#8bffbe'; }
    else if (a.state === 'locked') {
      badge = '🔒 🪙' + a.cost; badgeBg = 'rgba(0,0,0,.5)'; badgeColor = '#ffd23f'; dim = true;
      action = here ? (k.coins >= a.cost ? ('Unlock 🪙' + a.cost) : ('Need 🪙' + a.cost)) : 'Travel here to unlock';
      actionColor = here ? (k.coins >= a.cost ? '#ffe08a' : '#ff9d9d') : 'rgba(234,246,255,.5)';
    } else {
      badge = '👹 stolen!'; badgeBg = 'rgba(255,59,59,.25)'; badgeColor = '#ff9d9d'; dim = true;
      action = here ? '⚔️ Fight the Dadmonster' : 'Travel here to reclaim';
      actionColor = here ? '#ff9d9d' : 'rgba(234,246,255,.5)';
    }
    const wrap = `position:relative;width:170px;height:160px;border-radius:16px;background:${dim ? 'rgba(255,255,255,.04)' : 'rgba(255,255,255,.09)'};border:2px solid ${focused ? '#fff' : a.state === 'stolen' ? 'rgba(255,59,59,.5)' : 'rgba(255,255,255,.14)'};box-shadow:${focused ? '0 0 0 4px rgba(255,255,255,.28), 0 0 30px rgba(120,180,255,.5)' : 'none'};display:flex;flex-direction:column;align-items:center;justify-content:center;gap:9px;cursor:pointer;transform:${focused ? 'scale(1.05)' : 'none'};transition:transform .12s`;
    return `
            <div style="${wrap}" data-act="app:${i}" data-hov="focus:${base + i}">
              <div style="position:absolute;top:9px;right:9px;font-size:10px;font-weight:700;padding:3px 7px;border-radius:8px;background:${badgeBg};color:${badgeColor};font-family:'Fredoka'">${badge}</div>
              <div style="font-size:40px;filter:${dim ? 'grayscale(.7) opacity(.7)' : 'none'}">${esc(a.icon)}</div>
              <div style="font-family:'Fredoka';font-weight:700;font-size:14.5px;text-align:center;line-height:1.1">${esc(a.name)}</div>
              <div style="font-family:'Fredoka';font-weight:600;font-size:11.5px;color:${actionColor};text-align:center">${action}</div>
            </div>`;
  }).join('');

  return `
        <div style="position:absolute;inset:0;padding:18px 26px;animation:cg-pop .18s ease;overflow:auto">
          <div style="display:flex;align-items:center;gap:14px">
            <div style="font-family:'Fredoka';font-weight:700;font-size:13px;padding:8px 13px;border-radius:12px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.2);cursor:pointer;color:#ffb3b3" data-act="back">Ⓑ Back</div>
            <div style="font-size:34px">${esc(p.emoji)}</div>
            <div style="flex:1">
              <div style="font-family:'Baloo 2';font-weight:800;font-size:25px;line-height:1">${esc(p.name)}</div>
              <div style="font-family:'Fredoka';font-size:12.5px;color:rgba(234,246,255,.6)">${esc(castle)}</div>
            </div>
            <div style="${hereBadgeStyle}">${hereBadge}</div>
          </div>
          ${travelBanner}
          <div style="font-family:'Fredoka';font-weight:600;font-size:13px;color:rgba(234,246,255,.5);margin:16px 4px 12px">🎮 What you can launch here</div>
          <div style="display:flex;flex-wrap:wrap;gap:15px">${apps}</div>
        </div>`;
}

function renderHintBar() {
  return `
  <div style="position:relative;z-index:20;display:flex;align-items:center;gap:20px;padding:11px 30px;border-top:1px solid rgba(255,255,255,.08);font-family:'Fredoka';font-size:12.5px;color:rgba(234,246,255,.6)">
    <span><b style="color:#7dffb0">Ⓐ</b> Select</span>
    <span><b style="color:#ff8a8a">Ⓑ</b> Back</span>
    <span><b style="color:#8ff0ff">bumpers</b> Switch kid</span>
    <span><b style="color:#ffd23f">D-pad / stick</b> Move</span>
    <span style="margin-left:auto;opacity:.55">Keyboard: arrows · Enter · Esc · Tab</span>
  </div>`;
}

function renderLaunchOverlay() {
  const app = overlayApp();
  if (!app) return '';
  return `
  <div style="position:absolute;inset:0;z-index:60;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:22px;background:rgba(5,6,13,.93);border-radius:22px">
    <div style="font-size:86px;animation:cg-float 1.6s infinite">${esc(app.icon)}</div>
    <div style="font-family:'Baloo 2';font-weight:800;font-size:31px">Launching ${esc(app.name)}</div>
    <div style="display:flex;align-items:center;gap:12px;font-family:'Fredoka';font-size:16px;color:rgba(234,246,255,.65)"><span style="width:22px;height:22px;border:3px solid rgba(255,255,255,.2);border-top-color:#23e5ff;border-radius:50%;animation:cg-spin .8s linear infinite;display:inline-block"></span>starting up on the TV…</div>
  </div>`;
}

function renderBattleOverlay(k) {
  const b = ui.battle;
  if (!b) return '';
  const f = b.frames[b.frame];
  const hpBar = `width:120px;height:12px;border-radius:7px;background:rgba(0,0,0,.5);overflow:hidden;border:1px solid rgba(255,255,255,.2)`;
  return `
  <div style="position:absolute;inset:0;z-index:70;display:flex;flex-direction:column;background:radial-gradient(120% 100% at 50% 0%,#3a0f2a 0%,#12081f 70%);border-radius:22px" data-act="battle">
    <div style="flex:1;position:relative;overflow:hidden">
      <div style="position:absolute;inset:0;background-image:radial-gradient(1.5px 1.5px at 20% 30%,#fff,transparent),radial-gradient(1.5px 1.5px at 70% 20%,#ffd6f5,transparent),radial-gradient(1px 1px at 50% 60%,#fff,transparent);opacity:.6"></div>
      <div style="position:absolute;left:12%;bottom:22%;text-align:center">
        <div style="${hpBar}"><div style="width:${f.h}%;height:100%;background:linear-gradient(90deg,#5ad17a,#8bffbe);transition:width .4s"></div></div>
        <div style="font-size:72px;margin-top:10px">${esc(k.avatar)}</div>
        <div style="font-family:'Baloo 2';font-weight:800;font-size:16px;margin-top:4px">${esc(k.name)}</div>
      </div>
      <div style="position:absolute;right:12%;top:20%;text-align:center">
        <div style="${hpBar}"><div style="width:${f.f}%;height:100%;background:linear-gradient(90deg,#ff3b3b,#ff8a8a);transition:width .4s"></div></div>
        <div style="font-size:76px;margin-top:10px">👹</div>
        <div style="font-family:'Baloo 2';font-weight:800;font-size:16px;margin-top:4px;color:#ff8a8a">Dadmonster</div>
      </div>
    </div>
    <div style="margin:0 26px 26px;background:rgba(8,6,16,.92);border:2px solid rgba(255,255,255,.25);border-radius:14px;padding:18px 22px;min-height:78px;display:flex;align-items:center;justify-content:space-between;gap:16px">
      <div style="font-family:'Fredoka';font-weight:500;font-size:18px;line-height:1.35">${esc(f.msg)}</div>
      <div style="font-family:'Baloo 2';font-weight:800;font-size:14px;color:#7dffb0;white-space:nowrap">${f.prompt}</div>
    </div>
  </div>`;
}

// ── event delegation + boot ─────────────────────────────────────────────────

function act(spec) {
  const sep = spec.indexOf(':');
  const kind = sep < 0 ? spec : spec.slice(0, sep);
  const arg = sep < 0 ? '' : spec.slice(sep + 1);
  if (ui.battle && kind !== 'battle') return;
  switch (kind) {
    case 'kid': return selectKid(Number(arg));
    case 'sim': return simNight();
    case 'planet': {
      const p = server.planets.find(x => x.id === arg);
      if (p && !p.undiscovered) openPlanet(p.id);
      return;
    }
    case 'back': return back();
    case 'travel': return setCourse(currentPlanet().id);
    case 'app': { ui.focus = (showTravelBanner() ? 1 : 0) + Number(arg); return handleApp(Number(arg)); }
    case 'battle': return battleAdvance();
  }
}

function hov(spec) {
  const sep = spec.indexOf(':');
  const kind = spec.slice(0, sep), arg = spec.slice(sep + 1);
  if (kind === 'map' && ui.mapFocus !== arg) { ui.mapFocus = arg; render(); }
  if (kind === 'focus' && ui.focus !== Number(arg)) { ui.focus = Number(arg); render(); }
}

function fit() {
  // Fill the screen: the 1280×720 stage upscales to the panel (1.5× on a
  // 1920×1080 TV, full-bleed). min() letterboxes on non-16:9 displays.
  const s = Math.min(window.innerWidth / 1280, window.innerHeight / 720);
  ui.scale = s > 0 ? s : 1;
  render();
}

ROOT.addEventListener('click', e => {
  const el = e.target.closest('[data-act]');
  if (el) act(el.dataset.act);
});
ROOT.addEventListener('mouseover', e => {
  const el = e.target.closest('[data-hov]');
  if (el) hov(el.dataset.hov);
});
window.addEventListener('keydown', handleKey);
window.addEventListener('resize', fit);
(function loop() { pollPad(); requestAnimationFrame(loop); })();
fit();
connect();
