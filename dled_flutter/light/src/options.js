// OPTIONS (screens/options_screen.dart): the LPUs on the network (tap one to
// connect, tap empty space to disconnect) with IP ADDRESS / RENAME /
// ART-NET / sACN, and the show files kept on the box (NEW / REMOVE / RENAME /
// SAVE / SAVE AS / OPEN, IMPORT / EXPORT).
'use strict';

const options = (() => {
  const page = document.getElementById('pgOptions');
  const COLS = [26, 18, 16, 18, 14, 10]; // DEVICES LABEL FIRMWARE HARDWARE ART-NET sACN
  let shows = []; // [{name, size, modified}]
  let selected = null; // selected show name
  let showName = localStorage.getItem('dled_show') || 'Untitled'; // the show the LPU holds

  const cols = (cells) => {
    const r = ui.el('div', 'ocols');
    cells.forEach((c, i) => {
      const e = typeof c === 'string' ? ui.el('div', '', c) : c;
      e.style.flex = String(COLS[i]);
      r.appendChild(e);
    });
    return r;
  };

  // --- layout ---------------------------------------------------------------
  const devHead = cols(['DEVICES', 'LABEL', 'FIRMWARE', 'HARDWARE', 'ART-NET', 'sACN']);
  devHead.classList.add('ohead');
  const devList = ui.el('div', 'opanel');
  devList.addEventListener('click', (e) => { if (e.target === devList) dled.deselect(); });
  const devBtns = {
    ip: ui.button('IP ADDRESS', () => ipAddress()),
    name: ui.button('RENAME', () => renameDevice()),
    artnet: ui.button('ART-NET', () => artNet()),
    sacn: ui.button('sACN', () => sacn()),
  };
  devBtns.ip.classList.add('small'); // one line, like the app's scaled-down label
  const devCol = ui.el('div', 'ogrp');
  devCol.append(...Object.values(devBtns));
  const devSec = section(devHead, devList, [devCol], 34);

  const showHead = ui.el('div', 'ohead pad', 'SHOW FILES');
  const showList = ui.el('div', 'opanel');
  showList.addEventListener('click', (e) => { if (e.target === showList) { selected = null; draw(); } });
  const showBtns = {
    nw: ui.button('NEW', () => newShow()),
    rm: ui.button('REMOVE', () => removeShow()),
    rn: ui.button('RENAME', () => renameShow()),
    save: ui.button('SAVE', () => save()),
    saveAs: ui.button('SAVE AS', () => saveAs()),
    open: ui.button('OPEN', () => openShow()),
  };
  const fileBtns = { imp: ui.button('IMPORT', () => importShow()), exp: ui.button('EXPORT', () => exportShow()) };
  const g1 = ui.el('div', 'ogrp'), g2 = ui.el('div', 'ogrp');
  g1.append(...Object.values(showBtns));
  g2.append(...Object.values(fileBtns));
  const version = ui.el('div', 'over', 'v1.20'); // DLED's version (pubspec.yaml)
  const showSec = section(showHead, showList, [g1, g2, version], 26);
  page.append(devSec, showSec);

  function section(head, list, side, top) {
    const s = ui.el('div', 'osec');
    const left = ui.el('div', 'oleft');
    left.append(head, list);
    const right = ui.el('div', 'oright');
    right.style.paddingTop = top + 'px';
    right.append(...side);
    s.append(left, right);
    return s;
  }

  // --- devices --------------------------------------------------------------
  function drawDevices() {
    const st = app.st, c = st.connected, info = st.info;
    // like the app: the LPU being connected is selected at once, and tapping
    // it again does not start over (the show download takes a few seconds)
    const active = c ? c.ip : st.connecting;
    devList.innerHTML = '';
    for (const d of st.devices) {
      const sel = active === d.ip;
      const known = sel && c && info; // Art-Net / sACN / hardware are read once connected
      const first = ui.el('div', 'oip');
      first.append(ui.el('span', 'lpuicon'), ui.el('span', '', d.ip));
      const row = cols([first, known ? info.alias : '', d.version, known ? info.pcb : '',
        !known ? '' : info.artNet ? `${Math.floor(info.artNetRaw / 16)}.${info.artNetRaw % 16}` : '-',
        !known ? '' : info.sacn ? String(info.sacnUniverse) : '-']);
      row.classList.add('orow');
      row.classList.toggle('sel', !!sel);
      row.addEventListener('click', () => { if (!sel) dled.connect(d.ip); });
      devList.appendChild(row);
    }
    const on = !!(c && info);
    Object.values(devBtns).forEach((b) => { b.disabled = !on; });
  }

  function ipAddress() {
    const st = app.st;
    ui.ipDialog(true, st.connected.ip, (st.info && st.info.subnet) || '255.255.255.0', (dhcp, ip, mask) => dled.network(dhcp, ip, mask));
  }
  function renameDevice() {
    ui.nameDialog('DEVICE NAME', app.st.info.alias, (name) => dled.deviceName(name));
  }
  function artNet() {
    const i = app.st.info;
    ui.artNetDialog(i.artNet, i.artNetRaw, (on, raw) => dled.artNet(on, raw));
  }
  function sacn() {
    const i = app.st.info;
    ui.sacnDialog(i.sacn, i.sacnUniverse, (on, u) => dled.sacn(on, u));
  }

  // --- show files (on the box: /api/shows) -----------------------------------
  const url = (name) => `api/shows/${encodeURIComponent(name)}`;
  // A show's stored positions (positions.js) are the file NAME.positions next
  // to it (the PC bridge: NAME.positions.json, like the Windows app); saved,
  // renamed and removed with the show, read when it is opened.
  const POS = '.positions';
  const posUrl = (name) => url(name + POS);
  async function loadPositions(name) {
    let text = '';
    try {
      const r = name === 'Untitled' ? null : await fetch(posUrl(name), { cache: 'no-store' });
      if (r && r.ok) text = await r.text();
    } catch (_) {}
    dled.positionsLoad(text);
  }
  async function savePositions(name) {
    const text = dled.positionsText();
    try {
      await fetch(posUrl(name), text ? { method: 'PUT', body: text } : { method: 'DELETE' });
    } catch (_) {}
  }
  async function refresh() {
    try {
      const r = await fetch('api/shows', { cache: 'no-store' });
      shows = r.ok ? (await r.json()).filter((s) => !s.name.endsWith(POS)) : [];
    } catch (_) { shows = []; }
    if (selected && !shows.some((s) => s.name === selected)) selected = null;
    draw();
  }
  const exists = (name) => shows.some((s) => s.name.toLowerCase() === name.toLowerCase());
  const two = (n) => String(n).padStart(2, '0');
  const date = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`; };
  const size = (b) => (b < 1024 ? `${b} bytes` : `${Math.round(b / 1024)} kB`);

  function drawShows() {
    showList.innerHTML = '';
    for (const s of shows) {
      const row = ui.el('div', 'orow file');
      row.classList.toggle('sel', s.name === selected);
      const n = ui.el('div', 'n', s.name), d = ui.el('div', 'd', date(s.modified)), z = ui.el('div', 'z', size(s.size));
      row.append(n, d, z);
      row.addEventListener('click', () => { selected = s.name; draw(); });
      showList.appendChild(row);
    }
    const sel = selected != null;
    showBtns.rm.disabled = showBtns.rn.disabled = !sel;
    showBtns.open.disabled = !sel || !app.st.connected;
    showBtns.save.disabled = showBtns.saveAs.disabled = !app.st.connected;
    fileBtns.exp.disabled = !sel;
  }

  async function put(name, text) {
    const r = await fetch(url(name), { method: 'PUT', body: text });
    return r.ok;
  }
  function nextShowName() {
    for (let n = 1; ; n++) if (!exists(`show ${n}`)) return `show ${n}`;
  }
  function setShowName(n) { showName = n; localStorage.setItem('dled_show', n); }

  // NEW: an empty "show N" added to the list, no questions (reference app)
  async function newShow() {
    const name = nextShowName();
    if (await put(name, dled.emptyShowText())) { selected = name; await refresh(); }
  }
  async function removeShow() {
    if (!(await ui.confirm('Remove file?'))) return;
    await fetch(url(selected), { method: 'DELETE' });
    await fetch(posUrl(selected), { method: 'DELETE' }).catch(() => {});
    selected = null;
    await refresh();
  }
  function renameShow() {
    const old = selected;
    ui.nameDialog('SHOWFILE NAME', old, async (name) => {
      if (!name || name === old) return;
      if (exists(name) && !(await ui.confirm('Overwrite file?'))) return;
      const r = await fetch(`${url(old)}?to=${encodeURIComponent(name)}`, { method: 'POST' });
      if (r.ok) {
        if (showName === old) setShowName(name);
        selected = name;
        // its positions go with it (none: the new name has none either)
        await fetch(posUrl(name), { method: 'DELETE' }).catch(() => {});
        await fetch(`${posUrl(old)}?to=${encodeURIComponent(name + POS)}`, { method: 'POST' }).catch(() => {});
      }
      await refresh();
    });
  }
  // SAVE: into the selected show file (else the open show's name)
  function save() {
    const target = selected || showName;
    if (target === 'Untitled') return saveAs();
    return saveTo(target);
  }
  function saveAs() {
    ui.nameDialog('SHOWFILE NAME', showName === 'Untitled' ? nextShowName() : showName, (name) => saveTo(name));
  }
  async function saveTo(name) {
    if (!name) return;
    if (exists(name) && !(await ui.confirm('Overwrite file?'))) return;
    if (await put(name, dled.showText())) { setShowName(name); selected = name; await savePositions(name); }
    await refresh();
  }

  // OPEN: send the show to the LPU with LOADING... (progress, Abort puts the
  // LPU's previous show back)
  async function openShow() {
    const name = selected;
    const r = await fetch(url(name), { cache: 'no-store' });
    if (!r.ok) return;
    const text = await r.text();
    let aborted = false;
    const steps = {
      'releasing all playbacks': 'Releasing all playbacks...',
      uploading: 'Sending the show to the LPU...',
      'restoring the previous show': 'Aborted: restoring the previous show...',
      verifying: 'Checking the show on the LPU...',
    };
    const dlg = ui.loading(() => { aborted = true; });
    const msg = await dled.openShow(text, (f, step) => dlg.set(f, steps[step]), () => aborted);
    dlg.close();
    if (!aborted && msg.startsWith('Sent')) { setShowName(name); await loadPositions(name); }
  }

  // IMPORT: a .show file from this device into the box's list
  function importShow() {
    const input = ui.el('input');
    input.type = 'file';
    input.accept = '.show';
    input.addEventListener('change', async () => {
      const f = input.files && input.files[0];
      if (!f) return;
      const text = await f.text();
      if (!dled.checkShow(text)) return; // not a .show file: nothing (no pop-ups)
      const name = f.name.replace(/\.show$/i, '');
      if (exists(name) && !(await ui.confirm('Overwrite file?'))) return;
      if (await put(name, text)) selected = name;
      await refresh();
    });
    input.click();
  }
  // EXPORT: the selected show file to this device
  async function exportShow() {
    const r = await fetch(url(selected), { cache: 'no-store' });
    if (!r.ok) return;
    const a = ui.el('a');
    a.href = URL.createObjectURL(new Blob([await r.text()], { type: 'application/xml' }));
    a.download = `${selected}.show`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  function draw() {
    if (page.hidden) return;
    drawDevices();
    drawShows();
  }

  loadPositions(showName); // the show the LPU holds: its positions

  return { draw, shown: refresh };
})();
