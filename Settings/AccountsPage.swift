import Cocoa
import WebKit

// MARK: - Accounts page (chromeless://accounts)
//
// First-party manager for identities (per-tab account containers) and their
// site-routing rules, served by InternalScheme and styled to match the history /
// settings pages. Data flows over the shared SettingsBridge request/reply channel
// (identityList / identityCreate / identityUpdate / identityDelete /
// identityClearData / bindingList / bindingDelete / openInIdentity), trusted only
// from the internal origin.

let accountsHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>Accounts — chromeless</title>
<style>
  :root { --bg:#0a0a0e; --card:#131319; --card2:#17171f; --line:#23232c;
          --text:#ececf1; --dim:#8a8a93; --dim2:#b6b6c1; --accent:#5578f4; }
  * { box-sizing:border-box; }
  html,body { height:100%; margin:0; }
  body { background:var(--bg); color:var(--text);
         font:14px/1.5 -apple-system, system-ui; cursor:default; }
  .wrap { max-width:760px; margin:0 auto; padding:44px 24px 90px; }
  header { display:flex; align-items:center; gap:16px; margin-bottom:8px; }
  h2 { font-size:24px; font-weight:650; margin:0; letter-spacing:-.02em; flex:1; }
  .sub { color:var(--dim); font-size:13px; margin:0 0 26px; }
  .sect { margin:34px 2px 12px; font-size:11px; font-weight:600; letter-spacing:.04em;
          text-transform:uppercase; color:var(--dim); }
  button { font:13px -apple-system; color:var(--text); background:var(--card2);
           border:1px solid var(--line); border-radius:9px; padding:7px 14px; cursor:pointer;
           transition:border-color .15s ease, color .15s ease, background .15s ease; }
  button:hover { border-color:var(--accent); }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; font-weight:550; }
  button.primary:hover { filter:brightness(1.08); }
  button.danger:hover { border-color:#ff6b64; color:#ff6b64; }
  button.small { padding:5px 10px; font-size:12px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px;
          padding:16px 18px; margin-bottom:12px; }
  .crow { display:flex; align-items:center; gap:14px; }
  .avatar { width:40px; height:40px; border-radius:12px; flex:0 0 40px; display:flex;
            align-items:center; justify-content:center; font-size:19px; font-weight:600;
            color:#fff; }
  .meta { flex:1; min-width:0; }
  .name { background:none; border:none; color:var(--text); font:600 16px -apple-system;
          padding:2px 4px; margin:-2px -4px; border-radius:6px; width:100%;
          letter-spacing:-.01em; outline:none; }
  .name:focus { background:var(--card2); }
  .badges { display:flex; gap:6px; margin-top:3px; }
  .badge { font-size:10.5px; font-weight:600; letter-spacing:.03em; text-transform:uppercase;
           color:var(--dim2); background:var(--card2); border:1px solid var(--line);
           border-radius:6px; padding:1px 7px; }
  .actions { display:flex; gap:8px; flex-shrink:0; }
  .edit { margin-top:14px; padding-top:14px; border-top:1px solid var(--line);
          display:none; gap:18px; flex-wrap:wrap; align-items:center; }
  .card.open .edit { display:flex; }
  .field { display:flex; flex-direction:column; gap:6px; }
  .field label { font-size:11px; color:var(--dim); font-weight:600; letter-spacing:.03em;
                 text-transform:uppercase; }
  .swatches { display:flex; gap:7px; }
  .sw { width:22px; height:22px; border-radius:50%; cursor:pointer; border:2px solid transparent;
        transition:transform .1s ease; }
  .sw:hover { transform:scale(1.14); }
  .sw.on { border-color:var(--text); }
  .txt { background:var(--card2); color:var(--text); border:1px solid var(--line);
         border-radius:8px; padding:6px 10px; font:13px -apple-system; outline:none;
         -webkit-appearance:none; }
  .txt:focus { border-color:var(--accent); }
  .txt.emoji { width:52px; text-align:center; font-size:16px; }
  .txt.email { width:210px; }
  .brow { display:flex; align-items:center; gap:12px; padding:11px 16px; }
  .brow + .brow { border-top:1px solid var(--line); }
  .bhost { flex:1; font-size:13.5px; font-weight:500; }
  .chip { display:inline-flex; align-items:center; gap:6px; font-size:12px; color:var(--dim2); }
  .chip .dot { width:9px; height:9px; border-radius:50%; }
  .empty { padding:22px 16px; color:var(--dim); font-size:13px; text-align:center; }
  .note { color:var(--dim); font-size:12px; margin:6px 4px 0; }
  .x { background:none; border:none; color:var(--dim); cursor:pointer; padding:4px 6px;
       border-radius:6px; font-size:14px; }
  .x:hover { color:#ff6b64; }
</style></head>
<body>
<div class="wrap">
  <header>
    <h2>Accounts</h2>
    <button class="primary" id="add">New Identity</button>
  </header>
  <p class="sub">Each identity is a separate container with its own cookies and logins —
     sign into two accounts on the same site, side by side. Tabs are color-tagged;
     pinned sites always open in their container.</p>
  <p class="note" id="persistNote" style="display:none">
     ⚠︎ This macOS version can't save non-default containers to disk — their sessions
     reset when you quit. Upgrade to macOS 14+ for persistent containers.</p>

  <div id="list"></div>

  <div class="sect">Site routing rules</div>
  <div class="card" style="padding:0"><div id="bindings"></div></div>
</div>
<script>
  var bridge = window.webkit.messageHandlers.clSettingsBridge;
  var pending = {}, nextId = 1;
  window.__clSettings = {
    reply: function (id, data) { if (pending[id]) { pending[id](data); delete pending[id]; } },
    state: function (s) {
      if (s && s.accentHex) document.documentElement.style.setProperty('--accent', s.accentHex);
    }
  };
  bridge.postMessage({ action: 'get' });
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

  var PALETTE = ['#3B82F6','#10B981','#F59E0B','#EF4444','#8B5CF6','#EC4899','#14B8A6','#F97316'];

  function initialOf(i){ return (i.emoji || (i.name||'?').charAt(0).toUpperCase()); }

  function card(i) {
    var el = document.createElement('div'); el.className = 'card';
    var badges = '';
    if (i.isDefault) badges += '<span class="badge">Default</span>';
    if (i.ephemeral) badges += '<span class="badge">Temporary</span>';

    var sw = PALETTE.map(function (c) {
      return '<div class="sw' + (c.toLowerCase()===i.color.toLowerCase()?' on':'') +
             '" data-c="' + c + '" style="background:' + c + '"></div>';
    }).join('');

    el.innerHTML =
      '<div class="crow">' +
        '<div class="avatar" style="background:' + esc(i.color) + '">' + esc(initialOf(i)) + '</div>' +
        '<div class="meta">' +
          '<input class="name" value="' + esc(i.name) + '">' +
          '<div class="badges">' + badges + '</div>' +
        '</div>' +
        '<div class="actions">' +
          '<button class="small gmail">Open Gmail</button>' +
          '<button class="small toggle">Edit</button>' +
        '</div>' +
      '</div>' +
      '<div class="edit">' +
        '<div class="field"><label>Color</label><div class="swatches">' + sw + '</div></div>' +
        '<div class="field"><label>Avatar emoji</label>' +
          '<input class="txt emoji" maxlength="2" value="' + esc(i.emoji||'') + '" placeholder="🙂"></div>' +
        '<div class="field"><label>Linked email</label>' +
          '<input class="txt email" value="' + esc(i.email||'') + '" placeholder="you@gmail.com"></div>' +
        '<div class="field" style="flex:1"></div>' +
        '<div class="field"><label>&nbsp;</label><div class="actions">' +
          '<button class="small clear">Clear data</button>' +
          (i.isDefault ? '' : '<button class="small danger del">Delete</button>') +
        '</div></div>' +
      '</div>';

    var avatar = el.querySelector('.avatar');
    var nameEl = el.querySelector('.name');
    function save(extra) {
      var body = { id: i.id, name: nameEl.value }; for (var k in extra) body[k] = extra[k];
      request('identityUpdate', body);
    }
    nameEl.onchange = function () { i.name = nameEl.value; avatar.textContent = initialOf(i); save({}); };
    nameEl.onkeydown = function (e) { if (e.key === 'Enter') nameEl.blur(); };

    el.querySelector('.toggle').onclick = function () { el.classList.toggle('open'); };

    el.querySelectorAll('.sw').forEach(function (s) {
      s.onclick = function () {
        i.color = s.dataset.c;
        el.querySelectorAll('.sw').forEach(function (o){ o.classList.remove('on'); });
        s.classList.add('on'); avatar.style.background = i.color; save({ color: i.color });
      };
    });
    var emojiEl = el.querySelector('.txt.emoji');
    emojiEl.onchange = function () { i.emoji = emojiEl.value; avatar.textContent = initialOf(i); save({ emoji: emojiEl.value }); };
    var emailEl = el.querySelector('.txt.email');
    emailEl.onchange = function () { i.email = emailEl.value; save({ email: emailEl.value }); };

    el.querySelector('.gmail').onclick = function () {
      request('openInIdentity', { id: i.id, url: 'https://mail.google.com/' });
    };
    el.querySelector('.clear').onclick = function () {
      if (!confirm('Clear all cookies, storage and logins for "' + i.name + '"?')) return;
      request('identityClearData', { id: i.id }).then(function () { flash(el, 'Data cleared'); });
    };
    var del = el.querySelector('.del');
    if (del) del.onclick = function () {
      if (!confirm('Delete "' + i.name + '"? Its tabs close and all its data is erased.')) return;
      request('identityDelete', { id: i.id }).then(function () { loadIdentities(); loadBindings(); });
    };
    return el;
  }

  function flash(el, msg) {
    var b = el.querySelector('.badges');
    var t = document.createElement('span'); t.className = 'badge'; t.textContent = msg;
    t.style.color = 'var(--accent)'; b.appendChild(t);
    setTimeout(function () { t.remove(); }, 1600);
  }

  function loadIdentities() {
    request('identityList').then(function (res) {
      document.getElementById('persistNote').style.display = res.canPersist ? 'none' : 'block';
      var list = document.getElementById('list'); list.innerHTML = '';
      (res.identities || []).forEach(function (i) { list.appendChild(card(i)); });
    });
  }

  function loadBindings() {
    request('bindingList').then(function (rows) {
      var box = document.getElementById('bindings'); box.innerHTML = '';
      if (!rows || !rows.length) {
        box.innerHTML = '<div class="empty">No pinned sites yet. Use “Always open … here” from the container menu next to the tabs.</div>';
        return;
      }
      rows.forEach(function (b) {
        var row = document.createElement('div'); row.className = 'brow';
        row.innerHTML = '<span class="bhost">' + esc(b.host) + '</span>' +
          '<span class="chip"><span class="dot" style="background:' + esc(b.color) + '"></span>' +
          esc(b.identityName) + '</span><button class="x" title="Remove rule">✕</button>';
        row.querySelector('.x').onclick = function () {
          request('bindingDelete', { host: b.host }).then(function () { row.remove();
            if (!document.getElementById('bindings').children.length) loadBindings(); });
        };
        box.appendChild(row);
      });
    });
  }

  document.getElementById('add').onclick = function () {
    var name = prompt('Name this identity (e.g. Work, Personal, Client):');
    if (!name) return; name = name.trim(); if (!name) return;
    request('identityCreate', { name: name }).then(function (r) {
      if (r && r.error) { alert('Could not create identity.'); return; }
      loadIdentities();
    });
  };

  loadIdentities();
  loadBindings();
</script>
</body></html>
"""
