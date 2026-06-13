// Shared primitives for all Wanderguess client modules.
// This module is a singleton: every importer must use the SAME specifier
// (`core.js?v=1`) so there is exactly one `sb` client and one memoized auth.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

export const $ = id => document.getElementById(id);
export const show = s => document.querySelectorAll('.screen').forEach(el => el.classList.toggle('on', el.id === s));
export function escapeHtml(s){ return s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

if (!window.SUPA || window.SUPA.url.includes('YOUR-PROJECT')) {
  const m = $('home-msg');
  if (m) { m.className = 'msg err'; m.textContent = 'Supabase not configured — copy config.example.js to config.js and fill in your project URL + anon key.'; }
}
export const sb = createClient(window.SUPA.url, window.SUPA.anonKey);

// Silent anonymous auth: every client gets a real identity (auth.uid()) so the
// server can't be told "I'm player X" — it knows. Memoized; session persists.
let _authReady = null;
export function ensureAuth(){
  if (!_authReady) _authReady = (async () => {
    const { data } = await sb.auth.getSession();
    if (!data.session) { const r = await sb.auth.signInAnonymously(); if (r.error) console.error('anon auth failed', r.error); }
  })();
  return _authReady;
}
