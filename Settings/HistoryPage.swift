import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - History page (chromeless://history)
//
// First-party history browser served by InternalScheme, styled to match the
// settings page. Data flows over the same SettingsBridge request/reply channel
// (historyList / historyDelete / historyClear), trusted only from the internal
// origin.

let historyHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>History — chromeless</title>
<style>
  :root { --bg:#0a0a0e; --card:#131319; --card2:#17171f; --line:#23232c;
          --text:#ececf1; --dim:#8a8a93; --dim2:#b6b6c1; --accent:#5578f4; }
  * { box-sizing:border-box; }
  html,body { height:100%; margin:0; }
  body { background:var(--bg); color:var(--text);
         font:14px/1.5 -apple-system, system-ui; cursor:default; }
  .wrap { max-width:760px; margin:0 auto; padding:44px 24px 80px; }
  header { display:flex; align-items:center; gap:16px; margin-bottom:22px; }
  h2 { font-size:24px; font-weight:650; margin:0; letter-spacing:-.02em; flex:1; }
  input[type=search] { background:var(--card2); color:var(--text); border:1px solid var(--line);
          border-radius:9px; padding:8px 12px; font:13px -apple-system; width:260px;
          outline:none; transition:border-color .15s ease; -webkit-appearance:none; }
  input[type=search]:focus { border-color:var(--accent); }
  button { font:13px -apple-system; color:var(--text); background:var(--card2);
           border:1px solid var(--line); border-radius:9px; padding:7px 14px; cursor:pointer;
           transition:border-color .15s ease, color .15s ease, background .15s ease; }
  button:hover { border-color:var(--accent); }
  button.danger { color:#ff6b64; }
  button.icon { background:none; border:none; padding:4px 6px; color:var(--dim);
                opacity:0; transition:color .15s ease, opacity .15s ease; }
  button.icon:hover { color:#ff6b64; }
  .day { margin:26px 2px 8px; font-size:11px; font-weight:600; letter-spacing:.04em;
         text-transform:uppercase; color:var(--dim); }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; overflow:hidden; }
  .row { display:flex; align-items:center; gap:12px; padding:10px 16px;
         transition:background .15s ease; }
  .row:hover { background:var(--card2); }
  .row:hover button.icon { opacity:1; }
  .row + .row { border-top:1px solid var(--line); }
  .row .time { font:12px ui-monospace,"SF Mono",monospace; color:var(--dim); flex:0 0 44px; }
  .row a { color:var(--text); text-decoration:none; font-size:13.5px; font-weight:500;
           overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .row a:hover { color:var(--accent); }
  .row .host { color:var(--dim); font-size:12px; flex-shrink:0; }
  .row .main { flex:1; min-width:0; display:flex; align-items:baseline; gap:10px; }
  .empty { padding:30px 18px; color:var(--dim); font-size:13px; text-align:center; }
  .more { display:block; margin:18px auto 0; }
</style></head>
<body>
<div class="wrap">
  <header>
    <h2>History</h2>
    <input type="search" id="q" placeholder="Search history" autofocus>
    <button class="danger" id="clear">Clear all…</button>
  </header>
  <div id="list"></div>
  <button class="more" id="more" style="display:none">Show more</button>
</div>
<script>
  var bridge = window.webkit.messageHandlers.clSettingsBridge;
  var pending = {}, nextId = 1;
  window.__clSettings = {
    reply: function (id, data) { if (pending[id]) { pending[id](data); delete pending[id]; } },
    state: function () {}
  };
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

  var PAGE = 100, offset = 0, curQuery = '';
  function dayLabel(t) {
    var d = new Date(t * 1000), now = new Date();
    var sameDay = function (a, b) { return a.toDateString() === b.toDateString(); };
    if (sameDay(d, now)) return 'Today';
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (sameDay(d, y)) return 'Yesterday';
    return d.toLocaleDateString(undefined, { weekday:'long', month:'long', day:'numeric' });
  }
  function hhmm(t) {
    return new Date(t * 1000).toLocaleTimeString(undefined, { hour:'2-digit', minute:'2-digit' });
  }
  function hostOf(u) { try { return new URL(u).host.replace(/^www\\./,''); } catch (e) { return ''; } }

  function render(rows, append) {
    var list = document.getElementById('list');
    if (!append) list.innerHTML = '';
    if (!rows.length && !append) {
      list.innerHTML = '<div class="card"><div class="empty">' +
        (curQuery ? 'No matches.' : 'No history yet.') + '</div></div>';
      return;
    }
    var lastDay = append ? list.dataset.lastDay : null;
    var card = append ? list.lastElementChild : null;
    rows.forEach(function (r) {
      var day = dayLabel(r.t);
      if (day !== lastDay) {
        var h = document.createElement('div'); h.className = 'day'; h.textContent = day;
        list.appendChild(h);
        card = document.createElement('div'); card.className = 'card';
        list.appendChild(card);
        lastDay = day;
      }
      var row = document.createElement('div'); row.className = 'row';
      row.innerHTML = '<span class="time">' + hhmm(r.t) + '</span>' +
        '<span class="main"><a href="' + esc(r.url) + '">' + esc(r.title || r.url) + '</a>' +
        '<span class="host">' + esc(hostOf(r.url)) + '</span></span>' +
        '<button class="icon" title="Remove from history">✕</button>';
      row.querySelector('button').onclick = function () {
        request('historyDelete', { url: r.url }).then(function () { row.remove(); });
      };
      card.appendChild(row);
    });
    list.dataset.lastDay = lastDay;
  }

  function load(append) {
    if (!append) offset = 0;
    request('historyList', { q: curQuery, offset: offset }).then(function (rows) {
      render(rows || [], append);
      offset += (rows || []).length;
      document.getElementById('more').style.display =
        (rows && rows.length === PAGE) ? 'block' : 'none';
    });
  }

  var debounce;
  document.getElementById('q').oninput = function (e) {
    clearTimeout(debounce);
    debounce = setTimeout(function () { curQuery = e.target.value; load(false); }, 200);
  };
  document.getElementById('more').onclick = function () { load(true); };
  document.getElementById('clear').onclick = function () {
    if (!confirm('Clear all browsing history? This cannot be undone.')) return;
    request('historyClear').then(function () { load(false); });
  };
  load(false);
</script>
</body></html>
"""
