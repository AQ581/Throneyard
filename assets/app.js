import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_KEY, DISCORD_INVITE_URL, LAUNCH_AT } from './config.js';

export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
export const fmt = (n) => Number(n || 0).toLocaleString('en-US');
export const pad = (n) => String(n).padStart(2, '0');

export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

export function store(key, value) {
  try {
    if (value === undefined) return JSON.parse(localStorage.getItem(key) || 'null');
    localStorage.setItem(key, JSON.stringify(value));
  } catch (_) { return null; }
}

const LOGO = '<svg width="30" height="30" viewBox="0 0 64 64" aria-hidden="true"><polygon points="6,46 6,24 14,30 14,18 22,26 32,8 42,26 50,18 50,30 58,24 58,46" fill="#C8FF3D" stroke="#C8FF3D" stroke-width="1.5" stroke-linejoin="round"/><rect x="6" y="50" width="52" height="7" fill="#C8FF3D"/><rect x="29.5" y="24" width="5" height="6" fill="#0A0B0A"/><rect x="29.5" y="34" width="5" height="6" fill="#0A0B0A"/><rect x="16.5" y="33" width="4" height="5" fill="#0A0B0A"/><rect x="43.5" y="33" width="4" height="5" fill="#0A0B0A"/></svg>';

export function renderChrome(active) {
  const header = $('#site-header');
  if (header) {
    const link = (href, label, key, cls = '') =>
      `<a href="${href}" class="${cls}"${active === key ? ' aria-current="page"' : ''}>${label}</a>`;
    header.className = 'site-header';
    header.innerHTML = `
      <div class="wrap">
        <a class="brand" href="/" aria-label="Throneyard home">${LOGO}<span class="wordmark">THRONE<span style="color:var(--accent)">YARD</span></span></a>
        <nav class="nav" aria-label="Main">
          ${link('/#how', 'How it works', 'how', 'hide-sm')}
          ${link('/#honors', 'Honors', 'honors', 'hide-sm')}
          ${link('/#membership', 'Membership', 'membership')}
          ${link('/leaderboard.html', 'Rankings', 'rankings')}
          ${link('/community.html', 'Community', 'community')}
          ${link('/callouts.html', 'Callouts', 'callouts')}
          ${link('/highlights.html', 'Highlights', 'highlights', 'hide-sm')}
          <a href="/chat.html"${active === 'chat' ? ' aria-current="page"' : ''} id="nav-chat">Chat<span id="nav-chat-dot"></span></a>
          ${link('/submit.html', 'Submit mission', 'submit')}
          <span id="nav-bell"></span>
          <span id="nav-auth"></span>
        </nav>
      </div>`;
    updateNavAuth();
    sb.auth.onAuthStateChange((event, session) => {
      // Signed out here or in another tab, or the session expired: reset the page so nothing acts signed in.
      if (event === 'SIGNED_OUT') {
        sb.removeAllChannels();
        if (!signingOut) location.reload();
        return;
      }
      // Only redraw when the signed-in person actually changes (tab refocus also fires SIGNED_IN).
      const uid = session?.user?.id || null;
      if (uid !== lastUid) { lastUid = uid; updateNavAuth(); }
    });
  }
  const footer = $('#site-footer');
  if (footer) {
    footer.className = 'site-footer';
    footer.innerHTML = `<div class="wrap"><span>© ${new Date().getFullYear()} Throneyard · throneyard.com · <a href="/rules.html" style="color:var(--dim)">Badges &amp; Fair Play</a></span><span>Not affiliated with Rockstar Games or Take-Two Interactive.</span></div>`;
  }
  wireDiscordLinks();
}

let lastUid = undefined;
let signingOut = false;

export async function signOutHere() {
  signingOut = true;
  try { sb.removeAllChannels(); } catch (_) {}
  try {
    // 'local' signs out this device only; the player stays signed in on their other devices.
    await sb.auth.signOut({ scope: 'local' });
  } catch (_) {
    // Network failure: still clear the saved session so the player isn't stuck signed in.
    try { Object.keys(localStorage).filter((k) => k.startsWith('sb-')).forEach((k) => localStorage.removeItem(k)); } catch (_) {}
  }
  location.href = '/';
}

async function updateNavAuth() {
  const slot = $('#nav-auth');
  if (!slot) return;
  const { data } = await sb.auth.getSession();
  lastUid = data.session?.user?.id || null;
  if (data.session) { refreshUnread(); setupBell(data.session.user.id); }
  if (data.session) {
    slot.innerHTML = '<button class="btn btn-ghost" type="button" id="sign-out">Sign out</button>';
    $('#sign-out').addEventListener('click', (e) => { e.currentTarget.disabled = true; e.currentTarget.textContent = 'Signing out…'; signOutHere(); });
  } else {
    slot.innerHTML = isLaunched() ? '<a class="btn btn-primary" href="/submit.html">Sign up</a>' : '<a class="btn btn-primary" href="/#join">Join waitlist</a>';
    // Flip the button at launch for anyone with the page open.
    if (!isLaunched()) setTimeout(() => { if (!document.getElementById('sign-out')) slot.innerHTML = '<a class="btn btn-primary" href="/submit.html">Sign up</a>'; }, Math.min(new Date(LAUNCH_AT).getTime() - Date.now() + 500, 2147000000));
  }
}

// ---------- Notifications bell ----------
let bellReady = false;
const BELL_SVG = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>';
function ago(ts) {
  const s = (Date.now() - new Date(ts)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}
async function paintBell() {
  const { count } = await sb.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null);
  const n = count || 0;
  const badge = $('#bell-count');
  if (badge) { badge.textContent = n > 9 ? '9+' : String(n); badge.hidden = n === 0; }
  $('#bell-btn')?.setAttribute('aria-label', n ? `Notifications, ${n} unread` : 'Notifications');
}
async function openBell() {
  const panel = $('#bell-panel');
  panel.hidden = !panel.hidden;
  $('#bell-btn').setAttribute('aria-expanded', String(!panel.hidden));
  if (panel.hidden) return;
  panel.innerHTML = '<p class="dim" style="padding:14px">Loading…</p>';
  const { data } = await sb.from('notifications').select('*').order('id', { ascending: false }).limit(20);
  panel.innerHTML = `<div class="row between" style="padding:12px 14px;border-bottom:1px solid var(--line)"><strong>Notifications</strong><button type="button" class="link-btn" id="bell-clear">Mark all read</button></div>`
    + (data && data.length ? data.map((n) => `<a class="bell-item${n.read_at ? '' : ' unread-item'}" href="${esc(n.link || '#')}" data-nid="${n.id}">
        <strong>${esc(n.title)}</strong>${n.body ? `<span class="dim">${esc(n.body)}</span>` : ''}<span class="dim" style="font-size:12px">${ago(n.created_at)}</span></a>`).join('')
      : '<p class="dim" style="padding:14px">Nothing yet. Add friends, join a crew and submit runs. Updates show up here.</p>');
  $('#bell-clear').addEventListener('click', async () => {
    await sb.from('notifications').update({ read_at: new Date().toISOString() }).is('read_at', null);
    panel.querySelectorAll('.unread-item').forEach((x) => x.classList.remove('unread-item'));
    paintBell();
  });
  panel.querySelectorAll('[data-nid]').forEach((el) => el.addEventListener('click', () => {
    sb.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', Number(el.dataset.nid));
  }));
}
function toast(n) {
  let t = $('#ty-toast');
  if (!t) { t = document.createElement('a'); t.id = 'ty-toast'; t.className = 'toast'; document.body.appendChild(t); }
  t.href = n.link || '#';
  t.innerHTML = `<strong>${esc(n.title)}</strong>${n.body ? `<span>${esc(n.body)}</span>` : ''}`;
  t.classList.add('show');
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 5000);
}
function setupBell(uid) {
  const slot = $('#nav-bell');
  if (!slot || bellReady) return;
  bellReady = true;
  slot.className = 'bell-wrap';
  slot.innerHTML = `<button type="button" class="bell-btn" id="bell-btn" aria-haspopup="true" aria-expanded="false" aria-label="Notifications">${BELL_SVG}<span class="bell-count" id="bell-count" hidden>0</span></button><div class="bell-panel" id="bell-panel" hidden></div>`;
  $('#bell-btn').addEventListener('click', (e) => { e.stopPropagation(); openBell(); });
  document.addEventListener('click', (e) => { if (!e.target.closest('.bell-wrap')) { const p = $('#bell-panel'); if (p) p.hidden = true; } });
  paintBell();
  rtReady().then(() => sb.channel('user:' + uid, { config: { private: true } })
    .on('broadcast', { event: 'notification' }, ({ payload }) => { paintBell(); if (payload) toast(payload); })
    .subscribe());
}

export async function refreshUnread() {
  const dot = $('#nav-chat-dot');
  if (!dot) return;
  const { data } = await sb.rpc('dm_unread_count');
  dot.className = Number(data) > 0 ? 'nav-dot' : '';
  dot.setAttribute('aria-label', Number(data) > 0 ? `${data} unread messages` : '');
}
window.addEventListener('ty-unread', () => refreshUnread());

export function wireDiscordLinks() {
  $$('[data-discord]').forEach((a) => {
    if (DISCORD_INVITE_URL) {
      a.href = DISCORD_INVITE_URL;
      a.target = '_blank';
      a.rel = 'noopener';
    }
  });
}

// True once launch time has passed (uses the site setting, falls back to config).
export const isLaunched = (t = new Date(LAUNCH_AT).getTime()) => Date.now() >= t;

export async function getLaunchAt() {
  const { data } = await sb.from('settings').select('value').eq('key', 'launch_at').maybeSingle();
  return new Date(data?.value || LAUNCH_AT).getTime();
}

export function startCountdown(el, target, onDone) {
  const tick = () => {
    let diff = Math.max(0, target - Date.now());
    const d = Math.floor(diff / 864e5); diff -= d * 864e5;
    const h = Math.floor(diff / 36e5); diff -= h * 36e5;
    const m = Math.floor(diff / 6e4); diff -= m * 6e4;
    const s = Math.floor(diff / 1e3);
    el.innerHTML = [[d, 'days'], [h, 'hours'], [m, 'mins'], [s, 'secs']]
      .map(([v, l]) => `<div><b>${pad(v)}</b><span>${l}</span></div>`).join('');
  };
  tick();
  const id = setInterval(() => { tick(); if (Date.now() >= target) { clearInterval(id); onDone?.(); } }, 1000);
  return id;
}

export function leaderboardRows(rows, badges = {}) {
  return rows.map((r) => {
    const n = Number(r.rank);
    const cls = n === 1 ? 'r1' : n <= 3 ? `r${n}` : '';
    const initial = esc((r.gamertag || '?').charAt(0).toUpperCase());
    return `<tr>
      <td><span class="rank ${cls}">${pad(n)}</span></td>
      <td><div class="player"><div class="avatar">${initial}</div><strong>${playerLink(r.gamertag, r.member)}</strong>${memberChip(r.member)}${badgeChips(badges[r.gamertag])}</div></td>
      <td class="muted">${esc(r.city)}, ${esc(r.country)}</td>
      <td class="muted">${esc(r.platform === 'xbox' ? 'Xbox' : 'PS5')}</td>
      <td class="muted">${fmt(r.missions)}</td>
      <td><span class="score">${fmt(r.score)}</span></td>
    </tr>`;
  }).join('');
}

export async function currentProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return { session: null, profile: null };
  const { data: profile } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
  return { session, profile };
}

export async function getSettings() {
  const { data } = await sb.from('settings').select('key, value');
  const s = {};
  (data || []).forEach((r) => (s[r.key] = r.value));
  return {
    worldFinalMin: Number(s.world_final_min ?? 4),
    passPrice: s.pass_price || '5.99',
    earlyHours: Number(s.member_early_hours ?? 24),
    memberShots: Number(s.member_max_screenshots ?? 12),
    freeShots: Number(s.free_max_screenshots ?? 6),
    continentNames: s.continent_names || { NA: 'North America', EU: 'Europe', AS: 'Asia', OC: 'Oceania', SA: 'South America', AF: 'Africa' },
    continentMap: s.continent_map || {}
  };
}

export function applyPrizeText(s) {
  $$('.final-min').forEach((el) => (el.textContent = String(s.worldFinalMin)));
  $$('.pass-price').forEach((el) => (el.textContent = '$' + s.passPrice));
  $$('.early-hours').forEach((el) => (el.textContent = String(s.earlyHours)));
  $$('.member-shots').forEach((el) => (el.textContent = String(s.memberShots)));
  $$('.free-shots').forEach((el) => (el.textContent = String(s.freeShots)));
}

export const playerHref = (tag) => '/player.html?u=' + encodeURIComponent(tag || '');
export const playerLink = (tag, isMember = false) =>
  `<a href="${playerHref(tag)}" class="player-link${isMember ? ' name-member' : ''}">${esc(tag)}</a>`;

export const memberChip = (isMember) => (isMember ? '<span class="badge member">Member</span>' : '');
export const nameClass = (isMember) => (isMember ? ' class="name-member"' : '');

const COUNTRY_CODES = 'AD,AE,AF,AG,AI,AL,AM,AO,AR,AS,AT,AU,AW,AX,AZ,BA,BB,BD,BE,BF,BG,BH,BI,BJ,BL,BM,BN,BO,BQ,BR,BS,BT,BW,BY,BZ,CA,CC,CD,CF,CG,CH,CI,CK,CL,CM,CN,CO,CR,CU,CV,CW,CX,CY,CZ,DE,DJ,DK,DM,DO,DZ,EC,EE,EG,EH,ER,ES,ET,FI,FJ,FK,FM,FO,FR,GA,GB,GD,GE,GF,GG,GH,GI,GL,GM,GN,GP,GQ,GR,GS,GT,GU,GW,GY,HK,HN,HR,HT,HU,ID,IE,IL,IM,IN,IO,IQ,IR,IS,IT,JE,JM,JO,JP,KE,KG,KH,KI,KM,KN,KP,KR,KW,KY,KZ,LA,LB,LC,LI,LK,LR,LS,LT,LU,LV,LY,MA,MC,MD,ME,MF,MG,MH,MK,ML,MM,MN,MO,MP,MQ,MR,MS,MT,MU,MV,MW,MX,MY,MZ,NA,NC,NE,NF,NG,NI,NL,NO,NP,NR,NU,NZ,OM,PA,PE,PF,PG,PH,PK,PL,PM,PN,PR,PS,PT,PW,PY,QA,RE,RO,RS,RU,RW,SA,SB,SC,SD,SE,SG,SH,SI,SJ,SK,SL,SM,SN,SO,SR,SS,ST,SV,SX,SY,SZ,TC,TD,TG,TH,TJ,TK,TL,TM,TN,TO,TR,TT,TV,TW,TZ,UA,UG,US,UY,UZ,VA,VC,VE,VG,VI,VN,VU,WF,WS,YE,YT,ZA,ZM,ZW'.split(',');
let regionNames = null;
try { regionNames = new Intl.DisplayNames(['en'], { type: 'region' }); } catch (_) {}
export const countryName = (code) => {
  const c = String(code || '').split('-')[0];
  try { return (regionNames && regionNames.of(c)) || c; } catch (_) { return c; }
};

export function residenceOptions(selected = '') {
  const sel = String(selected || '').split('-')[0];
  const list = COUNTRY_CODES.map((c) => [c, countryName(c)]).sort((x, y) => x[1].localeCompare(y[1]));
  return '<option value="">Select your country</option>'
    + list.map(([c, n]) => `<option value="${c}"${c === sel ? ' selected' : ''}>${esc(n)}</option>`).join('');
}

export const residenceLabel = countryName;

// ---- Badges ----
let badgeCache = null;
export async function loadBadges() {
  if (badgeCache) return badgeCache;
  const { data } = await sb.rpc('badge_summary');
  badgeCache = {};
  (data || []).forEach((b) => (badgeCache[b.gamertag] = b));
  return badgeCache;
}

// Private realtime channels need the signed-in token before joining.
export async function rtReady() {
  try { await sb.realtime.setAuth(); } catch (_) {}
}

export function badgesFromRows(rows) {
  const out = {};
  (rows || []).forEach((r) => (out[r.gamertag] = { world: r.world, continent: r.cont_b ?? r.continent_badges ?? (typeof r.continent === 'number' ? r.continent : 0), city: r.city_badges }));
  return out;
}

export function badgeChips(b) {
  if (!b) return '';
  const chip = (cls, label, n) => `<span class="badge ${cls}">${label}${n > 1 ? ' ×' + n : ''}</span>`;
  let out = '';
  if (Number(b.world)) out += chip('honor-world', 'World Champion', Number(b.world));
  if (Number(b.continent)) out += chip('honor-continent', 'Continental Champion', Number(b.continent));
  if (Number(b.city)) out += chip('honor-city', 'City Champion', Number(b.city));
  return out;
}

const KIND_LABEL = { world: 'World Champion', continent: 'Continental Champion', city: 'City Champion' };
export async function renderChampions(el, { limit = 12, compact = false } = {}) {
  const { data } = await sb.rpc('hall_of_fame', { p_limit: 60 });
  if (!data || !data.length) {
    el.innerHTML = `<div class="card empty" style="padding:28px">The first champions are crowned after the first month of ranked play. Your name could be up here.</div>`;
    return;
  }
  const latest = data[0].month;
  const current = data.filter((r) => r.month === latest).slice(0, limit);
  const monthName = new Date(latest + 'T12:00:00').toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  el.innerHTML = `<div class="dim" style="margin-bottom:12px">Reigning champions · ${esc(monthName)}</div>
    <div class="champ-grid${compact ? ' compact' : ''}">${current.map((r) => `
      <div class="champ champ-${esc(r.kind)}">
        <span class="champ-kind">${KIND_LABEL[r.kind] || 'Champion'}</span>
        <strong class="champ-name">${playerLink(r.gamertag)}</strong>
        <span class="dim">${r.kind === 'world' ? esc(r.city) + ', ' + esc(r.country) : esc(r.label)}</span>
      </div>`).join('')}</div>`;
}

export function monthlyRows(rows, badges = {}) {
  return rows.map((r) => {
    const n = Number(r.rank);
    const cls = n === 1 ? 'r1' : n <= 3 ? `r${n}` : '';
    return `<tr>
      <td><span class="rank ${cls}">${pad(n)}</span></td>
      <td><div class="player"><div class="avatar">${esc((r.gamertag || '?').charAt(0).toUpperCase())}</div><strong>${playerLink(r.gamertag, r.member)}</strong>
        ${n === 1 ? '<span class="badge">Current leader</span>' : ''}${memberChip(r.member)}${badgeChips(badges[r.gamertag])}</div></td>
      <td class="muted">${esc(r.city)}, ${esc(r.country)}</td>
      <td class="muted">${fmt(r.missions)}</td>
      <td><span class="score">${fmt(r.score)}</span></td>
    </tr>`;
  }).join('');
}

export async function latestWeek() {
  const { data } = await sb.from('missions').select('week_label, opens_at')
    .eq('kind', 'weekend').lte('opens_at', new Date().toISOString()).order('opens_at', { ascending: false }).limit(1);
  return data?.[0]?.week_label || null;
}
