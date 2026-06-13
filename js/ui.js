// UI enhancements (decoupled — reads the DOM only): toast, copy/share invite,
// host-setup steppers + time pills, score "pop", how-to-play overlay.
(function(){
  const $ = id => document.getElementById(id);

  // ── Toast ──
  const tc = document.createElement('div'); tc.className = 'toast'; document.body.appendChild(tc);
  let tt; const toast = (msg, type) => {
    tc.textContent = msg; tc.className = 'toast show ' + (type || '');
    clearTimeout(tt); tt = setTimeout(() => { tc.className = 'toast ' + (type || ''); }, 1900);
  };

  const roomCode = () => ($('room-code') ? $('room-code').textContent : '').replace(/[^A-Z0-9]/gi, '');

  // ── Copy code ──
  $('btn-copy') && $('btn-copy').addEventListener('click', async () => {
    const c = roomCode(); if (!c) return;
    try { await navigator.clipboard.writeText(c); toast('Code copied', 'good'); }
    catch { toast('Code: ' + c); }
  });

  // ── Share invite ──
  $('btn-share') && $('btn-share').addEventListener('click', async () => {
    const c = roomCode(); if (!c) return;
    const url = location.origin + location.pathname;
    const text = `Join my Wanderguess room — code ${c}`;
    if (navigator.share) { try { await navigator.share({ title: 'Wanderguess', text, url }); } catch {} }
    else { try { await navigator.clipboard.writeText(`${text}\n${url}`); toast('Invite copied', 'good'); }
           catch { toast('Code: ' + c); } }
  });

  // ── Photo-count steppers (write to #ppp; the game module reads its .value) ──
  const ppp = $('ppp');
  const stepPPP = d => { let v = (parseInt(ppp.value, 10) || 3) + d; ppp.value = Math.max(1, Math.min(5, v)); };
  $('ppp-dec') && $('ppp-dec').addEventListener('click', () => stepPPP(-1));
  $('ppp-inc') && $('ppp-inc').addEventListener('click', () => stepPPP(1));

  // ── Time-per-photo segmented control (writes to hidden #spp) ──
  const seg = $('spp-seg');
  seg && seg.addEventListener('click', e => {
    const b = e.target.closest('.seg'); if (!b) return;
    seg.querySelectorAll('.seg').forEach(x => x.classList.toggle('on', x === b));
    $('spp').value = b.dataset.val;
  });

  // ── Score / points "pop" on change (observes text, no module changes) ──
  const bump = id => {
    const el = $(id); if (!el) return;
    new MutationObserver(() => { el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump'); })
      .observe(el, { childList: true, characterData: true, subtree: true });
  };
  bump('g-score');

  // ── Help / how-to-play overlay ──
  (function(){
    const overlay = $('help-overlay');
    if (!overlay) return;
    const openHelp  = () => overlay.classList.add('on');
    const closeHelp = () => overlay.classList.remove('on');
    $('btn-help').addEventListener('click', openHelp);
    $('help-close-btn').addEventListener('click', closeHelp);
    $('help-got-it').addEventListener('click', closeHelp);
    overlay.addEventListener('click', e => { if (e.target === overlay) closeHelp(); });
    // Auto-show once for first-time visitors
    if (!localStorage.getItem('wg.seen-help')) {
      openHelp();
      localStorage.setItem('wg.seen-help', '1');
    }
  })();
})();
