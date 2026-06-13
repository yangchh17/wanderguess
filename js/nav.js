// Bottom tab bar (Stage 0 UI shell). Switches between the Play surface
// (home or lobby, depending on whether you're in a room) and Profile.
// The active indicator auto-syncs to whichever .screen is shown — so it stays
// correct even when the game module navigates on its own (create/join/leave).
import { show } from './core.js?v=1';

const bar = document.getElementById('tabbar');
const tabFor = el => el && el.dataset.tab;
function setActive(tab){ bar.querySelectorAll('.tab').forEach(b => b.classList.toggle('on', tabFor(b) === tab)); }

function inRoom(){
  try { const s = JSON.parse(localStorage.getItem('geoguessur.session') || 'null'); return !!(s && s.roomId); }
  catch { return false; }
}

bar.querySelector('[data-tab="play"]').addEventListener('click', () => show(inRoom() ? 's-lobby' : 's-home'));
bar.querySelector('[data-tab="profile"]').addEventListener('click', () => {
  window.dispatchEvent(new Event('wg:open-profile'));   // account.js loads + shows s-profile
});

// Keep the active tab in sync with the visible screen, whoever changed it.
const screens = ['s-home', 's-lobby', 's-profile'].map(id => document.getElementById(id)).filter(Boolean);
const sync = () => setActive(document.getElementById('s-profile').classList.contains('on') ? 'profile' : 'play');
const mo = new MutationObserver(sync);
screens.forEach(s => mo.observe(s, { attributes: true, attributeFilter: ['class'] }));
sync();
