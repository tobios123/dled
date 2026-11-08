// PLAYBACK - the main window (screens/playback_screen.dart): 64 tiles, the
// mode buttons (RELEASE / RENAME / SWAP / PROPS), 8 fader strips with knob,
// fader and FLASH following one row of tiles. PC mode (a wide window,
// app.pc()): the grid in two halves side by side (1-32 | 33-64) and 16
// strips, each half's fader row under it: row r with row r + 4 (1-8 with
// 33-40, ... 25-32 with 57-64).
'use strict';

const playback = (() => {
  // tile colours (normal, in the fader row)
  const RED = ['#711217', '#470c32'], GREEN = ['#09722b', '#06483e'], YELLOW = ['#95660a', '#5d402a'],
    ORANGE = ['#b9480c', '#742d2b'], EMPTY = ['#1e2e3e', '#15213a'];
  const SHOW_CHANGE = 1500; // ms "Intensity xx %" / "Speed xx %" stays on a tile

  const grid = document.getElementById('grid');
  const faders = document.getElementById('faders');
  let row = 0; // the row of 8 playbacks on the faders (PC mode: 0-3, and row + 4)
  let armed = null; // 'edit' / 'release' / 'rename' / 'swap' / 'props'
  let swapFirst = -1;
  const flashing = new Map(); // pb -> pointer id holding FLASH
  const changed = new Map(); // pb -> {what, at}
  const last = []; // pb -> {v, sp} last drawn, to notice changes

  const pbOf = (i) => app.st.pb[i] || { l: '', n: 0, s: 'released', v: 1, sp: 0 };
  const hasContent = (p) => p.l !== '' || p.n > 0;

  // --- tiles ---------------------------------------------------------------
  const tiles = [];
  for (let r = 0; r < 8; r++) {
    const rowEl = ui.el('div', 'prow');
    // a tap between the tiles chooses the fader row
    rowEl.addEventListener('click', (e) => { if (e.target === rowEl) setRow(r); });
    for (let c = 0; c < 8; c++) {
      const pb = r * 8 + c;
      const t = ui.el('div', 'tile');
      const cv = ui.el('canvas');
      const label = ui.el('div', 't'), count = ui.el('div', 'c'), over = ui.el('div', 'x');
      t.append(cv, label, count, over);
      t.addEventListener('click', () => { if (!longPressed) tap(pb); longPressed = false; });
      t.addEventListener('pointerdown', () => {
        clearTimeout(holdTile);
        longPressed = false;
        holdTile = setTimeout(() => { longPressed = true; longPress(pb); }, RELEASE_HOLD);
      });
      for (const ev of ['pointerup', 'pointerleave', 'pointercancel']) t.addEventListener(ev, () => clearTimeout(holdTile));
      rowEl.appendChild(t);
      tiles.push({ t, cv, label, count, over });
    }
    grid.appendChild(rowEl);
  }

  // Long press (0.8 s, releaseHold in playback_screen.dart) on a holding
  // playback (yellow: a cue is on, no fade or delay running) releases it;
  // not while a mode is armed. Like the app, a press that long is never a
  // tap (no GO).
  const RELEASE_HOLD = 800;
  let holdTile = null, longPressed = false;
  function longPress(pb) {
    const p = pbOf(pb);
    if (!armed && !app.st.locked && p.s === 'playing' && !p.f) dled.release(pb);
  }

  function tap(pb) {
    const p = pbOf(pb);
    switch (armed) {
      case 'edit':
        arm(null);
        edit.open(pb);
        break;
      case 'release':
        arm(null);
        dled.release(pb);
        break;
      case 'rename':
        arm(null);
        ui.nameDialog('RENAME PLAYBACK', p.l, (name) => dled.rename(pb, name));
        break;
      case 'props':
        arm(null);
        propsDialog(pb);
        break;
      case 'swap':
        if (swapFirst < 0) swapFirst = pb; // first tap: remember it
        else if (swapFirst === pb) arm(null); // same tile: cancel
        else { dled.swap(swapFirst, pb); arm(null); }
        draw();
        break;
      default:
        if (hasContent(p)) dled.go(pb);
    }
  }

  // PLAYBACK PROPERTIES: Background, Exclusive, Go Mode, Repeat; each change
  // goes to the LPU at once, Close closes.
  function propsDialog(pb) {
    const p = pbOf(pb);
    const GO = ['Go', 'Toggle', 'Flash', 'Solo'], REP = ['Loop', 'Bounce', 'Random', 'Off'];
    const body = ui.el('div', 'props');
    body.append(
      ui.row('Background', ui.checkbox(p.bg, (v) => dled.props(pb, null, null, v, null))),
      ui.row('Exclusive', ui.checkbox(p.ex, (v) => dled.props(pb, null, null, null, v))),
      ui.row('Go Mode', ui.segments(GO, Math.max(GO.indexOf(p.g), 0), (i) => dled.props(pb, GO[i], null, null, null))),
      ui.row('Repeat', ui.segments(REP, Math.max(REP.indexOf(p.r), 0), (i) => dled.props(pb, null, REP[i], null, null))));
    const btns = ui.el('div', 'btn-row');
    btns.appendChild(ui.button('Close', () => close()));
    body.appendChild(btns);
    const close = ui.panel('PLAYBACK PROPERTIES', body);
  }

  function shade(hex, f) {
    const n = parseInt(hex.slice(1), 16);
    const c = (v) => Math.round(v * f);
    return `rgb(${c(n >> 16)},${c((n >> 8) & 255)},${c(n & 255)})`;
  }

  // A canvas is only painted again when what it shows changed: a fast cue
  // loop changes one tile 40 times a second, and repainting all 64 tiles and
  // 8 strips each time kept a phone too busy to answer the LPU.
  function changedKey(cv, ...parts) {
    const key = parts.join('|');
    if (cv._key === key) return false;
    cv._key = key;
    return true;
  }

  // The tile: flat colour darkening at the top / bottom edge, ticks on the
  // left (intensity, lit from the bottom) and right (speed, from the middle).
  function paintTile(cv, fill, level, speed) {
    const w = cv.clientWidth, h = cv.clientHeight, k = app.ratio();
    if (!w || !h || !changedKey(cv, w, h, k, fill, Math.round(level * 8), Math.round(Math.abs(speed) * 4) * Math.sign(speed))) return;
    if (cv.width !== Math.round(w * k) || cv.height !== Math.round(h * k)) {
      cv.width = Math.round(w * k);
      cv.height = Math.round(h * k);
    }
    const g = cv.getContext('2d');
    g.setTransform(k, 0, 0, k, 0, 0);
    const edge = shade(fill, 0.65);
    const grad = g.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, edge); grad.addColorStop(0.1, fill); grad.addColorStop(0.9, fill); grad.addColorStop(1, edge);
    g.fillStyle = grad;
    g.fillRect(0, 0, w, h);
    const ticks = 8, top = h * 0.18, bottom = h * 0.82, step = (bottom - top) / (ticks - 1);
    const on = Math.round(level * ticks);
    g.lineWidth = 1;
    for (let t = 0; t < ticks; t++) {
      const y = Math.round(bottom - t * step) + 0.5;
      g.strokeStyle = t < on ? 'rgba(255,255,255,.75)' : 'rgba(255,255,255,.15)';
      g.beginPath(); g.moveTo(3, y); g.lineTo(7, y); g.stroke();
    }
    const n = Math.round(Math.abs(speed) * ticks / 2), mid = (top + bottom) / 2;
    g.strokeStyle = 'rgba(255,255,255,.75)';
    for (let t = 1; t <= n; t++) {
      const y = Math.round(speed > 0 ? mid - t * step : mid + t * step) + 0.5;
      g.beginPath(); g.moveTo(w - 7, y); g.lineTo(w - 3, y); g.stroke();
    }
  }

  // the rows the strips follow
  const onFaders = (r) => r === row || (app.pc() && r === row + 4);

  function drawTiles(now) {
    [...grid.children].forEach((el, r) => el.classList.toggle('act', onFaders(r)));
    tiles.forEach((tile, pb) => {
      const p = pbOf(pb);
      const prev = last[pb];
      const has = hasContent(p);
      // only a change of a playback that was already there (not the show
      // arriving after connecting)
      if (prev && prev.has && prev.v !== p.v) changed.set(pb, { what: 'Intensity', at: now });
      if (prev && prev.has && prev.sp !== p.sp) changed.set(pb, { what: 'Speed', at: now });
      last[pb] = { v: p.v, sp: p.sp, has };
      const base = !has ? EMPTY : p.s === 'releasing' ? ORANGE : p.s === 'playing' ? (p.f ? GREEN : YELLOW) : RED;
      const actRow = onFaders(Math.floor(pb / 8));
      paintTile(tile.cv, base[actRow ? 1 : 0], p.v, p.sp);
      tile.t.classList.toggle('swap', armed === 'swap' && swapFirst === pb);
      const alpha = has ? (actRow ? 0.72 : 1) : (actRow ? 0.38 : 0.54);
      tile.label.style.color = tile.over.style.color = `rgba(255,255,255,${alpha})`;
      const ch = changed.get(pb);
      const showing = ch && now - ch.at < SHOW_CHANGE;
      tile.over.textContent = !showing ? '' : ch.what === 'Speed'
        ? `Speed\n${Math.round(p.sp * 100)}%` : `Intensity\n${Math.round(p.v * 100)}%`;
      tile.label.textContent = showing ? '' : (p.l !== '' ? p.l : String(pb + 1));
      const active = p.s === 'playing' || p.s === 'releasing';
      tile.count.textContent = showing ? '' : p.n === 0 ? '- / -' : active && p.a != null ? `${p.a + 1} / ${p.n}` : `- / ${p.n}`;
      tile.count.style.color = `rgba(255,255,255,${alpha * 0.85})`;
    });
    // take the overlays off again after SHOW_CHANGE
    if ([...changed.values()].some((c) => now - c.at < SHOW_CHANGE)) app.redrawSoon(250);
  }

  // --- fader strips ----------------------------------------------------------
  const strips = [];
  for (let i = 0; i < 16; i++) {
    const s = ui.el('div', 'strip' + (i >= 8 ? ' b2' : '') + (i === 8 ? ' gap' : '')); // b2: PC mode only
    const led = ui.el('div', 'sled');
    const knob = ui.el('canvas', 'knob');
    const fader = ui.el('canvas', 'fader');
    const flash = ui.el('button', 'flashbtn', 'FLASH');
    s.append(led, knob, fader, flash);
    faders.appendChild(s);
    strips.push({ s, led, knob, fader, flash });
    const pb = () => (i < 8 ? row * 8 + i : (row + 4) * 8 + i - 8);

    // knob: drag up / down, 100 px for the whole range, relative (no jump);
    // the knob's position becomes the speed through its curve (core/knob.dart)
    relativeDrag(knob, () => (dled.speedToKnob(pbOf(pb()).sp) + 1) / 2,
      (v0, dy) => dled.speed(pb(), dled.knobToSpeed(Math.min(Math.max(v0 + dy / 100, 0), 1) * 2 - 1)));
    // fader: relative to where it was grabbed
    relativeDrag(fader, () => pbOf(pb()).v, (v0, dy) => dled.fader(pb(), v0 + dy / faderTravel(fader)));

    flash.addEventListener('pointerdown', (e) => {
      if (flashing.has(pb())) return;
      const p = pbOf(pb());
      if (p.n === 0 || p.s === 'playing') return; // like the app: only a stopped playback with cues
      flash.setPointerCapture(e.pointerId);
      flashing.set(pb(), e.pointerId);
      dled.flash(pb(), true);
      draw();
    });
    const up = (e) => {
      const n = pb();
      if (flashing.get(n) !== e.pointerId) return;
      flashing.delete(n);
      dled.flash(n, false);
      draw();
    };
    flash.addEventListener('pointerup', up);
    flash.addEventListener('pointercancel', up);
  }

  function relativeDrag(el, value, set) {
    let v0 = 0, y0 = 0;
    el.addEventListener('pointerdown', (e) => {
      el.setPointerCapture(e.pointerId);
      v0 = value();
      y0 = e.clientY / app.scale();
    });
    el.addEventListener('pointermove', (e) => {
      if (!el.hasPointerCapture(e.pointerId)) return;
      set(v0, Math.max(-1e3, y0 - e.clientY / app.scale()));
    });
  }

  const capHeight = (w) => Math.min(Math.max(w * 0.30, 14), 34);
  const faderMargin = (w, h) => capHeight(w) / 2 + h * 0.04;
  const faderTravel = (cv) => Math.max(cv.clientHeight - 2 * faderMargin(cv.clientWidth, cv.clientHeight), 1);

  function sizeCanvas(cv, w, h) {
    const k = app.ratio();
    if (cv.width !== Math.round(w * k) || cv.height !== Math.round(h * k)) {
      cv.width = Math.round(w * k);
      cv.height = Math.round(h * k);
    }
    const g = cv.getContext('2d');
    g.setTransform(k, 0, 0, k, 0, 0);
    g.clearRect(0, 0, w, h);
    return g;
  }

  // the knob with its ring of 21 LED dots; the dot at the position is lit
  function paintKnob(cv, value, size) {
    if (!changedKey(cv, size, app.ratio(), Math.round(value * 20), value.toFixed(3))) return;
    cv.style.width = cv.style.height = size + 'px';
    const g = sizeCanvas(cv, size, size);
    const c = size / 2, ringR = size / 2 - 2, knobR = ringR * 0.72, dots = 21, start = 2.356, sweep = 4.712;
    const lit = Math.round(value * (dots - 1)), dotR = Math.min(Math.max(size * 0.03, 1), 2.2);
    for (let i = 0; i < dots; i++) {
      const a = start + sweep * i / (dots - 1);
      const x = c + Math.cos(a) * ringR, y = c + Math.sin(a) * ringR;
      if (i === lit) {
        g.fillStyle = 'rgba(74,168,255,.45)';
        g.beginPath(); g.arc(x, y, dotR * 2.2, 0, 7); g.fill();
      }
      g.fillStyle = i === lit ? '#8fcbff' : '#4a4a4a';
      g.beginPath(); g.arc(x, y, dotR, 0, 7); g.fill();
    }
    const grad = g.createRadialGradient(c - knobR * 0.3, c - knobR * 0.3, 0, c, c, knobR);
    grad.addColorStop(0, '#5a5a5a'); grad.addColorStop(1, '#1a1a1a');
    g.fillStyle = 'rgba(0,0,0,.5)';
    g.beginPath(); g.arc(c, c + 2, knobR, 0, 7); g.fill();
    g.fillStyle = grad;
    g.beginPath(); g.arc(c, c, knobR, 0, 7); g.fill();
    g.strokeStyle = '#0a0a0a'; g.lineWidth = 1; g.stroke();
    const a = start + sweep * value;
    g.strokeStyle = '#dddddd'; g.lineWidth = 2; g.lineCap = 'round';
    g.beginPath();
    g.moveTo(c + Math.cos(a) * knobR * 0.35, c + Math.sin(a) * knobR * 0.35);
    g.lineTo(c + Math.cos(a) * knobR * 0.85, c + Math.sin(a) * knobR * 0.85);
    g.stroke();
  }

  // the fader: a slot with a scale on both sides and the cap
  function paintFader(cv, value) {
    const w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h || !changedKey(cv, w, h, app.ratio(), value.toFixed(3))) return;
    const g = sizeCanvas(cv, w, h);
    const cx = w / 2, m = faderMargin(w, h), top = m, bottom = h - m;
    const slotW = Math.min(Math.max(w * 0.06, 3), 6), tickGap = slotW + w * 0.07;
    g.strokeStyle = '#6a6a6a'; g.lineWidth = 1;
    for (let i = 0; i <= 10; i++) {
      const y = Math.round(bottom - (bottom - top) * i / 10) + 0.5, len = w * (i % 5 === 0 ? 0.13 : 0.08);
      g.beginPath(); g.moveTo(cx - tickGap - len, y); g.lineTo(cx - tickGap, y);
      g.moveTo(cx + tickGap, y); g.lineTo(cx + tickGap + len, y); g.stroke();
    }
    g.fillStyle = '#000';
    roundRect(g, cx - slotW / 2, top - 4, slotW, bottom - top + 8, slotW / 2); g.fill();
    const capW = Math.min(Math.max(w * 0.56, 22), 60), capH = capHeight(w);
    const y = bottom - (bottom - top) * Math.min(Math.max(value, 0), 1);
    const x0 = cx - capW / 2, y0 = y - capH / 2;
    g.fillStyle = 'rgba(0,0,0,.5)'; roundRect(g, x0, y0 + 2, capW, capH, 3); g.fill();
    const grad = g.createLinearGradient(0, y0, 0, y0 + capH);
    grad.addColorStop(0, '#5a5a5a'); grad.addColorStop(0.45, '#2a2a2a'); grad.addColorStop(0.55, '#1a1a1a'); grad.addColorStop(1, '#3a3a3a');
    g.fillStyle = grad; roundRect(g, x0, y0, capW, capH, 3); g.fill();
    g.strokeStyle = 'rgba(0,0,0,.5)';
    for (const f of [0.22, 0.34, 0.66, 0.78]) {
      const gy = Math.round(y0 + capH * f) + 0.5;
      g.beginPath(); g.moveTo(x0 + 3, gy); g.lineTo(x0 + capW - 3, gy); g.stroke();
    }
    g.strokeStyle = '#e8e8e8'; g.lineWidth = Math.min(Math.max(capH * 0.08, 1.5), 3);
    g.beginPath(); g.moveTo(x0 + 2, y); g.lineTo(x0 + capW - 2, y); g.stroke();
  }

  function roundRect(g, x, y, w, h, r) {
    g.beginPath();
    g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
    g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
  }

  function drawFaders() {
    if (app.pc() && row > 3) row -= 4; // PC mode pairs row r with r + 4
    strips.forEach((st, i) => {
      if (i >= 8 && !app.pc()) return;
      const n = i < 8 ? row * 8 + i : (row + 4) * 8 + i - 8, p = pbOf(n);
      st.led.className = 'sled' + (flashing.has(n) ? ' flash' : p.s === 'playing' ? ' play' : '');
      const w = st.s.clientWidth, h = st.s.clientHeight;
      st.led.style.marginTop = `${h * 0.025}px`;
      st.knob.style.marginTop = `${h * 0.015}px`;
      paintKnob(st.knob, (dled.speedToKnob(p.sp) + 1) / 2, Math.min(Math.max(w * 0.62, 26), 64));
      paintFader(st.fader, p.v);
      st.flash.classList.toggle('down', flashing.has(n));
    });
  }

  // --- fader row: tap between tiles, 3-finger swipe, swipe on the faders, Ctrl + wheel
  function setRow(r) {
    row = Math.min(Math.max(r, 0), 7);
    if (app.pc()) row %= 4; // a tap on row 6 (41-48) also picks its pair 9-16
    draw();
  }
  function swipe(el, fingers, onRows) {
    let y0 = null, row0 = 0;
    el.addEventListener('touchstart', (e) => {
      if (e.touches.length >= fingers) { y0 = e.touches[0].clientY; row0 = row; }
    }, { passive: true });
    el.addEventListener('touchmove', (e) => {
      if (y0 == null || e.touches.length < fingers) return;
      onRows(row0, (e.touches[0].clientY - y0) / app.scale());
    }, { passive: true });
    el.addEventListener('touchend', () => { y0 = null; });
  }
  swipe(grid, 3, (r0, dy) => setRow(r0 - Math.round(dy / 60)));
  window.addEventListener('wheel', (e) => {
    if (!e.ctrlKey) return;
    e.preventDefault();
    setRow(row + Math.sign(e.deltaY));
  }, { passive: false });

  // --- mode buttons ------------------------------------------------------------
  const modeButtons = {
    edit: document.getElementById('bEdit'),
    release: document.getElementById('bRelease'),
    rename: document.getElementById('bRename'),
    swap: document.getElementById('bSwap'),
    props: document.getElementById('bProps'),
  };
  function arm(a) { armed = a; swapFirst = -1; draw(); }
  for (const [name, b] of Object.entries(modeButtons)) {
    if (name === 'release') continue;
    b.addEventListener('click', () => arm(armed === name ? null : name));
  }
  // RELEASE: tap = arm / disarm; hold 0.5 s = release all
  let holdTimer = null, held = false;
  modeButtons.release.addEventListener('pointerdown', () => {
    held = false;
    holdTimer = setTimeout(() => { held = true; dled.releaseAll(); if (armed === 'release') arm(null); }, 500);
  });
  modeButtons.release.addEventListener('pointerup', () => {
    clearTimeout(holdTimer);
    if (!held) arm(armed === 'release' ? null : 'release');
  });
  modeButtons.release.addEventListener('pointerleave', () => clearTimeout(holdTimer));

  function draw() {
    const now = performance.now();
    if (app.pc() && row > 3) row -= 4;
    const locked = !!app.st.locked; // DMX collision in PATCH: no playback changes
    document.getElementById('app').classList.toggle('locked', locked);
    for (const [name, b] of Object.entries(modeButtons)) {
      b.disabled = locked;
      b.classList.toggle('lit', armed === name && !locked);
    }
    drawTiles(now);
    drawFaders();
  }

  return { draw };
})();
