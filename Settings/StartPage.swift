import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Start page

let startPageHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>chromeless</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { background: #0a0a0e; color: #e8e8ee; font: 15px/1.6 -apple-system, system-ui;
         display: flex; align-items: center; justify-content: center;
         -webkit-user-select: none; cursor: default; }
  main { text-align: center; max-width: 680px; padding: 48px; animation: in .6s ease-out; }
  @keyframes in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
  h1 { font-size: 46px; font-weight: 650; letter-spacing: -.02em; margin: 0 0 6px; color: #fff; }
  p.tag { color: #85858f; margin: 0 0 46px; font-size: 16px; }
  .keys { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
          justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 48px; color: #55555e; font-size: 12px; }
</style></head>
<body><main>
  <h1>chromeless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="keys">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; T</kbd> <kbd>&#8984; W</kbd></div><div>new tab / close tab</div>
    <div class="k"><kbd>&#8984; F</kbd></div>       <div>find on page</div>
    <div class="k"><kbd>&#8984; D</kbd></div>       <div>bookmark this page</div>
    <div class="k"><kbd>&#8679;&#8984; J</kbd></div><div>downloads</div>
    <div class="k"><kbd>&#8984; drag</kbd></div>    <div>move the window</div>
    <div class="k"><kbd>&#8963;&#8984; F</kbd></div><div>fullscreen</div>
    <div class="k"><kbd>&#8679;&#8984; S</kbd></div><div>snapshot the page &rarr; desktop</div>
    <div class="k"><kbd>&#8984; P</kbd></div>       <div>pin on top of every window</div>
    <div class="k"><kbd>&#8984; [</kbd> <kbd>&#8984; ]</kbd></div><div>back / forward</div>
    <div class="k"><kbd>esc</kbd></div>             <div>bail out &mdash; back to this page</div>
    <div class="k"><kbd>&#8984; =</kbd> <kbd>&#8984; &minus;</kbd> <kbd>&#8984; 0</kbd></div><div>zoom</div>
    <div class="k"><kbd>&#8679;&#8984; C</kbd></div><div>copy current url</div>
  </div>
  <footer>&#8984;N new window &nbsp;&middot;&nbsp; &#8984;R reload &nbsp;&middot;&nbsp; &#8679;&#8984;W close window</footer>
</main></body></html>
"""
