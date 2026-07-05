import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Settings page

let settingsHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>Settings — chromeless</title>
<style>
  :root { --bg:#0a0a0e; --card:#131319; --card2:#17171f; --line:#23232c;
          --text:#ececf1; --dim:#8a8a93; --dim2:#b6b6c1; --accent:#5578f4; }
  * { box-sizing:border-box; }
  html,body { height:100%; margin:0; }
  body { background:var(--bg); color:var(--text);
         font:14px/1.5 -apple-system, system-ui; -webkit-user-select:none;
         cursor:default; display:flex; }
  /* Sidebar — Chrome/Helium style: icon + label, accent-tinted active pill */
  nav { width:232px; flex:0 0 232px; padding:24px 14px; border-right:1px solid var(--line);
        position:sticky; top:0; height:100vh; }
  nav .brand { display:flex; align-items:center; gap:9px; margin:2px 10px 24px;
               font-size:15px; font-weight:640; letter-spacing:-.01em; }
  nav .brand .dot { width:9px; height:9px; border-radius:50%; background:var(--accent); }
  nav a { display:flex; align-items:center; gap:11px; padding:9px 11px; border-radius:9px;
          color:var(--dim2); text-decoration:none; font-size:13.5px; font-weight:500; margin-bottom:3px;
          transition:background .15s ease, color .15s ease; }
  nav a svg { width:19px; height:19px; fill:currentColor; opacity:.85; flex:0 0 19px; }
  nav a.active { background:color-mix(in srgb, var(--accent) 16%, transparent); color:var(--text); }
  nav a.active svg { opacity:1; fill:var(--accent); }
  nav a:hover:not(.active) { background:#14141b; color:var(--text); }
  /* Content */
  main { flex:1; overflow-y:auto; padding:44px 52px; }
  .wrap { max-width:680px; }
  section { display:none; animation:in .24s ease-out; }
  section.active { display:block; }
  @keyframes in { from { opacity:0; transform:translateY(6px);} to {opacity:1;} }
  h2 { font-size:24px; font-weight:650; margin:0 0 3px; letter-spacing:-.02em; }
  .sub { color:var(--dim); margin:0 0 26px; font-size:13px; }
  /* Card group (Chrome settings card) */
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px;
          overflow:hidden; margin-bottom:22px; }
  .row { display:flex; align-items:center; justify-content:space-between; gap:20px;
         padding:16px 18px; }
  .row + .row { border-top:1px solid var(--line); }
  .row .t { font-size:14px; font-weight:500; }
  .row .d { color:var(--dim); font-size:12.5px; margin-top:2px; max-width:400px; }
  select { background:var(--card2); color:var(--text); border:1px solid var(--line);
           border-radius:9px; padding:7px 11px; font:13px -apple-system; min-width:150px;
           transition:border-color .15s ease; }
  select:hover { border-color:color-mix(in srgb, var(--accent) 50%, var(--line)); }
  select:focus { outline:none; border-color:var(--accent); }
  /* Toggle */
  .sw { position:relative; width:42px; height:25px; flex:0 0 42px; }
  .sw input { opacity:0; width:0; height:0; }
  .sw span { position:absolute; inset:0; background:#33333e; border-radius:999px; transition:.18s; }
  .sw span::before { content:""; position:absolute; width:19px; height:19px; left:3px; top:3px;
                     background:#fff; border-radius:50%; transition:.18s; }
  .sw input:checked + span { background:var(--accent); }
  .sw input:checked + span::before { transform:translateX(17px); }
  /* Color-scheme swatches */
  .swatches { display:flex; gap:14px; }
  .swatch { display:flex; flex-direction:column; align-items:center; gap:8px; cursor:pointer; }
  .swatch .chip { width:56px; height:56px; border-radius:14px; border:2px solid transparent;
                  box-shadow:0 0 0 1px var(--line) inset; transition:.15s; }
  .swatch.sel .chip { border-color:var(--accent); box-shadow:0 0 0 3px color-mix(in srgb, var(--accent) 30%, transparent); }
  .swatch .nm { font-size:12px; color:var(--dim2); }
  .swatch.sel .nm { color:var(--text); }
  .chip.blue { background:linear-gradient(135deg,#5578f4,#3450d1); }
  .chip.grayscale { background:linear-gradient(135deg,#9a9aa2,#5c5c63); }
  /* Small inline select for tables */
  select.mini { min-width:88px; padding:5px 8px; font-size:12px; }
  /* Buttons */
  button { font:13px -apple-system; color:var(--text); background:var(--card2);
           border:1px solid var(--line); border-radius:9px; padding:7px 14px; cursor:pointer;
           transition:border-color .15s ease, color .15s ease, background .15s ease; }
  button:hover { border-color:var(--accent); }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  button.danger { color:#ff6b64; }
  button.link { background:none; border:none; padding:4px 6px; color:var(--accent); }
  button.icon { background:none; border:none; padding:4px; color:var(--dim); }
  button.icon:hover { color:#ff6b64; }
  /* dynamic list rows */
  .list .lrow { display:flex; align-items:center; gap:12px; padding:12px 18px; }
  .list .lrow + .lrow { border-top:1px solid var(--line); }
  .lrow .host { font-size:13px; font-weight:500; flex:1; min-width:0;
                overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .lrow .usr { font-size:12px; color:var(--dim); }
  .lrow .perms { display:flex; gap:8px; align-items:center; }
  .empty { padding:22px 18px; color:var(--dim); font-size:13px; text-align:center; }
  .chk { display:flex; align-items:center; gap:9px; font-size:13px; padding:9px 0; cursor:pointer; }
  .chk input { width:16px; height:16px; accent-color:var(--accent); }
  .mono { font:12px ui-monospace,"SF Mono",monospace; color:var(--dim2);
          overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .sech { display:flex; align-items:center; justify-content:space-between;
          margin:26px 2px 10px; font-size:11px; font-weight:600; letter-spacing:.04em;
          text-transform:uppercase; color:var(--dim); }
</style></head>
<body>
<nav>
  <div class="brand"><span class="dot"></span>chromeless</div>
  <a data-s="general" class="active">
    <svg viewBox="0 0 24 24"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>General</a>
  <a data-s="appearance">
    <svg viewBox="0 0 24 24"><path d="M12 2C6.49 2 2 6.49 2 12s4.49 10 10 10c1.38 0 2.5-1.12 2.5-2.5 0-.61-.23-1.2-.64-1.67-.08-.1-.13-.21-.13-.33 0-.28.22-.5.5-.5H16c3.31 0 6-2.69 6-6 0-4.96-4.49-9-10-9zm5.5 11c-.83 0-1.5-.67-1.5-1.5S16.67 10 17.5 10s1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm-3-4C13.67 9 13 8.33 13 7.5S13.67 6 14.5 6s1.5.67 1.5 1.5S15.33 9 14.5 9zM5 11.5C5 10.67 5.67 10 6.5 10S8 10.67 8 11.5 7.33 13 6.5 13 5 12.33 5 11.5zm4-4C9 6.67 9.67 6 10.5 6S12 6.67 12 7.5 11.33 9 10.5 9 9 8.33 9 7.5z"/></svg>Appearance</a>
  <a data-s="accessibility">
    <svg viewBox="0 0 24 24"><path d="M12 2c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2zm9 7h-6v13h-2v-6h-2v6H9V9H3V7h18v2z"/></svg>Accessibility</a>
  <a data-s="privacy">
    <svg viewBox="0 0 24 24"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg>Privacy &amp; Security</a>
  <a data-s="passwords">
    <svg viewBox="0 0 24 24"><path d="M12.65 10A5.99 5.99 0 0 0 7 6c-3.31 0-6 2.69-6 6s2.69 6 6 6a5.99 5.99 0 0 0 5.65-4H17v4h4v-4h2v-4H12.65zM7 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z"/></svg>Passwords</a>
  <a data-s="downloads">
    <svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>Downloads</a>
  <a data-s="about">
    <svg viewBox="0 0 24 24"><path d="M11 7h2v2h-2V7zm0 4h2v6h-2v-6zm1-9C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z"/></svg>About</a>
</nav>
<main><div class="wrap">
  <section id="general" class="active">
    <h2>General</h2>
    <p class="sub">Search, tabs, and startup.</p>
    <div class="card">
      <div class="row">
        <div><div class="t">Default search engine</div>
          <div class="d">Used when you type a term instead of a URL.</div></div>
        <select id="searchEngine"></select>
      </div>
      <div class="row">
        <div><div class="t">Suggestions from the search engine</div>
          <div class="d">When you type in the address bar, Chromeless sends what you type to your default search engine to get suggestions.</div></div>
        <label class="sw"><input type="checkbox" id="searchSuggestions"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Open new tabs next to active</div>
          <div class="d">Otherwise new tabs go to the end of the strip.</div></div>
        <label class="sw"><input type="checkbox" id="newTabNextToActive"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Restore tabs on launch</div>
          <div class="d">Reopen your previous session at startup.</div></div>
        <label class="sw"><input type="checkbox" id="restoreTabs"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Hide the tab bar with one tab</div>
          <div class="d">Show the tab strip only once you have more than one tab. Turn off for classic mode — the tab bar stays visible always.</div></div>
        <label class="sw"><input type="checkbox" id="autoHideSingleTab"><span></span></label>
      </div>
    </div>

    <div class="sech"><span>Features</span></div>
    <div class="card">
      <div class="row">
        <div><div class="t">Preload new tabs</div>
          <div class="d">Keep the next tab pre-built in the background so ⌘T opens instantly. Uses a little extra memory.</div></div>
        <label class="sw"><input type="checkbox" id="prewarmTabs"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">!Bang shortcuts</div>
          <div class="d">Type !w, !gh, !yt… in the address bar to search a site directly. Resolved locally — no third party sees the query.</div></div>
        <label class="sw"><input type="checkbox" id="bangs"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Link preview bubble</div>
          <div class="d">Show the target URL in a bubble at the bottom-left when hovering a link.</div></div>
        <label class="sw"><input type="checkbox" id="linkPreview"><span></span></label>
      </div>
    </div>
  </section>

  <section id="appearance">
    <h2>Appearance</h2>
    <p class="sub">Color, framing, and zoom.</p>
    <div class="card">
      <div class="row">
        <div><div class="t">Accent color</div>
          <div class="d">Tints the address bar, controls, and this page.</div></div>
        <div class="swatches">
          <div class="swatch" data-scheme="blue"><div class="chip blue"></div><div class="nm">Helium</div></div>
          <div class="swatch" data-scheme="grayscale"><div class="chip grayscale"></div><div class="nm">Grayscale</div></div>
        </div>
      </div>
      <div class="row">
        <div><div class="t">Rounded frame around web content</div>
          <div class="d">Float pages as a card inset from the window chrome.</div></div>
        <label class="sw"><input type="checkbox" id="roundedFrame"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Centered address bar</div>
          <div class="d">Float the address bar centered in the toolbar instead of stretching it full-width.</div></div>
        <label class="sw"><input type="checkbox" id="centeredLocationBar"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Frameless mode</div>
          <div class="d">Automatically hide all browser UI until you hover the top edge (⌘⇧L).</div></div>
        <label class="sw"><input type="checkbox" id="zenMode"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Minimal address bar</div>
          <div class="d">Show only the site's domain when idle; the full URL returns when you click the address bar.</div></div>
        <label class="sw"><input type="checkbox" id="minimalAddressBar"><span></span></label>
      </div>
      <div class="row">
        <div><div class="t">Default page zoom</div>
          <div class="d">New sites start at this zoom.</div></div>
        <select id="defaultZoom">
          <option value="0.75">75%</option><option value="0.9">90%</option>
          <option value="1">100%</option><option value="1.1">110%</option>
          <option value="1.25">125%</option><option value="1.5">150%</option>
        </select>
      </div>
    </div>
  </section>

  <section id="accessibility">
    <h2>Accessibility</h2>
    <p class="sub">Feedback and confirmations.</p>
    <div class="card">
      <div class="row">
        <div><div class="t">Background action confirmation toasts</div>
          <div class="d">Show a toast when a link opens a new tab or content is copied.</div></div>
        <label class="sw"><input type="checkbox" id="confirmationToasts"><span></span></label>
      </div>
    </div>
  </section>

  <section id="privacy">
    <h2>Privacy &amp; Security</h2>
    <p class="sub">Blocking, site permissions, and browsing data.</p>
    <div class="card">
      <div class="row">
        <div><div class="t">Block ads &amp; trackers</div>
          <div class="d">WebKit content blocking. Applies to all tabs.</div></div>
        <label class="sw"><input type="checkbox" id="blockAds"><span></span></label>
      </div>
    </div>

    <div class="sech"><span>Site permissions</span>
      <button class="link" id="clearPerms">Reset all</button></div>
    <div class="card list" id="permsList"></div>

    <div class="sech"><span>Clear browsing data</span></div>
    <div class="card" style="padding:6px 18px 14px">
      <label class="chk"><input type="checkbox" id="cd_history" checked> Browsing history</label>
      <label class="chk"><input type="checkbox" id="cd_cookies"> Cookies and site data</label>
      <label class="chk"><input type="checkbox" id="cd_cache" checked> Cached files and images</label>
      <div style="margin-top:12px"><button class="primary" id="clearData">Clear now</button></div>
    </div>
  </section>

  <section id="passwords">
    <h2>Passwords</h2>
    <p class="sub">Saved logins, stored in your macOS login keychain.</p>
    <div class="card">
      <div class="row">
        <div><div class="t">Offer to save passwords</div>
          <div class="d">Detect login forms and offer to save &amp; fill.</div></div>
        <label class="sw"><input type="checkbox" id="autofillEnabled"><span></span></label>
      </div>
    </div>
    <div class="sech"><span>Saved logins</span></div>
    <div class="card list" id="pwList"></div>
  </section>

  <section id="downloads">
    <h2>Downloads</h2>
    <p class="sub">Where files are saved.</p>
    <div class="card">
      <div class="row">
        <div style="min-width:0; flex:1"><div class="t">Download location</div>
          <div class="d mono" id="dlPath"></div></div>
        <button id="chooseDir">Change…</button>
      </div>
    </div>
  </section>

  <section id="about">
    <h2>About</h2>
    <p class="sub">The browser that isn’t there.</p>
    <div class="card">
      <div class="row"><div class="t">chromeless</div><div class="mono" id="version"></div></div>
      <div class="row">
        <div><div class="t">A minimal WebKit browser for macOS</div>
          <div class="d">No telemetry. Native WebKit. One file.</div></div>
      </div>
    </div>
  </section>
</div></main>
<script>
  var bridge = window.webkit.messageHandlers.clSettingsBridge;
  function send(action, key, value) { bridge.postMessage({action:action, key:key, value:value}); }

  function activate(name) {
    var target = document.querySelector('nav a[data-s="' + name + '"]');
    if (!target) return;
    document.querySelectorAll('nav a').forEach(function (x){ x.classList.remove('active'); });
    document.querySelectorAll('section').forEach(function (x){ x.classList.remove('active'); });
    target.classList.add('active');
    document.getElementById(name).classList.add('active');
  }
  document.querySelectorAll('nav a').forEach(function (a) {
    a.onclick = function () { location.hash = a.dataset.s; activate(a.dataset.s); };
  });
  if (location.hash) activate(location.hash.slice(1));

  function paintSwatches(scheme) {
    document.querySelectorAll('.swatch').forEach(function (s) {
      s.classList.toggle('sel', s.dataset.scheme === scheme);
    });
  }

  // Request/response over the bridge (actions that return data carry an id).
  var pending = {}, nextId = 1;
  function request(action, extra) {
    return new Promise(function (res) {
      var id = nextId++; pending[id] = res;
      var m = { action: action, id: id };
      if (extra) for (var k in extra) m[k] = extra[k];
      bridge.postMessage(m);
    });
  }
  function esc(s){ return String(s).replace(/[&<>"]/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }

  // Native pushes current state here on load.
  window.__clSettings = {
    reply: function (id, data) { if (pending[id]) { pending[id](data); delete pending[id]; } },
    state: function (s) {
      document.documentElement.style.setProperty('--accent', s.accentHex);
      var eng = document.getElementById('searchEngine');
      eng.innerHTML = '';
      s.searchEngines.forEach(function (e) {
        var o = document.createElement('option'); o.value = e.id; o.textContent = e.label;
        eng.appendChild(o);
      });
      eng.value = s.searchEngine;
      document.getElementById('searchSuggestions').checked = s.searchSuggestions;
      document.getElementById('newTabNextToActive').checked = s.newTabNextToActive;
      document.getElementById('restoreTabs').checked = s.restoreTabs;
      document.getElementById('roundedFrame').checked = s.roundedFrame;
      document.getElementById('centeredLocationBar').checked = s.centeredLocationBar;
      document.getElementById('zenMode').checked = s.zenMode;
      document.getElementById('autoHideSingleTab').checked = s.autoHideSingleTab;
      document.getElementById('minimalAddressBar').checked = s.minimalAddressBar;
      document.getElementById('defaultZoom').value = String(s.defaultZoom);
      document.getElementById('blockAds').checked = s.blockAds;
      document.getElementById('autofillEnabled').checked = s.autofillEnabled;
      document.getElementById('confirmationToasts').checked = s.confirmationToasts;
      document.getElementById('prewarmTabs').checked = s.prewarmTabs;
      document.getElementById('bangs').checked = s.bangs;
      document.getElementById('linkPreview').checked = s.linkPreview;
      document.getElementById('dlPath').textContent = s.downloadDir;
      document.getElementById('version').textContent = 'Version ' + s.version;
      paintSwatches(s.colorScheme);
    }
  };

  document.getElementById('searchEngine').onchange = function (e){ send('set','searchEngine', e.target.value); };
  document.getElementById('defaultZoom').onchange = function (e){ send('set','defaultZoom', parseFloat(e.target.value)); };
  ['searchSuggestions','newTabNextToActive','restoreTabs','roundedFrame','centeredLocationBar','zenMode','autoHideSingleTab','minimalAddressBar','blockAds','autofillEnabled','confirmationToasts','prewarmTabs','bangs','linkPreview'].forEach(function (id) {
    document.getElementById(id).onchange = function (e){ send('set', id, e.target.checked); };
  });
  document.querySelectorAll('.swatch').forEach(function (s) {
    s.onclick = function () {
      var scheme = s.dataset.scheme;
      paintSwatches(scheme);
      send('set', 'colorScheme', scheme);
      send('get');
    };
  });

  // --- Site permissions table ---
  var PERMS = ['ask','allow','deny'], PLABEL = {ask:'Ask',allow:'Allow',deny:'Block'};
  function permSelect(origin, kind, val) {
    var opts = PERMS.map(function(p){ return '<option value="'+p+'"'+(p===val?' selected':'')+'>'+PLABEL[p]+'</option>'; }).join('');
    return '<select class="mini" data-o="'+esc(origin)+'" data-k="'+kind+'">'+opts+'</select>';
  }
  function renderPerms() {
    request('listPermissions').then(function (rows) {
      var el = document.getElementById('permsList');
      if (!rows || !rows.length) { el.innerHTML = '<div class="empty">No site permissions yet.</div>'; return; }
      el.innerHTML = rows.map(function (r) {
        return '<div class="lrow"><div class="host">'+esc(r.origin.replace(/^https?:\\/\\//,''))+'</div>'+
          '<div class="perms">📷 '+permSelect(r.origin,'camera',r.camera)+
          ' 🎙 '+permSelect(r.origin,'microphone',r.microphone)+
          '<button class="icon" title="Forget site" data-reset="'+esc(r.origin)+'">✕</button></div></div>';
      }).join('');
      el.querySelectorAll('select.mini').forEach(function (sel) {
        sel.onchange = function () {
          send2('setPermission', {origin:sel.dataset.o, permission:sel.dataset.k, decision:sel.value});
        };
      });
      el.querySelectorAll('[data-reset]').forEach(function (b) {
        b.onclick = function () { send2('resetSite', {origin:b.dataset.reset}); renderPerms(); };
      });
    });
  }
  function send2(action, extra){ var m={action:action}; if(extra) for(var k in extra) m[k]=extra[k]; bridge.postMessage(m); }
  document.getElementById('clearPerms').onclick = function () { send2('clearPermissions'); renderPerms(); };

  // --- Clear browsing data ---
  document.getElementById('clearData').onclick = function () {
    var btn = this; btn.disabled = true; btn.textContent = 'Clearing…';
    request('clearData', {flags: {
      history: document.getElementById('cd_history').checked,
      cookies: document.getElementById('cd_cookies').checked,
      cache: document.getElementById('cd_cache').checked
    }}).then(function () { btn.disabled = false; btn.textContent = 'Cleared ✓';
      setTimeout(function(){ btn.textContent = 'Clear now'; }, 1600); });
  };

  // --- Passwords ---
  function renderPasswords() {
    request('listPasswords').then(function (rows) {
      var el = document.getElementById('pwList');
      if (!rows || !rows.length) { el.innerHTML = '<div class="empty">No saved logins.</div>'; return; }
      el.innerHTML = rows.map(function (r, i) {
        return '<div class="lrow"><div style="flex:1;min-width:0">'+
          '<div class="host">'+esc(r.host)+'</div><div class="usr" id="usr'+i+'">'+esc(r.username)+'</div></div>'+
          '<button class="link" data-reveal="'+i+'">Reveal</button>'+
          '<button class="icon" title="Delete" data-del="'+i+'">🗑</button></div>';
      }).join('');
      el.querySelectorAll('[data-reveal]').forEach(function (b) {
        b.onclick = function () {
          var r = rows[b.dataset.reveal];
          request('revealPassword', {host:r.host, username:r.username}).then(function (res) {
            if (res && res.password) {
              document.getElementById('usr'+b.dataset.reveal).textContent = r.username + ' · ' + res.password;
              b.textContent = 'Hide';
              b.onclick = function () { document.getElementById('usr'+b.dataset.reveal).textContent = r.username; b.textContent='Reveal'; renderPasswords(); };
            }
          });
        };
      });
      el.querySelectorAll('[data-del]').forEach(function (b) {
        b.onclick = function () { var r = rows[b.dataset.del]; send2('deletePassword', {host:r.host, username:r.username}); renderPasswords(); };
      });
    });
  }

  // --- Downloads ---
  document.getElementById('chooseDir').onclick = function () {
    request('chooseDownloadDir').then(function (res) {
      if (res && res.path) document.getElementById('dlPath').textContent = res.path;
    });
  };

  // Lazy-load list data when its pane is first shown.
  var loaded = {};
  var origActivate = activate;
  activate = function (name) {
    origActivate(name);
    if (name === 'privacy' && !loaded.privacy) { loaded.privacy = true; renderPerms(); }
    if (name === 'passwords' && !loaded.passwords) { loaded.passwords = true; renderPasswords(); }
  };
  if (location.hash) activate(location.hash.slice(1));

  send('get');
</script>
</body></html>
"""
