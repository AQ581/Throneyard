// Callout cards: shared by the Callouts page and player profiles.
import { sb, $, esc, fmt, playerHref } from '/assets/app.js';

export const REACTS = [['fire', '🔥'], ['gg', 'GG'], ['crown', '👑']];
const HONOR = { world: ['honor-world', 'World Champ'], continent: ['honor-continent', 'Continental Champ'], city: ['honor-city', 'City Champ'] };

export function timeAgo(iso) {
  const s = Math.max(1, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 604800) return `${Math.floor(s / 86400)}d`;
  return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

// Escape first, then turn @gamertags into profile links. No other links are made clickable.
function bodyHTML(text) {
  return esc(text).replace(/(^|\s)@([A-Za-z0-9_.\-]{2,32})/g, (m, pre, tag) => `${pre}<a href="${playerHref(tag)}">@${tag}</a>`);
}

export function postHTML(p, { compact = false } = {}) {
  const honor = p.honor && HONOR[p.honor] ? `<span class="badge ${HONOR[p.honor][0]}">${HONOR[p.honor][1]}</span>` : '';
  const member = p.member ? '<span class="badge member">Member</span>' : '';
  const callout = p.rival ? `<div class="callout-tag">Callout → <a href="${playerHref(p.rival)}">@${esc(p.rival)}</a></div>` : '';
  const clip = p.clip_id && p.clip_title
    ? `<a class="clip-chip" href="${playerHref(p.author)}"><span class="badge">Verified run</span> ${esc(p.clip_title)} · ${fmt(p.clip_score)} pts</a>` : '';
  const actions = compact ? '' : `
    <div class="row post-actions" style="gap:8px;flex-wrap:wrap">
      ${REACTS.map(([k, label]) => `<button type="button" class="react" data-react="${k}" aria-pressed="${p.my_reaction === k}" aria-label="${k}"><span>${label}</span><span data-count>${fmt(p[k])}</span></button>`).join('')}
      ${p.reply_to ? '' : `<a class="react" href="#post-${p.id}" data-open>Reply · ${fmt(p.reply_count)}</a>`}
      <span style="flex:1"></span>
      ${p.mine ? '<button type="button" class="link-btn" data-delete>Delete</button>'
               : '<button type="button" class="link-btn" data-report>Report</button><button type="button" class="link-btn" data-block>Block</button>'}
    </div>`;
  return `<article class="post${p.reply_to ? ' reply' : ''}" id="post-${p.id}" data-id="${p.id}" data-author="${esc(p.author)}">
    <div class="row" style="gap:8px;flex-wrap:wrap;align-items:center">
      <a href="${playerHref(p.author)}" class="post-author${p.member ? ' name-member' : ''}">${esc(p.author)}</a>
      ${member}${honor}
      <span class="dim" style="font-size:13px">${esc(p.city || '')} · ${timeAgo(p.created_at)}</span>
    </div>
    ${callout}
    <p class="post-body">${bodyHTML(p.body)}</p>
    ${clip}
    ${actions}
    <p class="error post-err" role="alert" hidden></p>
  </article>`;
}

// One listener for every card inside `root`.
export function wirePosts(root, { onChange } = {}) {
  root.addEventListener('click', async (e) => {
    const card = e.target.closest('.post');
    if (!card) return;
    const id = Number(card.dataset.id);
    const err = $('.post-err', card);
    const fail = (m) => { err.textContent = m; err.hidden = false; };
    err.hidden = true;

    const react = e.target.closest('[data-react]');
    if (react) {
      const { data: { session } } = await sb.auth.getSession();
      if (!session) return fail('Sign in to react.');
      const { data, error } = await sb.rpc('react_post', { p_id: id, p_kind: react.dataset.react });
      if (error) return fail(error.message);
      card.querySelectorAll('[data-react]').forEach((b) => {
        const was = b.getAttribute('aria-pressed') === 'true';
        const now = b.dataset.react === data;
        const c = b.querySelector('[data-count]');
        c.textContent = fmt(Number(c.textContent.replace(/,/g, '')) + (now ? 1 : 0) - (was ? 1 : 0));
        b.setAttribute('aria-pressed', String(now));
      });
      return;
    }
    if (e.target.closest('[data-delete]')) {
      const b = e.target.closest('[data-delete]');
      if (b.dataset.armed !== '1') { b.dataset.armed = '1'; b.textContent = 'Tap again to delete'; return; }
      const { error } = await sb.from('posts').delete().eq('id', id);
      if (error) return fail('Couldn\'t delete. Try again.');
      card.remove(); onChange?.();
      return;
    }
    if (e.target.closest('[data-report]')) {
      const { data: { session } } = await sb.auth.getSession();
      if (!session) return fail('Sign in to report.');
      const { error } = await sb.from('post_reports').insert({ post_id: id, reason: 'Reported from feed' });
      e.target.closest('[data-report]').textContent = error && error.code !== '23505' ? 'Try again' : 'Reported';
      return;
    }
    if (e.target.closest('[data-block]')) {
      const { data: { session } } = await sb.auth.getSession();
      if (!session) return fail('Sign in to block.');
      const b = e.target.closest('[data-block]');
      if (b.dataset.armed !== '1') { b.dataset.armed = '1'; b.textContent = `Block ${card.dataset.author}?`; return; }
      const { data: who } = await sb.from('profiles').select('id').eq('gamertag', card.dataset.author).maybeSingle();
      if (!who) return fail('Player not found.');
      const { error } = await sb.from('blocks').insert({ blocker: session.user.id, blocked: who.id });
      if (error && error.code !== '23505') return fail('Couldn\'t block. Try again.');
      root.querySelectorAll(`.post[data-author="${CSS.escape(card.dataset.author)}"]`).forEach((x) => x.remove());
      onChange?.();
    }
  });
}
