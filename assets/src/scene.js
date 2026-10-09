// Building blocks shared by banner.html, social.html and demo.html.
// Everything is plain DOM so headless Chrome renders it with no network or deps.

const HUD =
  "Space capture  ·  T timer  ·  C camera  ·  M mirror  ·  Esc cancel    [FaceTime HD Camera]";

const NOTES = `
  <div class="h">[2, 3, 1, 4] &nbsp; k = 4</div>
  <table>
    <tr><th>i</th><th>total</th><th>need</th><th>seen?</th><th>found</th></tr>
    <tr><td>0</td><td>2</td><td>−2</td><td>no</td><td>–</td></tr>
    <tr><td>1</td><td>5</td><td>1</td><td>no</td><td>–</td></tr>
    <tr><td>2</td><td>6</td><td>2</td><td class="ok">yes</td><td class="hit">[3, 1]</td></tr>
    <tr><td>3</td><td>10</td><td>6</td><td class="ok">yes</td><td class="hit">[4]</td></tr>
  </table>`;

function el(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

function terminal({ x, y, w, h, title = "herdr · study" }) {
  const node = el(`
    <div class="win" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">
      <div class="bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
        <span class="title">${title}</span></div>
      <div class="term">
        <div class="side">
          <div class="ws">study</div>
          <div class="agent">✻ claude</div>
          <div class="muted">&nbsp;&nbsp;dsa · prefix sums</div>
          <div style="height:10px"></div>
          <div class="ws">core</div>
          <div class="muted">✻ claude · idle</div>
        </div>
        <div class="pane">
          <div class="transcript"></div>
          <div class="prompt"><span class="caret">❯ </span><span class="input"></span><span class="cursor"></span></div>
          <div class="status">⏵⏵ accept edits on</div>
        </div>
      </div>
    </div>`);
  return node;
}

function camera({ x, y, w }) {
  const vh = Math.round((w * 9) / 16);
  return el(`
    <div class="win cam" style="left:${x}px;top:${y}px;width:${w}px;height:${vh + 28}px">
      <div class="bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
        <span class="title">herdr-cam</span></div>
      <div class="view" style="height:${vh}px">
        <div class="page">${NOTES}</div>
        <div class="hud">${HUD}</div>
        <div class="flash"></div>
      </div>
    </div>`);
}

function keys(labels, { x, y }) {
  const parts = labels
    .map((k) => (k === "then" ? `<span class="then">then</span>` : `<span class="key">${k}</span>`))
    .join("");
  return el(`<div class="keys" style="left:${x}px;top:${y}px">${parts}</div>`);
}

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const ease = (v) => 1 - Math.pow(1 - clamp(v), 3);
