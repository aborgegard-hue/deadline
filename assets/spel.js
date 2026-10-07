/* Deadline UF. State and private roles come ONLY from the authenticated RPC.
   There is no role deck, solution, service key or client-side role assignment here. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const cfg = window.DEADLINE_CONFIG || {};
  const storageKey = 'deadline.game.v1';
  const sdkUrl = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3/dist/umd/supabase.js';
  const qrUrl = 'https://cdn.jsdelivr.net/npm/qrcode-generator@2.0.4/dist/qrcode.js';
  let client, state, busy = false, blocked = false, roleVisible = false;
  let pollTimer, qrPromise, renderedQr = '', lastPoll = 0;
  let syncServerTime = 0, syncPerformance = 0, queue = Promise.resolve();
  let captchaToken = '', captchaWidget, saved = null;
  const show = (id, yes) => { $(id).hidden = !yes; };
  const text = (id, value) => { $(id).textContent = value ?? ''; };
  const make = (tag, value, cls) => {
    const node = document.createElement(tag); node.textContent = value ?? '';
    if (cls) node.className = cls;
    return node;
  };
  function notice(message, ok = false) {
    text('notice', message); $('notice').classList.toggle('ok', ok);
  }
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script'); s.src = src; s.async = true;
      const timeout = setTimeout(() => { s.remove(); reject(new Error('Biblioteket kunde inte laddas. Kontrollera anslutningen och ladda om sidan.')); }, 20000);
      s.onload = () => { clearTimeout(timeout); resolve(); };
      s.onerror = () => { clearTimeout(timeout); reject(new Error('Ett bibliotek kunde inte laddas. Kontrollera anslutningen och ladda om sidan.')); };
      document.head.appendChild(s);
    });
  }
  function publicKey(key) {
    if (key.startsWith('sb_publishable_')) return true;
    try {
      const part = key.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      return JSON.parse(atob(part.padEnd(Math.ceil(part.length / 4) * 4, '='))).role === 'anon';
    } catch { return false; }
  }
  function controls() {
    $('create').disabled = !client || busy;
    $('join').disabled = !client || busy;
    if (!state) return;
    const off = busy || blocked;
    $('deal').disabled = off || state.players.length !== state.capacity;
    $('ready').disabled = off || state.me.ready;
    $('start').disabled = off || !state.can_start;
    $('vote').disabled = off || state.me.voted;
    $('suspect').disabled = off || state.me.voted;
    $('finish').disabled = off || !state.can_finish;
    $('leave').disabled = off;
    document.querySelectorAll('.kick').forEach(b => { b.disabled = off; });
  }
  async function identity() {
    const { data, error } = await client.auth.getSession();
    if (error) throw new Error('Kunde inte kontrollera din session. Ladda om utan att rensa webbdata.');
    if (data.session) return data.session.user.id;
    if (cfg.turnstileSiteKey && !captchaToken) throw new Error('Slutför säkerhetskontrollen först.');
    try {
      const result = await client.auth.signInAnonymously({ options: { captchaToken: captchaToken || undefined } });
      if (result.error) {
        if (result.error.code === 'anonymous_provider_disabled') throw new Error('Administratören behöver aktivera Anonymous Sign-Ins i Supabase.');
        if (result.error.status === 429) throw new Error('För många anslutningar från samma nätverk. Vänta och försök igen.');
        throw new Error('Kunde inte skapa en spelarsession. Kontrollera anslutningen, Anonymous Sign-Ins och eventuell CAPTCHA.');
      }
      return result.data.user.id;
    } finally {
      captchaToken = '';
      if (captchaWidget !== undefined) window.turnstile.reset(captchaWidget);
    }
  }
  function rpc(action, payload) {
    const task = async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 15000);
      try {
        const { data, error } = await client.rpc('deadline', { action, payload }).abortSignal(controller.signal);
        if (error) {
          if (error.code === 'PGRST202') throw new Error('Databasfunktionen saknas. Kör 01_schema.sql i rätt Supabase-projekt.');
          throw new Error('Databasen svarar inte eller sessionen kunde inte verifieras. Behåll fliken och försök igen.');
        }
        if (data?.error) { const e = new Error(data.error); e.gameError = true; throw e; }
        if (!data || typeof data !== 'object') throw new Error('Oväntat svar från servern.');
        return data;
      } finally { clearTimeout(timer); }
    };
    const result = queue.then(task, task); queue = result.catch(() => {}); return result;
  }
  function remember(s) {
    saved = { id: s.id, code: s.code };
    localStorage.setItem(storageKey, JSON.stringify(saved));
  }
  function accept(s) {
    if (state?.id !== s.id) { roleVisible = false; renderedQr = ''; }
    state = s; blocked = false;
    syncServerTime = Date.parse(s.server_now); syncPerformance = performance.now();
    remember(s); render();
  }
  function inviteLink() {
    const url = new URL(location.href); url.search = ''; url.hash = '';
    url.searchParams.set('kod', state.code); return url.href;
  }
  async function drawQr() {
    const link = inviteLink(); text('invite-link', link);
    if (renderedQr === link) return;
    renderedQr = link;
    try {
      qrPromise ||= loadScript(qrUrl); await qrPromise;
      if (!state || inviteLink() !== link) return;
      const qr = window.qrcode(0, 'M'); qr.addData(link); qr.make();
      // Trusted SVG generated locally from a join URL; no third-party QR service.
      $('qr').innerHTML = qr.createSvgTag({ cellSize: 4, margin: 16, scalable: true });
    } catch {
      renderedQr = ''; qrPromise = null;
      text('qr', 'QR-koden kunde inte laddas. Dela länken eller spelkoden.');
    }
  }
  function renderRole() {
    const role = state?.me.role;
    show('role-content', !!role && roleVisible);
    $('toggle-role').setAttribute('aria-expanded', String(roleVisible));
    text('toggle-role', roleVisible ? 'Dölj min roll' : 'Visa min roll');
    // Remove sensitive text from the DOM when hidden (it remains only in this player's memory).
    for (const id of ['persona-name', 'persona-job', 'murderer']) text(id, '');
    $('role-fields').replaceChildren();
    if (!role || !roleVisible) return;
    text('persona-name', role.name); text('persona-job', role.occupation);
    text('murderer', role.is_murderer ? 'Du är mördaren. Håll det hemligt.' : 'Du är oskyldig till mordet.');
    for (const [field, title] of [['background','Vem du är'],['knows','Vad du vet'],['secret','Din hemlighet'],['objective','Ditt mål'],['rules','Dina regler']]) {
      $('role-fields').append(make('h5', title), make('p', role[field]));
    }
  }
  function render() {
    show('entry', false); show('room', true); show('welcome', false);
    const s = state, lobby = s.phase === 'lobby', briefing = s.phase === 'briefing';
    const playing = s.phase === 'playing', finished = s.phase === 'finished';
    text('phase', { lobby: '01 / Samla gruppen', briefing: '02 / Läs era roller', playing: '03 / Utredningen pågår', finished: '04 / Fallet avslutat' }[s.phase]);
    text('case-title', s.title); text('room-code', s.code);
    text('player-count', `${s.players.length} / ${s.capacity}`);
    show('invite', lobby); if (lobby) drawQr();
    show('clock-box', playing); show('deal', lobby && s.me.is_host);
    show('start', briefing && s.me.is_host); show('leave', lobby && !s.me.is_host);
    show('intro-panel', !lobby); text('introduction', s.introduction);
    show('role-panel', !!s.me.role && !finished); renderRole();
    show('ready', briefing && !s.me.ready);
    show('clue-panel', playing || finished); show('vote-form', playing);
    show('finish', !!s.can_finish); show('solution', finished);
    text('lobby-help', lobby ? 'Kontrollera att bara rätt personer är med. När rollerna delas ut låses gruppen.' : briefing ? 'Läs era roller privat. Läs sedan den gemensamma bakgrunden och låt värden starta.' : 'Privata hemligheter visas bara på respektive spelares mobil.');
    const people = s.players.map((p, index) => {
      const li = make('li'), who = make('div', '', 'identity');
      const label = p.persona || `Spelare ${index + 1}`;
      who.append(make('strong', label + (p.id === s.me.id ? ' (du)' : '')), make('small', lobby ? (p.id === s.me.id && s.me.is_host ? 'Värd / inväntar roll' : 'Inväntar roll') : ''));
      li.append(who, make('small', briefing ? (p.ready ? 'Redo' : 'Läser') : playing ? (p.voted ? 'Anklagelse klar' : '') : ''));
      if (lobby && s.me.is_host && p.id !== s.me.id) {
        const kick = make('button', 'Ta bort', 'kick'); kick.type = 'button';
        kick.setAttribute('aria-label', `Ta bort ${label} från lobbyn`);
        kick.onclick = () => { if (confirm(`Ta bort ${label}?`)) act('kick', { player_id: p.id }); };
        li.append(kick);
      }
      return li;
    });
    $('players').replaceChildren(...people);
    $('clues').replaceChildren(...s.clues.map(c => { const box = make('article', '', 'clue'); box.append(make('h4', c.title), make('p', c.body)); return box; }));
    const selected = $('suspect').value || s.me.vote || '';
    const options = [new Option('Välj en person', ''), ...s.players.map(p => new Option(p.persona || `Spelare ${s.players.indexOf(p) + 1}`, p.id))];
    $('suspect').replaceChildren(...options); $('suspect').value = selected;
    text('vote-status', s.me.voted ? 'Din slutanklagelse är låst. Inga andras val visas innan slutet.' : 'Du lämnar ditt val privat.');
    if (finished && s.solution) {
      text('solution-person', s.solution.persona);
      text('solution-text', s.solution.text);
      const killer = s.players.find(p => p.persona === s.solution.persona);
      text('my-result', !s.me.vote ? 'Du lämnade ingen slutanklagelse.' : s.me.vote === killer?.id ? 'Du pekade ut rätt person.' : 'Du pekade ut en annan person.');
    }
    controls(); tick();
  }
  function tick() {
    if (!state?.started_at || state.phase !== 'playing') return;
    const serverNow = syncServerTime + performance.now() - syncPerformance;
    const end = Date.parse(state.started_at) + state.duration_seconds * 1000;
    const seconds = Math.max(0, Math.ceil((end - serverNow) / 1000));
    text('clock', `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`);
  }
  function schedule(delay = 4000) {
    clearTimeout(pollTimer);
    if (state && !blocked && state.phase !== 'finished') pollTimer = setTimeout(poll, delay);
  }
  async function poll() {
    if (!state || busy || document.hidden) { schedule(5000); return; }
    const id = state.id;
    try {
      const s = await rpc('state', { game_id: id });
      if (state?.id !== id) return;
      accept(s); lastPoll = 0; notice('Ansluten. Omgången uppdateras automatiskt.', true);
    } catch (e) {
      if (state?.id !== id) return;
      if (e.gameError) blocked = true;
      notice(e.message); controls(); lastPoll = Math.min(30000, (lastPoll || 4000) * 2);
    } finally { schedule(lastPoll || 4000); }
  }
  async function act(action, payload = {}) {
    if (busy) return;
    busy = true; clearTimeout(pollTimer); controls();
    try {
      if (action === 'create' || action === 'join') {
        const uid = await identity();
        // Stable internal label for retries; players use their persona names.
        payload = { ...payload, name: 'Spelare ' + uid.replace(/-/g, '').slice(0, 16) };
      }
      const s = await rpc(action, { ...(state ? { game_id: state.id } : {}), ...payload });
      if (s.left) { localStorage.removeItem(storageKey); saved = null; goBack(); }
      else accept(s);
      notice('Klart. Omgången är uppdaterad.', true);
    } catch (e) { notice(e.message); }
    finally { busy = false; controls(); schedule(); }
  }
  function goBack() {
    clearTimeout(pollTimer); state = null; blocked = false; roleVisible = false;
    $('role-fields').replaceChildren();
    for (const id of ['persona-name','persona-job','murderer']) text(id, '');
    show('role-content', false); show('room', false); show('entry', true); show('welcome', true);
    show('create-form', true);
    const url = new URL(location.href); url.searchParams.delete('kod'); history.replaceState(null, '', url.href);
    show('resume', !!saved); controls();
    notice('Din spelarsession finns kvar i den här webbläsaren.', true);
    $('entry').scrollIntoView({ block: 'start' });
  }
  async function resume() {
    if (!saved || busy) return;
    busy = true; controls();
    try {
      const { data, error } = await client.auth.getSession();
      if (error || !data.session) throw new Error('Den gamla spelarsessionen saknas. Återgå till samma webbläsare som tidigare. En roll kan bara återtas med samma spelarsession.');
      accept(await rpc('state', { game_id: saved.id }));
      notice('Du är tillbaka i samma omgång med samma roll.', true);
    } catch (e) {
      notice(e.message);
      if (e.gameError) { saved = null; localStorage.removeItem(storageKey); show('resume', false); }
    } finally { busy = false; controls(); schedule(); }
  }
  $('create-form').addEventListener('submit', e => {
    e.preventDefault(); act('create', { capacity: Number($('capacity').value) });
  });
  $('join-form').addEventListener('submit', e => {
    e.preventDefault(); act('join', { code: $('code').value.toUpperCase().replace(/[\s-]/g, '') });
  });
  $('vote-form').addEventListener('submit', e => {
    e.preventDefault();
    if (confirm('Lås din slutanklagelse? Den kan inte ändras.')) act('vote', { player_id: $('suspect').value });
  });
  for (const action of ['deal', 'ready', 'start']) $(action).onclick = () => act(action);
  $('finish').onclick = () => { if (confirm('Avsluta utredningen och visa facit för alla?')) act('finish'); };
  $('leave').onclick = () => { if (confirm('Lämna den här lobbyn?')) act('leave'); };
  $('toggle-role').onclick = () => { roleVisible = !roleVisible; renderRole(); };
  $('back').onclick = goBack; $('new-game').onclick = goBack; $('resume').onclick = resume;
  $('copy').onclick = async () => {
    try { await navigator.clipboard.writeText(inviteLink()); notice('Inbjudningslänken är kopierad.', true); }
    catch { notice('Kopiera länken under knappen manuellt eller dela spelkoden.'); }
  };
  document.addEventListener('visibilitychange', () => {
    roleVisible = false; renderRole();
    if (!document.hidden && state && state.phase !== 'finished') schedule(50);
  });
  window.addEventListener('online', () => { if (state) { blocked = false; schedule(50); } });
  window.addEventListener('offline', () => notice('Du är offline. Behåll fliken. Spelets tid fortsätter på servern.'));
  setInterval(tick, 1000);
  async function init() {
    const code = new URL(location.href).searchParams.get('kod');
    const inviteCode = (code || '').toUpperCase().replace(/[\s-]/g, '');
    const validInvite = /^[A-F0-9]{10}$/.test(inviteCode);
    if (code) {
      $('code').value = inviteCode;
      show('create-form', false);
      text('code-help', 'Inbjudan tar dig direkt till den här lobbyn.');
    }
    if (!cfg.supabaseUrl || !cfg.supabasePublishableKey) {
      notice('Databasen är inte ansluten än. Spelsidan är upplagd, men lobby och roller aktiveras först när Supabase har kopplats in.');
      return;
    }
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(cfg.supabaseUrl) || !publicKey(cfg.supabasePublishableKey)) {
      throw new Error('Ogiltig konfiguration. Använd Supabase-projektets HTTPS-adress och en publishable/anon-nyckel, aldrig en hemlig nyckel.');
    }
    try {
      localStorage.setItem('deadline.storage-test', '1'); localStorage.removeItem('deadline.storage-test');
      saved = JSON.parse(localStorage.getItem(storageKey) || 'null');
      if (saved && (typeof saved.id !== 'string' || typeof saved.code !== 'string')) saved = null;
    } catch { throw new Error('Webbläsaren tillåter inte att din session sparas. Tillåt webbplatsdata och ladda om.'); }
    await loadScript(sdkUrl);
    client = window.supabase.createClient(cfg.supabaseUrl.replace(/\/$/, ''), cfg.supabasePublishableKey, {
      auth: { storageKey: 'deadline.auth.v1', persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    });
    const { data, error } = await client.auth.getSession();
    if (error) throw new Error('Sessionen kunde inte läsas. Försök ladda om sidan.');
    if (cfg.turnstileSiteKey && !data.session) {
      await loadScript('https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit');
      captchaWidget = window.turnstile.render('#captcha', {
        sitekey: cfg.turnstileSiteKey, theme: 'dark',
        callback: token => { captchaToken = token; if (validInvite && !state) act('join', { code: inviteCode }); },
        'expired-callback': () => { captchaToken = ''; },
        'error-callback': () => { captchaToken = ''; notice('Säkerhetskontrollen misslyckades. Försök igen.'); }
      });
    }
    controls(); show('resume', !!saved);
    notice('Redo. Skapa en lobby eller gå med via en spelkod.', true);
    if (saved && (!code || saved.code === inviteCode) && data.session) await resume();
    else if (validInvite && (!cfg.turnstileSiteKey || data.session || captchaToken)) {
      notice('Ansluter till spelet...');
      await act('join', { code: inviteCode });
    } else if (code && !validInvite) notice('Inbjudningslänken har en ogiltig spelkod. Be värden om en ny länk.');
  }
  init().catch(e => { client = null; controls(); notice(e.message); });
})();
