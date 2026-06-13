// Account (anonymous → permanent) + stats / history.
// Upgrading the anonymous user keeps the same auth.uid(), so all history carries over.
import { sb, $, show, ensureAuth, escapeHtml } from './core.js?v=1';
import { formatKm } from '../shared/geo.js?v=2';

const LS = 'geoguessur.session';   // room session key (cleared on identity change)
let acctMode = 'create';           // 'create' | 'signin'

async function refreshAccount(){
  const { data: { user } } = await sb.auth.getUser();
  const signedIn = !!(user && !user.is_anonymous && user.email);
  $('acct-status').innerHTML = signedIn
    ? `Signed in as <b>${escapeHtml(user.email)}</b>`
    : `Playing as <b>guest</b> — stats save on this device; create an account to keep them anywhere.`;
  $('acct-guest').style.display = signedIn ? 'none' : '';
  $('btn-acct-signout').style.display = signedIn ? '' : 'none';
  $('acct-form').style.display = 'none';
}
function acctMsg(t, err){ $('acct-msg').className = 'msg ' + (err ? 'err' : (t ? 'ok' : '')); $('acct-msg').textContent = t || ''; }
function openAcctForm(mode){
  acctMode = mode;
  $('acct-form').style.display = '';
  $('acct-submit').textContent = mode === 'signin' ? 'Sign in' : 'Create account';
  $('acct-pass').setAttribute('autocomplete', mode === 'signin' ? 'current-password' : 'new-password');
  acctMsg(''); $('acct-email').focus();
}
$('btn-acct-create').addEventListener('click', () => openAcctForm('create'));
$('btn-acct-signin').addEventListener('click', () => openAcctForm('signin'));
$('acct-cancel').addEventListener('click', () => { $('acct-form').style.display = 'none'; acctMsg(''); });
$('acct-submit').addEventListener('click', async () => {
  const email = $('acct-email').value.trim(), pass = $('acct-pass').value;
  if (!email || !pass) return acctMsg('Enter an email and password.', true);
  if (acctMode === 'create' && pass.length < 8) return acctMsg('Password must be at least 8 characters.', true);
  $('acct-submit').disabled = true;
  try {
    if (acctMode === 'signin') {
      const { error } = await sb.auth.signInWithPassword({ email, password: pass });
      if (error) throw error;
      localStorage.removeItem(LS);          // different identity → leave the guest room
      location.reload();                    // clean re-init under the signed-in uid
      return;
    } else {
      const { data, error } = await sb.auth.updateUser({ email, password: pass });   // upgrade in place
      if (error) throw error;
      if (data.user && data.user.email) acctMsg('Account created ✓ — your history is saved.');
      else acctMsg('Almost there — check your email to confirm your account.');
      await refreshAccount();
    }
    $('acct-form').style.display = 'none';
  } catch (e) { acctMsg('Error: ' + (e.message || e), true); }
  finally { $('acct-submit').disabled = false; }
});
$('btn-acct-signout').addEventListener('click', async () => {
  await sb.auth.signOut();
  await sb.auth.signInAnonymously();        // back to a fresh guest so play still works
  localStorage.removeItem(LS);
  location.reload();
});

async function openProfile(){
  show('s-profile');
  $('stats-grid').innerHTML = '<span class="mut">Loading…</span>';
  $('history-list').innerHTML = '<span class="mut">Loading…</span>';
  $('prof-closest').textContent = '';
  const [{ data: s }, { data: h }] = await Promise.all([ sb.rpc('get_my_stats'), sb.rpc('get_my_history') ]);
  const st = (s && s[0]) || {};
  const tiles = [
    ['Games', (st.games || 0).toLocaleString()],
    ['Total pts', (st.total_points || 0).toLocaleString()],
    ['Avg / game', (st.avg_points || 0).toLocaleString()],
    ['Best game', (st.best_game || 0).toLocaleString()],
    ['Photos', (st.total_photos || 0).toLocaleString()],
    ['Best photo', (st.best_points || 0).toLocaleString()],
  ];
  $('stats-grid').innerHTML = tiles.map(([k, v]) => `<div class="stat"><div class="v">${v}</div><div class="k">${k}</div></div>`).join('');
  $('prof-closest').textContent = (st.closest_km != null) ? `Closest guess ever: ${formatKm(st.closest_km)}.` : '';
  const rows = h || [];
  $('history-list').innerHTML = rows.length ? rows.map(r => {
    const d = new Date(r.finished_at), ds = isNaN(d) ? '' : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    return `<div class="hrow"><span class="hcode">${escapeHtml(r.room_code || '—')}</span>` +
      `<span class="hmeta">${ds} · ${r.photos_guessed} photo${r.photos_guessed === 1 ? '' : 's'}</span>` +
      `<span class="hpts">${(r.points || 0).toLocaleString()}</span></div>`;
  }).join('') : '<span class="mut">No games yet — play a round to start your history.</span>';
}
// The bottom tab bar (js/nav.js) requests the profile view via this event.
window.addEventListener('wg:open-profile', () => { refreshAccount(); openProfile(); });

ensureAuth().then(refreshAccount);
