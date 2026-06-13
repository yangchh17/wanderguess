// Write-only suggestion box; the server rate-limits per uid.
import { sb, $, ensureAuth } from './core.js?v=1';

$('fb-toggle').addEventListener('click', () => {
  const c = $('fb-card'); const open = c.style.display === 'none';
  c.style.display = open ? '' : 'none';
  if (open) $('fb-text').focus();
});
$('fb-cancel').addEventListener('click', () => { $('fb-card').style.display = 'none'; $('fb-msg').textContent = ''; });
$('fb-send').addEventListener('click', async () => {
  const body = $('fb-text').value.trim(), m = $('fb-msg');
  if (body.length < 3) { m.className = 'msg err'; m.textContent = 'Tell us a bit more first.'; return; }
  $('fb-send').disabled = true;
  try {
    await ensureAuth();
    const { error } = await sb.rpc('submit_feedback', { p_body: body });
    if (error) throw error;
    $('fb-text').value = '';
    m.className = 'msg ok'; m.textContent = 'Thanks — suggestion received ✓';
    setTimeout(() => { $('fb-card').style.display = 'none'; m.textContent = ''; }, 1600);
  } catch (e) { m.className = 'msg err'; m.textContent = 'Error: ' + (e.message || e); }
  finally { $('fb-send').disabled = false; }
});
