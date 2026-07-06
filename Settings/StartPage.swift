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
  p.tag { color: #85858f; margin: 0 0 40px; font-size: 16px; }
  .quick { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
           justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 44px; color: #55555e; font-size: 12px; }
  footer a { color: #7d7d88; text-decoration: none; }
  footer a:hover { color: #b9b9c4; }
</style></head>
<body><main>
  <h1>chromeless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="quick">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; T</kbd> <kbd>&#8984; W</kbd></div><div>new tab / close tab</div>
    <div class="k"><kbd>&#8984; Y</kbd></div>       <div>history</div>
    <div class="k"><kbd>&#8984; ,</kbd></div>       <div>settings</div>
  </div>
  <footer>See and customize every shortcut in
    <a href="chromeless://settings#shortcuts">Settings &rarr; Shortcuts</a></footer>
</main></body></html>
"""
