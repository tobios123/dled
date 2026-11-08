// DLED light page: startup, scaling, the pages and the state from
// window.dled (the shared Dart logic, core.js). Pages: playback.js (main
// window), edit.js (with positions.js), patch.js, options.js.
'use strict';

const app = (() => {
  // The layout follows the window's shape (width / height of the page area),
  // never its size in pixels:
  //   up to 0.75 (phones, tablets held upright): 768 wide, scaled to the width
  //   0.75 - 1.55 (a tablet on its side, a 5:4 / 4:3 screen, a window): 1024
  //     high, scaled to the height, as wide as the window (stretched sideways;
  //     scaled to the width the tiles got too flat to use)
  //   1.55 and wider (16:9 / 16:10 full screen): PC mode, the tile grid in
  //     two halves side by side (1-32 | 33-64) over 16 fader strips
  //     (playback.js); the other pages stay 768 wide, centred
  const W = 768, H = 1024; // design size (widgets/design_scale.dart)
  const PC_RATIO = 1.55; // a 16:10 screen's page area is ~1.6-1.75; a 4:3 one's ~1.4 (too narrow strips)
  const shape = () => window.innerWidth / window.innerHeight;
  const pcMode = () => shape() >= PC_RATIO;
  const root = document.getElementById('app');
  const led = document.getElementById('led');
  const pages = {
    playback: document.getElementById('pgPlayback'),
    patch: document.getElementById('pgPatch'),
    edit: document.getElementById('pgEdit'),
    positions: document.getElementById('pgPositions'),
    options: document.getElementById('pgOptions'),
  };
  const bOptions = document.getElementById('bOptions'), bPatch = document.getElementById('bPatch');
  let page = 'playback';
  const api = {
    st: { connected: null, devices: [], pb: [], locked: false, info: null },
    scale: () => (shape() <= W / H ? window.innerWidth / W : window.innerHeight / H),
    pc: pcMode,
    height: () => window.innerHeight / api.scale(), // in design pixels
    ratio: () => (window.devicePixelRatio || 1) * api.scale(),
    redrawSoon,
    show: (p) => show(p),
  };

  function fit() {
    const s = api.scale(), h = window.innerHeight / s, pc = pcMode();
    const w = Math.max(window.innerWidth / s, W); // design width: the whole window
    const left = Math.max(0, (window.innerWidth - w * s) / 2);
    root.classList.toggle('pc', pc);
    root.style.transform = `scale(${s})`;
    root.style.width = `${w}px`;
    root.style.height = `${h}px`;
    root.style.left = `${left}px`;
    document.getElementById('faders').style.height = `${Math.min(Math.max(h * 0.33, 200), 420)}px`;
    // the dialogs are scaled the same way
    document.getElementById('dialogs').style.cssText =
      `position:fixed;left:${left}px;top:0;width:${w}px;height:${h}px;transform:scale(${s});transform-origin:0 0;pointer-events:none`;
    draw();
  }
  window.addEventListener('resize', fit);

  // PATCH / OPTIONS open their page (the mode buttons give way to "back");
  // the lit tab or "back" returns to PLAYBACK, like the app.
  function show(p) {
    // leaving EDIT (POSITIONS belongs to it: EDIT stays open behind it)
    const inEdit = (x) => x === 'edit' || x === 'positions';
    if (inEdit(page) && !inEdit(p)) dled.editClose();
    page = p;
    root.dataset.page = p;
    for (const [name, el] of Object.entries(pages)) el.hidden = name !== p;
    document.getElementById('modes').hidden = p !== 'playback';
    document.getElementById('back').hidden = p === 'playback';
    document.getElementById('posModes').hidden = p !== 'positions';
    bOptions.classList.toggle('lit', p === 'options');
    bPatch.classList.toggle('lit', p === 'patch');
    if (p === 'options') options.shown();
    draw();
  }
  // Pull to reload (mobile browsers do it on pages that scroll; this page
  // keeps every touch for its faders): drag the top bar down 80 px and let
  // go. The hint follows the finger; less than 80 px does nothing.
  (() => {
    const top = document.getElementById('top'), hint = document.getElementById('pull');
    const PULL = 80;
    let y0 = null, pulled = 0;
    top.addEventListener('pointerdown', (e) => { y0 = e.clientY; pulled = 0; });
    window.addEventListener('pointermove', (e) => {
      if (y0 == null) return;
      pulled = Math.max(0, (e.clientY - y0) / api.scale());
      if (pulled < 10) return;
      hint.classList.add('on');
      hint.classList.toggle('ready', pulled >= PULL);
      hint.style.transform = `translate(-50%, ${Math.min(pulled, PULL * 1.5) * api.scale() - 40}px)`;
    });
    const end = () => {
      if (y0 == null) return;
      y0 = null;
      hint.classList.remove('on', 'ready');
      hint.style.transform = '';
      if (pulled >= PULL) location.reload();
    };
    window.addEventListener('pointerup', end);
    window.addEventListener('pointercancel', end);
  })();

  // Full screen: a tap on the name (the sign next to it shows it can) hides
  // the browser's address bar and the phone / tablet bars; another tap, Esc
  // or a swipe from the edge brings them back. Not on iPhones (Safari allows
  // it for videos only): there the sign is not shown.
  (() => {
    const de = document.documentElement, logo = document.getElementById('logo');
    const can = !!(de.requestFullscreen || de.webkitRequestFullscreen);
    const isFull = () => !!(document.fullscreenElement || document.webkitFullscreenElement);
    document.getElementById('fs').hidden = !can;
    if (!can) return;
    logo.style.cursor = 'pointer';
    logo.addEventListener('click', () => {
      // refused by the browser (an embedded one, a policy): nothing (no pop-ups)
      try {
        const r = isFull()
          ? (document.exitFullscreen || document.webkitExitFullscreen).call(document)
          : (de.requestFullscreen || de.webkitRequestFullscreen).call(de);
        if (r && r.catch) r.catch(() => {});
      } catch (_) {}
    });
  })();

  bOptions.addEventListener('click', () => show(page === 'options' ? 'playback' : 'options'));
  bPatch.addEventListener('click', () => show(page === 'patch' ? 'playback' : 'patch'));
  // back: POSITIONS returns to its EDIT, the other pages to PLAYBACK
  document.getElementById('bBack').addEventListener('click', () => show(page === 'positions' ? 'edit' : 'playback'));

  let frame = false, timer = null;
  function redraw() {
    if (frame) return;
    frame = true;
    requestAnimationFrame(() => {
      frame = false;
      api.st = JSON.parse(dled.state());
      draw();
    });
  }
  function redrawSoon(ms) {
    if (timer) return;
    timer = setTimeout(() => { timer = null; redraw(); }, ms);
  }

  function draw() {
    led.classList.toggle('on', !!api.st.connected);
    if (page === 'playback') playback.draw();
    if (page === 'patch') patch.draw();
    if (page === 'edit') edit.draw();
    if (page === 'positions') positions.draw();
    if (page === 'options') options.draw();
  }

  window.addEventListener('load', () => {
    dled.onChange(redraw);
    api.st = JSON.parse(dled.state());
    fit();
    dled.start();
  });
  return api;
})();
