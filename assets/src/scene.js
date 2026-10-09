// Building blocks shared by banner.html, social.html and demo.html.
// Everything is plain DOM so headless Chrome renders it with no network or deps.

// The real app's HUD strings (app/Core.swift hudText), so the illustration matches.
const CAMERA_NAME = "FaceTime HD Camera";
function hud(shots) {
  const status = `[${CAMERA_NAME}]`;
  if (!shots) return `Space capture  ·  Enter send  ·  T timer  ·  C camera  ·  M mirror  ·  Esc cancel    ${status}`;
  const photos = shots === 1 ? "1 photo" : `${shots} photos`;
  return `Space add  ·  Enter send ${photos}  ·  ⌫ undo  ·  T timer  ·  Esc discard    ${status}`;
}
const HUD = hud(0);

// ---- hand-drawn sketch -----------------------------------------------------------
// Two sheets of paper, drawn the way a pen does it: every line is a slightly bowed
// double stroke with overshoot, letters sit off-baseline at small random angles, and
// an ink filter roughens the edges. Seeded, so every frame draws the same marks.
//   "login"  a wireframe of a login card, with a red-pen note
//   "bucket" a hand dry run of a token-bucket rate limiter, with one slip at t=3

function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function sketch(kind = "login", seed = 7) {
  const r = rng(seed);
  const j = (a) => (r() - 0.5) * 2 * a;
  const out = [];
  const ink = "#1f2a44";

  // one pen pass: bowed quadratic with a little overshoot at both ends
  function pass(x1, y1, x2, y2, bow, w, op) {
    const dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1;
    const over = 1.5 + r() * 2.5;
    const ux = dx / len, uy = dy / len;
    const sx = x1 - ux * over * r() + j(0.8), sy = y1 - uy * over * r() + j(0.8);
    const ex = x2 + ux * over * r() + j(0.8), ey = y2 + uy * over * r() + j(0.8);
    const mx = (sx + ex) / 2 - uy * j(bow), my = (sy + ey) / 2 + ux * j(bow);
    out.push(`<path d="M${sx.toFixed(1)} ${sy.toFixed(1)} Q${mx.toFixed(1)} ${my.toFixed(1)} ${ex.toFixed(1)} ${ey.toFixed(1)}" stroke="${ink}" stroke-width="${w}" stroke-opacity="${op}" fill="none" stroke-linecap="round"/>`);
  }
  function line(x1, y1, x2, y2, w = 1.6) {
    const bow = Math.min(3, Math.hypot(x2 - x1, y2 - y1) / 40);
    pass(x1, y1, x2, y2, bow, w, 0.92);
    if (r() < 0.7) pass(x1 + j(0.6), y1 + j(0.6), x2 + j(0.6), y2 + j(0.6), bow, w * 0.6, 0.55);
  }
  function rect(x, y, w, h, sw) {
    line(x, y, x + w, y, sw); line(x + w, y, x + w, y + h, sw);
    line(x + w, y + h, x, y + h, sw); line(x, y + h, x, y, sw);
  }
  function circle(cx, cy, rad) {
    let d = "";
    const start = r() * Math.PI * 2, steps = 26;
    for (let i = 0; i <= steps + 3; i++) {
      const a = start + (i / steps) * Math.PI * 2;
      const rr = rad * (1 + j(0.06)) + i * 0.05;
      d += `${i ? "L" : "M"}${(cx + Math.cos(a) * rr).toFixed(1)} ${(cy + Math.sin(a) * rr * 0.92).toFixed(1)} `;
    }
    out.push(`<path d="${d}" stroke="${ink}" stroke-width="1.5" fill="none" stroke-linejoin="round" stroke-opacity=".9"/>`);
  }
  function hatch(x, y, w, h) {
    for (let k = -h; k < w; k += 5 + r() * 2) {
      const x1 = Math.max(x, x + k), y1 = x + k < x ? y - k : y;
      const x2 = Math.min(x + w, x + k + h), y2 = x + k + h > x + w ? y + (x + w - (x + k)) : y + h;
      pass(x1 + j(1), y1 + j(1), x2 + j(1), y2 + j(1), 1, 0.9, 0.3);
    }
  }
  // Each letter gets its real width from the font, then a little random spacing,
  // size, baseline and angle, which is what keeps it reading as handwriting.
  const measure = document.createElement("canvas").getContext("2d");
  function text(str, x, y, size, color = ink, op = 0.95) {
    let dx = 0, spans = "";
    for (const ch of str) {
      const rot = j(5), dy = j(1.1), s = size * (1 + j(0.06));
      measure.font = `700 ${s}px "Bradley Hand"`;
      const adv = measure.measureText(ch === " " ? "\u00a0" : ch).width;
      spans += `<tspan x="${(x + dx).toFixed(1)}" y="${(y + dy).toFixed(1)}" rotate="${rot.toFixed(1)}" font-size="${s.toFixed(1)}">${ch === " " ? "&#160;" : ch}</tspan>`;
      dx += adv * (1.02 + j(0.05));
    }
    out.push(`<text font-family="Bradley Hand, Noteworthy, cursive" font-weight="700" fill="${color}" fill-opacity="${op}">${spans}</text>`);
  }

  if (kind === "bucket") {
    text("rate limiter dry run", 22, 30, 17);
    text("cap 4  ·  +1 token / sec", 196, 30, 11, "#3a4766", 0.85);
    const cols = [26, 70, 130, 186, 252], heads = ["t", "tokens", "req", "allowed", "left"];
    heads.forEach((h, i) => text(h, cols[i], 62, 13, "#3a4766", 0.9));
    line(20, 70, 318, 72, 1.5);
    line(56, 46, 57, 220, 1);
    const rows = [
      ["0", "4", "3", "3", "1"],
      ["1", "2", "2", "2", "0"],
      ["2", "1", "3", "1", "0"],
      ["3", "2", "2", "2", "0"],
    ];
    rows.forEach((row, k) => {
      const y = 98 + k * 34;
      row.forEach((v, i) => text(v, cols[i] + 6, y, 16));
      if (k === 2) text("✗ 2", cols[3] + 30, y, 13, "#b3261e", 0.9);
    });
    circle(80, 199, 13);
    text("refill ok?", 102, 244, 12, "#3a4766", 0.8);
    line(100, 236, 86, 214, 1);
  } else {
  // card outline
    rect(70, 14, 200, 214, 1.8);
    // logo scribble + heading
    circle(170, 40, 13);
    line(163, 44, 170, 34, 1.2); line(170, 34, 177, 44, 1.2);
    text("Welcome back", 112, 76, 17);
    // email + password fields
    text("email", 92, 98, 11, "#3a4766", 0.8);
    rect(90, 102, 160, 22, 1.4);
    text("password", 92, 140, 11, "#3a4766", 0.8);
    rect(90, 144, 160, 22, 1.4);
    text("• • • • • •", 98, 160, 12);
    // remember me
    rect(91, 175, 11, 11, 1.3);
    line(93, 181, 96, 185, 1.6); line(96, 185, 104, 172, 1.6);
    text("remember me", 108, 185, 12);
    // button
    rect(90, 194, 160, 22, 1.8);
    hatch(91, 195, 158, 20);
    text("Sign in", 146, 210, 14);
    // annotation in red pen
    const red = "#b3261e";
    out.push(`<path d="M252 205 q20 -2 30 -16" stroke="${red}" stroke-width="1.4" fill="none" stroke-linecap="round"/>`);
    out.push(`<path d="M252 205 l6 -5 M252 205 l7 3" stroke="${red}" stroke-width="1.4" fill="none" stroke-linecap="round"/>`);
    text("8px corners", 274, 182, 11, red, 0.9);
    text("forgot password?", 112, 244, 11, "#3a4766", 0.85);
    line(112, 247, 218, 248, 0.9);

  }

  return `<svg viewBox="0 0 340 260" width="100%" height="100%" style="overflow:visible">
    <defs><filter id="ink" x="-5%" y="-5%" width="110%" height="110%">
      <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="${seed}" result="n"/>
      <feDisplacementMap in="SourceGraphic" in2="n" scale="1.3"/>
    </filter></defs>
    <g filter="url(#ink)">${out.join("")}</g></svg>`;
}

const PAGES = { login: sketch("login", 7), bucket: sketch("bucket", 11) };

function el(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

function terminal({ x, y, w, h, title = "herdr · app" }) {
  const node = el(`
    <div class="win" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">
      <div class="bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
        <span class="title">${title}</span></div>
      <div class="term">
        <div class="side">
          <div class="ws">app</div>
          <div class="agent">✻ claude</div>
          <div class="muted">&nbsp;&nbsp;login + limits</div>
          <div style="height:10px"></div>
          <div class="ws">api</div>
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
        <div class="page page1"><div class="sketch">${PAGES.login}</div></div>
        <div class="page page2" style="opacity:0"><div class="sketch">${PAGES.bucket}</div></div>
        <div class="tray">
          <div class="thumb" style="opacity:0"><div class="sketch">${PAGES.login}</div></div>
          <div class="thumb" style="opacity:0"><div class="sketch">${PAGES.bucket}</div></div>
        </div>
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
