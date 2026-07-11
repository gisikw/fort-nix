'use strict';

// Parent controls: a thin phone-sized client over the management-plane API.
// Same architecture rule as the kiosk (INVARIANTS 2): this page owns no
// state — it renders the SSE payload plus the ledger tail, and every tap is
// a POST the backend validates. Full re-render per state change, with input
// values/focus carried across (a parent mid-typing must not lose the field
// to a background SSE push).

let state = null; // last /api/events payload
let ledger = [];  // recent ledger tail, newest first
let live = false; // SSE connection state
let editKid = null, editRows = []; // open chore editor, if any

const root = document.getElementById('root');
const esc = s => String(s).replace(/[&<>"']/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

let toastTimer = null;
function toast(msg, isErr) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = isErr ? 'err' : '';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 3500);
}

async function api(path, body) {
  const opts = body === undefined ? undefined : {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body),
  };
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    toast(data.error || ('error ' + res.status), true);
    throw new Error(data.error || res.status);
  }
  return data;
}

async function refreshLedger() {
  try {
    ledger = (await api('/api/admin/ledger?n=30')).events || [];
  } catch (e) { /* toast already shown */ }
  render();
}

// ── rendering ───────────────────────────────────────────────────────────────

function kidWhere(k) {
  if (k.transit) return `${esc(k.location)} → ${esc(k.transit.to)} (${k.transit.nights} night${k.transit.nights === 1 ? '' : 's'} left)`;
  return 'at ' + esc(k.location);
}

function choreRows(k) {
  if (!k.chores || !k.chores.length) return '<div class="nochores">no chores defined</div>';
  return k.chores.map((c, i) => `
    <div class="chore ${c.done ? 'done' : ''}">
      <input type="checkbox" id="ck-${esc(k.id)}-${i}" data-kid="${esc(k.id)}" data-idx="${i}" ${c.done ? 'checked' : ''}>
      <label for="ck-${esc(k.id)}-${i}">${esc(c.name)}</label>
      <span class="val">🪙${c.coins}</span>
    </div>`).join('');
}

function choreEditor(k) {
  const rows = editRows.map((r, i) => `
    <div class="edit-row">
      <input type="text" id="ed-name-${i}" data-edit="name" data-idx="${i}" value="${esc(r.name)}" placeholder="chore name">
      <input type="number" id="ed-coins-${i}" data-edit="coins" data-idx="${i}" value="${esc(r.coins)}" min="0">
      <button class="small danger" data-act="edit-del" data-idx="${i}">✕</button>
    </div>`).join('');
  return `
    ${rows}
    <div class="edit-actions">
      <button class="small" data-act="edit-add">+ add chore</button>
      <button class="small" data-act="edit-save" data-kid="${esc(k.id)}">Save list</button>
      <button class="small" data-act="edit-cancel">Cancel</button>
    </div>`;
}

function kidCard(k) {
  const editing = editKid === k.id;
  return `
  <div class="card">
    <h2>${esc(k.avatar)} ${esc(k.name)}
      <span class="coins">🪙${k.coins}</span>
      <span class="sub">${kidWhere(k)}</span>
    </h2>
    ${editing ? choreEditor(k) : choreRows(k)}
    ${editing ? '' : `
    <div class="grant-row">
      <input type="number" id="grant-amt-${esc(k.id)}" placeholder="±coins">
      <input type="text" id="grant-reason-${esc(k.id)}" placeholder="reason (e.g. bounty)">
      <button data-act="grant" data-kid="${esc(k.id)}">Grant</button>
    </div>
    <div class="edit-actions">
      <button class="small" data-act="edit" data-kid="${esc(k.id)}">Edit chore list</button>
    </div>`}
  </div>`;
}

function appRow(p, a) {
  const chip = {ready: 'ready', locked: `locked 🪙${a.cost}`, stolen: `stolen 🪙${a.cost}`}[a.state] || esc(a.state);
  const steal = a.state === 'ready'
    ? `<button class="small danger" data-act="steal" data-planet="${esc(p.id)}" data-app="${esc(a.id)}" data-cost="${a.cost || 0}">👹 Steal</button>`
    : '';
  return `
    <div class="app">
      <span>${esc(a.icon)}</span><span class="name">${esc(a.name)}</span>
      <span class="state ${esc(a.state)}">${chip}</span>${steal}
    </div>`;
}

function planetCard(p) {
  if (p.undiscovered) return '';
  const here = state.kids.filter(k => !k.transit && k.location === p.id).map(k => k.avatar).join(' ');
  return `
  <div class="card">
    <h2>${esc(p.emoji)} ${esc(p.name)} <span class="sub">${here ? 'here: ' + esc(here) : ''}</span></h2>
    ${p.apps.map(a => appRow(p, a)).join('') || '<div class="nochores">no apps</div>'}
  </div>`;
}

function ledgerRows() {
  if (!ledger.length) return '<div class="nochores">nothing yet</div>';
  return ledger.map(e => {
    const coins = e.coins ? `<span class="${e.coins > 0 ? 'plus' : 'minus'}">${e.coins > 0 ? '+' : ''}${e.coins}🪙</span>` : '';
    const who = [e.kid, e.app || e.planet].filter(Boolean).join(' · ');
    return `<div class="ev"><span class="d">${esc(e.date || '')}</span><span class="t">${esc(e.type)}</span>
      <span>${esc(who)}</span>${coins}<span class="note">${esc(e.note || '')}</span></div>`;
  }).join('');
}

function render() {
  if (!state) return;
  const snapshot = {};
  root.querySelectorAll('input[type=text], input[type=number]').forEach(el => {
    if (el.id) snapshot[el.id] = el.value;
  });
  const focusId = document.activeElement && document.activeElement.id;
  const sel = focusId && document.activeElement.selectionStart != null
    ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null;

  root.innerHTML = `
  <header>
    <h1>Parent Controls</h1>
    <span class="meta">night ${state.night} · ${esc(state.date)}</span>
    <span class="meta ${live ? 'live' : 'dead'}">${live ? '● live' : '● reconnecting…'}</span>
  </header>
  <div class="card">
    <h2>Nightly tick <span class="sub">last ran for ${esc(state.lastTickDate)} · idempotent, safe to tap twice</span></h2>
    <div class="edit-actions">
      <button data-act="tick">Run tick for today</button>
      ${state.dev ? '<button data-act="tick1">+1 day (dev)</button>' : ''}
    </div>
  </div>
  ${state.playing ? `
  <div class="card">
    <h2>📺 Now playing <span class="sub">${esc(state.playing.icon)} ${esc(state.playing.name)} · launched by ${esc(state.playing.kid)}</span></h2>
    <div class="edit-actions">
      <button class="danger" data-act="stop-app">■ Stop app on TV</button>
    </div>
  </div>` : ''}
  ${state.kids.map(kidCard).join('')}
  ${state.planets.map(planetCard).join('')}
  <div class="card ledger">
    <h2>Recent activity</h2>
    ${ledgerRows()}
  </div>`;

  for (const [id, v] of Object.entries(snapshot)) {
    const el = document.getElementById(id);
    if (el) el.value = v;
  }
  if (focusId) {
    const el = document.getElementById(focusId);
    if (el) {
      el.focus();
      if (sel && el.setSelectionRange) try { el.setSelectionRange(sel[0], sel[1]); } catch (e) {}
    }
  }
}

// ── actions (event delegation, kiosk-style) ─────────────────────────────────

root.addEventListener('click', async ev => {
  const btn = ev.target.closest('button[data-act]');
  if (!btn) return;
  const d = btn.dataset;
  try {
    switch (d.act) {
      case 'tick': {
        const r = await api('/api/admin/tick', {});
        toast(`tick: advanced ${r.advanced} night(s), now night ${r.night}`);
        break;
      }
      case 'tick1': {
        const r = await api('/api/admin/tick', {days: 1});
        toast(`tick: advanced ${r.advanced} night(s), now night ${r.night}`);
        break;
      }
      case 'grant': {
        const amt = document.getElementById(`grant-amt-${d.kid}`);
        const reason = document.getElementById(`grant-reason-${d.kid}`);
        const coins = parseInt(amt.value, 10);
        if (!coins) { toast('enter a nonzero coin amount', true); return; }
        await api('/api/admin/grant', {kid: d.kid, coins, reason: reason.value || 'manual grant'});
        amt.value = ''; reason.value = '';
        toast(`granted ${coins > 0 ? '+' : ''}${coins} to ${d.kid}`);
        break;
      }
      case 'steal': {
        let cost = parseInt(d.cost, 10) || 0;
        if (!cost) {
          const v = prompt('This app has no price. Re-unlock cost in coins?');
          if (v === null) return;
          cost = parseInt(v, 10);
          if (!cost || cost < 0) { toast('need a positive cost', true); return; }
        }
        if (!confirm(`Send the Dadmonster to steal "${d.app}"? Reclaim will cost a trip + 🪙${cost}.`)) return;
        await api('/api/admin/steal', {planet: d.planet, app: d.app, cost});
        toast(`👹 stole ${d.app}`);
        break;
      }
      case 'stop-app': {
        if (!confirm(`Stop "${state.playing ? state.playing.name : 'the running app'}" on the TV? The kiosk comes back on its own.`)) return;
        await api('/api/admin/stop-app', {});
        toast('■ stop sent to the TV');
        break;
      }
      case 'edit': {
        const kid = state.kids.find(k => k.id === d.kid);
        editKid = d.kid;
        editRows = (kid.chores || []).map(c => ({name: c.name, coins: c.coins}));
        render();
        break;
      }
      case 'edit-add':
        editRows.push({name: '', coins: 10});
        render();
        break;
      case 'edit-del':
        editRows.splice(parseInt(d.idx, 10), 1);
        render();
        break;
      case 'edit-cancel':
        editKid = null; editRows = [];
        render();
        break;
      case 'edit-save': {
        const chores = editRows.map(r => ({name: r.name.trim(), coins: parseInt(r.coins, 10) || 0}));
        await api('/api/admin/chores', {kid: d.kid, chores});
        editKid = null; editRows = [];
        toast('chore list saved');
        break;
      }
    }
  } catch (e) { /* toast already shown by api() */ }
});

root.addEventListener('change', async ev => {
  const el = ev.target;
  if (el.matches('input[type=checkbox][data-kid]')) {
    const kid = state.kids.find(k => k.id === el.dataset.kid);
    const chore = kid && kid.chores[parseInt(el.dataset.idx, 10)];
    if (!chore) return;
    try {
      if (el.checked) {
        await api('/api/admin/chore-check', {kid: kid.id, chore: chore.name});
        toast(`✓ ${chore.name}: +${chore.coins}🪙 for ${kid.name}`);
      } else {
        if (!confirm(`Uncheck "${chore.name}" and take back 🪙${chore.coins} from ${kid.name}?`)) {
          render(); // restore the box from state
          return;
        }
        await api('/api/admin/chore-uncheck', {kid: kid.id, chore: chore.name});
        toast(`↩ ${chore.name}: −${chore.coins}🪙 from ${kid.name}`);
      }
    } catch (e) {
      render(); // backend refused — re-render truth (INVARIANTS 2)
    }
  }
});

// Editor rows mirror their inputs so re-renders never lose typed text.
root.addEventListener('input', ev => {
  const el = ev.target;
  if (el.dataset.edit) {
    const row = editRows[parseInt(el.dataset.idx, 10)];
    if (row) row[el.dataset.edit] = el.dataset.edit === 'coins' ? (parseInt(el.value, 10) || 0) : el.value;
  }
});

// ── SSE: the payload stream the kiosk uses; EventSource auto-reconnects ─────

const es = new EventSource('/api/events');
es.onopen = () => { live = true; render(); };
es.onerror = () => { live = false; render(); };
es.onmessage = ev => {
  live = true;
  state = JSON.parse(ev.data);
  refreshLedger(); // renders when done
};
