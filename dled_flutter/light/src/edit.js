// EDIT (screens/edit_screen.dart, widgets/edit_controls.dart): the cues of
// one playback, the fixtures, and the programmer (LED faders, colour square /
// wheel, pan / tilt pad, FX). The state lives in dled (state().edit); the
// LPU's programmer follows every change live, like the reference app.
'use strict';

const edit = (() => {
  const page = document.getElementById('pgEdit');
  const FADERS = ['R', 'G', 'B', 'A', 'W', 'In', 'Sh', 'Col', 'Go', 'Rota', 'Prism', 'Iris', 'Focus', 'Zoom', 'Frost', 'Custom', 'Custom2'];
  const COLOURS = { R: '#e02020', G: '#20c020', B: '#3050e0' };
  const WAVES = {
    intensity: ['None', 'Sinus', 'Ramp', 'Inversed Ramp', 'Square', 'Random'],
    position: ['None', 'Circle', 'Eight', 'Square', 'Pan', 'Tilt', 'Random'],
    colour: ['None', 'Rainbow', 'Random', 'Full Sinus', 'Full Twinkle'],
  };
  const FX_TITLE = { intensity: 'INTENSITY FX', position: 'POSITION FX', colour: 'COLOURMIX FX' };
  const GEN = ['intensity', 'position', 'colour'];
  let fine = false, colourMode = 0; // 0 faders, 1 colour square, 2 colour wheel
  const E = () => app.st.edit;

  const btn = (label, fn, cls = 'pbtn') => {
    const b = ui.el('button', cls);
    b.textContent = label;
    b.addEventListener('click', fn);
    return b;
  };

  // --- cues row: the cues (scroll sideways) and ADD / REMOVE ------------------
  const cuesRow = ui.el('div', 'ecues');
  const cueSec = ui.el('div', 'ecuesec');
  const cueList = ui.el('div', 'ecuelist');
  cueList.addEventListener('wheel', (e) => { cueList.scrollLeft += e.deltaY + e.deltaX; e.preventDefault(); }, { passive: false });
  cueSec.append(ui.el('div', 'ohead', 'CUES'), cueList);
  const gAdd = ui.el('div', 'grpv');
  const bAdd = btn('ADD', () => { dled.editAdd(); scrollToEnd = true; }), bRemove = btn('REMOVE', () => dled.editRemove());
  gAdd.append(bAdd, bRemove);
  const addCol = ui.el('div', 'eside top');
  addCol.appendChild(gAdd);
  cuesRow.append(cueSec, addCol);
  let scrollToEnd = false, cueKey = '';

  // --- fixtures and the side buttons -------------------------------------------
  const mid = ui.el('div', 'emid');
  const fixSec = ui.el('div', 'efix');
  const grid = ui.fixtureGrid({ flags: false, onSelect: (next) => dled.editSelect([...next]) });
  const gridPanel = ui.el('div', 'epanel');
  gridPanel.appendChild(grid.el);
  fixSec.append(ui.el('div', 'ohead', 'FIXTURES'), gridPanel);
  const side = ui.el('div', 'eside');
  const g1 = ui.el('div', 'grpv'), g2 = ui.el('div', 'grpv');
  const bRename = btn('RENAME', () => renameCue()), bCond = btn('CONDITION', () => dled.editCondition()),
    bDelay = btn('DELAY', () => timeDialog('ENTER DELAY', 'delay', dled.editDelay)),
    bFade = btn('FADE', () => timeDialog('ENTER FADE', 'fade', dled.editFade));
  const bLoad = btn('LOAD', () => dled.editLoad()), bRecord = btn('RECORD', () => dled.editRecord()),
    bClear = btn('CLEAR', () => dled.editClear()), bClearAll = btn('CLEAR ALL', () => dled.editClearAll());
  g1.append(bRename, bCond, bDelay, bFade);
  g2.append(bLoad, bRecord, bClear, bClearAll);
  side.append(g1, ui.el('div', 'fill'), g2);
  mid.append(fixSec, side);

  // --- bottom panel: buttons over what they belong to, the pad, the faders ----
  const bottom = ui.el('div', 'ebottom');
  const panel = ui.el('div', 'epanel bot');
  const top = ui.el('div', 'erow top');
  const padBtns = ui.el('div', 'epadbtns');
  const bHome = btn('⌂', () => dled.editPosition(128, 128), 'ebtn home');
  const bFine = btn('Fine', () => { fine = !fine; draw(); }, 'ebtn');
  const bFxPos = btn('FX', () => fxDialog('position'), 'ebtn');
  // POS: the stored positions (always: managing them needs no selection)
  const bPos = btn('POS', () => positions.open(), 'ebtn');
  bHome.style.flex = '20'; bFine.style.flex = '25'; bFxPos.style.flex = '25'; bPos.style.flex = '30';
  padBtns.append(bHome, bFine, bFxPos, bPos);
  const bMode = btn('↻', () => { colourMode = (colourMode + 1) % 3; draw(); }, 'ebtn');
  const bFxCol = btn('FX', () => fxDialog('colour'), 'ebtn');
  const bFxInt = btn('FX', () => fxDialog('intensity'), 'ebtn');
  bMode.style.gridColumn = 'span 1'; bFxCol.style.gridColumn = 'span 4'; bFxInt.style.gridColumn = 'span 2';
  top.append(padBtns, bMode, bFxCol, bFxInt);
  const row = ui.el('div', 'erow faders');
  const pad = ui.el('canvas', 'epad');
  row.appendChild(pad);
  const colourBox = ui.el('div', 'ecolour');
  const colourCv = ui.el('canvas');
  colourBox.appendChild(colourCv);
  row.appendChild(colourBox);
  const faders = {};
  for (const k of FADERS) {
    const f = ui.el('div', 'efader');
    const cv = ui.el('canvas'), val = ui.el('div', 'eval');
    f.append(ui.el('div', 'elab', k), cv, val);
    row.appendChild(f);
    faders[k] = { f, cv, val };
    drag(f, (x, y, r) => {
      if (f.classList.contains('off')) return;
      const span = r.height - 18 - 24 - 8;
      dled.editSlider(k, Math.min(Math.max(1 - (y - 18 - 4) / span, 0), 1) * 255);
    });
  }
  panel.append(top, row);
  bottom.appendChild(panel);
  page.append(cuesRow, mid, bottom);

  /// pointer down / move inside [el]: fn(x, y, rect, dx, dy, first) in design pixels
  function drag(el, fn) {
    let last = null;
    const at = (e) => {
      const r = el.getBoundingClientRect(), s = app.scale();
      return [(e.clientX - r.left) / s, (e.clientY - r.top) / s, { width: r.width / s, height: r.height / s }];
    };
    el.addEventListener('pointerdown', (e) => {
      el.setPointerCapture(e.pointerId);
      const [x, y, r] = at(e);
      last = [x, y];
      fn(x, y, r, 0, 0, true);
    });
    el.addEventListener('pointermove', (e) => {
      if (!last) return;
      const [x, y, r] = at(e);
      fn(x, y, r, x - last[0], y - last[1], false);
      last = [x, y];
    });
    const end = () => { last = null; };
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
  }

  // pan / tilt: absolute, or in fine mode moved slowly by the drag
  drag(pad, (x, y, r, dx, dy, first) => {
    const e = E();
    if (!e || pad.classList.contains('off')) return;
    if (fine) {
      if (!first) dled.editPosition(clamp255(e.pan + dx * 0.1), clamp255(e.tilt - dy * 0.1));
      return;
    }
    dled.editPosition(clamp255(x / r.width * 255), clamp255((1 - y / r.height) * 255));
  });
  const clamp255 = (v) => Math.min(Math.max(v, 0), 255);

  // colour square / wheel
  drag(colourCv, (x, y, r) => {
    const s = Math.min(r.width, r.height);
    const ox = (r.width - s) / 2, oy = (r.height - s) / 2;
    const [cr, cg, cb] = colourMode === 1 ? squareAt((x - ox) / s, (y - oy) / s) : wheelAt(x - ox - s / 2, y - oy - s / 2, s / 2);
    dled.editRgb(cr, cg, cb);
  });

  function hsv(h, s, v) { // h 0-360, s / v 0..1 -> [r, g, b] 0-255
    const f = (n) => { const k = (n + h / 60) % 6; return v - v * s * Math.max(0, Math.min(k, 4 - k, 1)); };
    return [f(5) * 255, f(3) * 255, f(1) * 255];
  }
  function toHsv(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let h = 0;
    if (d) h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return [(h * 60 + 360) % 360, max ? d / max : 0, max];
  }
  // hue left to right; white at the top, the pure colour in the middle, black below
  function squareAt(x, y) {
    x = Math.min(Math.max(x, 0), 0.999); y = Math.min(Math.max(y, 0), 1);
    const [r, g, b] = hsv(x * 360, 1, 1);
    const mix = (a, c, t) => a + (c - a) * t;
    return y <= 0.5 ? [mix(255, r, y * 2), mix(255, g, y * 2), mix(255, b, y * 2)]
      : [mix(r, 0, (y - 0.5) * 2), mix(g, 0, (y - 0.5) * 2), mix(b, 0, (y - 0.5) * 2)];
  }
  // red on the left, white in the middle, the pure colour at the rim
  function wheelAt(dx, dy, radius) {
    const sat = Math.min(Math.hypot(dx, dy) / radius, 1);
    const hue = ((Math.atan2(dy, dx) * 180 / Math.PI - 180) % 360 + 360) % 360;
    return hsv(hue, sat, 1);
  }

  // --- dialogs --------------------------------------------------------------------
  function renameCue() {
    const e = E(), q = e.sel[0], c = e.cues[q];
    ui.nameDialog('RENAME CUE', c.n, (name) => dled.editRename(name), { clearTo: String(q + 1) });
  }
  function timeDialog(title, key, apply) {
    const e = E(), c = e.cues[e.sel[0]];
    ui.nameDialog(title, c ? c[key] : '0s', (text) => apply(text), { clearTo: '0s' });
  }

  // FX: the waveforms, Size / Speed / Phase window faders, X / Ok / Cancel.
  // The LPU follows the dialog live; Cancel puts the old generator back.
  function fxDialog(gen) {
    const kept = E().fx[GEN.indexOf(gen)];
    let w = kept.w, size = kept.size, speed = kept.speed, phase = kept.phase;
    const live = (keep = false) => dled.editFx(gen, w, size, speed, phase, keep);
    const body = ui.el('div', 'fx-dlg');
    const top = ui.el('div', 'fx-top');
    const list = ui.el('div', 'fx-list');
    const rows = WAVES[gen].map((name) => {
      const r = ui.el('div', 'lib-row', name);
      r.addEventListener('click', () => { w = name; live(); show(); });
      list.appendChild(r);
      return r;
    });
    top.appendChild(list);
    const fxFaders = [['Size', 0, () => size, (v) => { size = v; }], ['Speed', -100, () => speed, (v) => { speed = v; }],
      ['Phase', 0, () => phase, (v) => { phase = v; }]].map(([label, min, get, set]) => {
      const f = ui.el('div', 'wfader');
      const cv = ui.el('canvas'), val = ui.el('div', 'wval');
      f.append(ui.el('div', 'wlab', label), cv, val);
      top.appendChild(f);
      drag(f, (x, y, r) => {
        const t = Math.min(Math.max(1 - (y - 20 - 4) / (r.height - 20 - 26 - 8), 0), 1);
        set(Math.round(min + t * (100 - min)));
        live();
        show();
      });
      return { cv, val, min, get };
    });
    const btns = ui.el('div', 'fx-btns');
    btns.append(ui.button('X', () => { w = 'None'; size = speed = phase = 0; live(); show(); }, { width: 76 }), ui.el('div', 'fill'),
      ui.button('Ok', () => { close(); live(true); }),
      ui.button('Cancel', () => { close(); dled.editFx(gen, kept.w, kept.size, kept.speed, kept.phase, true); }));
    body.append(top, btns);
    function show() {
      rows.forEach((r) => r.classList.toggle('sel', r.textContent === w));
      for (const f of fxFaders) {
        const v = f.get();
        f.val.textContent = String(Math.round(v));
        windowFader(f.cv, (v - f.min) / (100 - f.min), v !== 0, f.min < 0);
      }
    }
    const close = ui.panel(FX_TITLE[gen], body, { padding: 0 });
    show();
  }

  // --- drawing --------------------------------------------------------------------
  function canvas(cv) {
    const r = cv.getBoundingClientRect(), d = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
    if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
    const s = app.scale(), c = cv.getContext('2d');
    c.setTransform(d * s, 0, 0, d * s, 0, 0);
    c.clearRect(0, 0, w, h);
    return [c, r.width / s, r.height / s];
  }

  // LED segments lit up to the value
  function ledFader(cv, fraction, colour) {
    const [c, w, h] = canvas(cv);
    const seg = 3, gap = 2, n = Math.floor((h + gap) / (seg + gap)), lit = Math.round(fraction * n);
    for (let i = 0; i < n; i++) {
      c.fillStyle = colour;
      c.globalAlpha = i < lit ? 1 : 1;
      c.fillStyle = i < lit ? colour : dim(colour);
      c.fillRect(0, h - (i + 1) * seg - i * gap, w, seg);
    }
  }
  const dim = (hex) => { const n = parseInt(hex.slice(1), 16); const f = (x) => Math.round(x * 0.45); return `rgb(${f(n >> 16)},${f((n >> 8) & 255)},${f(n & 255)})`; };

  // the FX dialog's faders: a window around the value, white segments up to it
  function windowFader(cv, fraction, filled, fromMiddle) {
    const [c, w, h] = canvas(cv);
    const seg = 4, gap = 2, inset = 6, n = Math.floor((h + gap) / (seg + gap));
    const wh = 5 * (seg + gap) + 4, cy = wh / 2 + (1 - Math.min(Math.max(fraction, 0), 1)) * (h - wh);
    for (let i = 0; i < n; i++) {
      const y = h - (i + 1) * seg - i * gap, m = y + seg / 2;
      const lit = filled && (!fromMiddle ? m > cy - wh / 2
        : cy < h / 2 ? m > cy - wh / 2 && m < h / 2 : m < cy + wh / 2 && m > h / 2);
      c.fillStyle = lit ? '#e8e8e8' : '#5a5a5a';
      c.fillRect(inset, y, w - 2 * inset, seg);
    }
    c.strokeStyle = '#fff'; c.lineWidth = 1.5;
    roundRect(c, 0.75, cy - wh / 2, w - 1.5, wh, 6); c.stroke();
  }
  function roundRect(c, x, y, w, h, r) {
    c.beginPath();
    c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r);
    c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath();
  }

  // pan / tilt: a 4 x 4 grid, a "+" and the values (-100..100) on the edges
  function drawPad(e, on) {
    const [c, w, h] = canvas(pad);
    if (!on) return;
    c.strokeStyle = '#5a5e66'; c.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      c.beginPath(); c.moveTo(w * i / 4, 0); c.lineTo(w * i / 4, h); c.moveTo(0, h * i / 4); c.lineTo(w, h * i / 4); c.stroke();
    }
    const x = e.pan / 255 * w, y = (1 - e.tilt / 255) * h;
    c.strokeStyle = '#e0e0e0'; c.lineWidth = 3;
    c.beginPath(); c.moveTo(x - 7, y); c.lineTo(x + 7, y); c.moveTo(x, y - 7); c.lineTo(x, y + 7); c.stroke();
    const bw = 40, bh = 34;
    const box = (bx, by, text) => {
      roundRect(c, bx, by, bw, bh, 6);
      c.fillStyle = '#151d26'; c.fill(); c.strokeStyle = '#8a8e96'; c.lineWidth = 1; c.stroke();
      c.fillStyle = '#e0e0e0'; c.font = '11px "DejaVu Sans", Verdana, sans-serif'; c.textAlign = 'center'; c.textBaseline = 'middle';
      c.fillText(text, bx + bw / 2, by + bh / 2);
    };
    box(Math.min(Math.max(x - bw / 2, 2), w - bw - 2), h - bh - 2, String(Math.round(e.pan / 255 * 200 - 100)));
    box(w - bw - 2, Math.min(Math.max(y - bh / 2, 2), h - bh - 2), String(Math.round(e.tilt / 255 * 200 - 100)));
  }

  function marker(c, x, y) {
    c.strokeStyle = '#fff'; c.lineWidth = 3;
    roundRect(c, x - 17, y - 17, 34, 34, 6); c.stroke();
  }
  function drawColour(e) {
    const [c, w, h] = canvas(colourCv);
    const s = Math.min(w, h), ox = (w - s) / 2, oy = (h - s) / 2;
    const [hue, sat, val] = toHsv(e.attrs.R || 0, e.attrs.G || 0, e.attrs.B || 0);
    if (colourMode === 1) {
      const g = c.createLinearGradient(ox, 0, ox + s, 0);
      for (let a = 0; a <= 360; a += 30) g.addColorStop(a / 360, `hsl(${a},100%,50%)`);
      c.fillStyle = g; c.fillRect(ox, oy, s, s);
      const v = c.createLinearGradient(0, oy, 0, oy + s);
      v.addColorStop(0, '#fff'); v.addColorStop(0.5, 'rgba(255,255,255,0)'); v.addColorStop(0.5, 'rgba(0,0,0,0)'); v.addColorStop(1, '#000');
      c.fillStyle = v; c.fillRect(ox, oy, s, s);
      const y = val < 0.999 ? 0.5 + (1 - val) / 2 : sat / 2;
      marker(c, ox + hue / 360 * s, oy + y * s);
    } else {
      const cx = ox + s / 2, cy = oy + s / 2, r = s / 2;
      const g = c.createConicGradient ? c.createConicGradient(0, cx, cy) : null;
      if (g) {
        for (let a = 0; a <= 360; a += 30) g.addColorStop(a / 360, `hsl(${(a - 180 + 360) % 360},100%,50%)`);
        c.fillStyle = g; c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.fill();
      }
      const rg = c.createRadialGradient(cx, cy, 0, cx, cy, r);
      rg.addColorStop(0, '#fff'); rg.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = rg; c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.fill();
      const a = (hue + 180) % 360 * Math.PI / 180;
      marker(c, cx + Math.cos(a) * r * sat, cy + Math.sin(a) * r * sat);
    }
  }

  const two = (n) => String(n);
  function drawCues(e) {
    const key = JSON.stringify([e.cues, e.sel]);
    if (key === cueKey) return;
    cueKey = key;
    const left = cueList.scrollLeft;
    cueList.innerHTML = '';
    e.cues.forEach((c, q) => {
      const t = ui.el('div', 'ecue');
      t.classList.toggle('sel', e.sel.includes(q));
      t.classList.toggle('rec', c.rec);
      for (const line of [c.n, c.delay, c.follow ? 'Follow' : 'Halt', c.fade]) t.appendChild(ui.el('div', '', line));
      t.addEventListener('click', () => dled.editCue(q));
      cueList.appendChild(t);
    });
    cueList.scrollLeft = left;
    if (scrollToEnd) { scrollToEnd = false; cueList.scrollLeft = cueList.scrollWidth; }
  }

  function draw() {
    if (page.hidden) return;
    const e = E();
    if (!e) return;
    const on = !!app.st.connected;
    bottom.style.height = `${250 + Math.min(Math.max((app.height() - 1024) * 0.3, 0), 300)}px`;
    drawCues(e);
    grid.draw(app.st.fixtures, new Set(e.fixtures), { recorded: e.recorded });
    const one = e.sel.length === 1, any = e.sel.length > 0;
    bAdd.disabled = bRemove.disabled = !on;
    bRename.disabled = bLoad.disabled = bRecord.disabled = !one || !on;
    bCond.disabled = bDelay.disabled = bFade.disabled = !any || !on;
    bClear.disabled = bClearAll.disabled = !on;
    const en = new Set(e.enabled);
    const position = en.has('Pan') || en.has('Tilt'), rgb = en.has('R') || en.has('G') || en.has('B');
    bHome.disabled = bFine.disabled = bFxPos.disabled = !position;
    bFine.classList.toggle('lit', fine && position);
    bFxCol.disabled = !rgb;
    bFxInt.disabled = !en.has('In');
    [[bFxInt, 0], [bFxPos, 1], [bFxCol, 2]].forEach(([b, g]) => {
      b.classList.toggle('lit', !b.disabled && e.fx[g].w !== 'None');
      b.classList.toggle('red', !!e.loadedFx[g]);
    });
    pad.classList.toggle('off', !position);
    drawPad(e, position);
    colourBox.hidden = colourMode === 0;
    for (const k of FADERS) {
      const f = faders[k], enabled = en.has(k), hide = colourMode !== 0 && ['R', 'G', 'B', 'A', 'W'].includes(k);
      f.f.hidden = hide;
      if (hide) continue;
      f.f.classList.toggle('off', !enabled);
      const v = enabled ? e.attrs[k] || 0 : 0;
      f.val.textContent = enabled ? two(Math.round(v)) : '';
      if (enabled) ledFader(f.cv, v / 255, COLOURS[k] || '#9a9a9a'); else canvas(f.cv);
    }
    if (colourMode !== 0) drawColour(e);
  }

  function open(pb) {
    dled.editOpen(pb);
    cueKey = '';
    app.show('edit');
  }

  return { draw, open };
})();
