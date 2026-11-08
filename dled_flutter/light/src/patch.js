// PATCH (screens/patch_screen.dart + widgets/fixture_grid.dart): the 64
// fixture slots; tap / drag to select, PERSONALITY / RENAME / ADDRESS /
// CLEAR and the four patch flags. Every change is written to the LPU at once
// and read back (dled.personality ...).
'use strict';

const patch = (() => {
  const page = document.getElementById('pgPatch');
  const selected = new Set();

  // --- layout ---------------------------------------------------------------
  const head = ui.el('div', 'phead2');
  const title = ui.el('span', 'ohead', 'FIXTURES');
  const deselect = ui.el('span', 'desel', 'DESELECT ALL');
  deselect.addEventListener('click', () => { selected.clear(); draw(); });
  head.append(title, ui.el('span', 'fill'), deselect);
  const grid = ui.fixtureGrid({ onSelect: (next) => { selected.clear(); next.forEach((x) => selected.add(x)); draw(); } });
  const btn = (label, fn) => {
    const b = ui.el('button', 'pbtn');
    b.innerHTML = label;
    b.addEventListener('click', fn);
    return b;
  };
  const left = ui.el('div', 'ppanel left');
  const g1 = ui.el('div', 'grpv'), g2 = ui.el('div', 'grpv');
  const bPers = btn('PERSONALITY', () => personalityDialog()), bName = btn('RENAME', () => renameDialog()),
    bAddr = btn('ADDRESS', () => addressDialog()), bClear = btn('CLEAR', () => clear());
  g1.append(bPers, bName, bAddr);
  g2.append(bClear);
  left.append(g1, g2);
  const right = ui.el('div', 'ppanel right');
  const g3 = ui.el('div', 'grph');
  const flagBtns = [['p', 'INVERT<br>PAN'], ['t', 'INVERT<br>TILT'], ['s', 'SWAP<br>PAN/TILT'], ['d', 'VIRTUAL<br>DIMMER']]
    .map(([k, l]) => btn(l, () => dled.flag([...selected], k)));
  g3.append(...flagBtns);
  right.appendChild(g3);
  const bar = ui.el('div', 'pbar2');
  bar.append(left, right);
  page.append(head, grid.el, bar);

  // --- actions ----------------------------------------------------------------
  const byslot = () => Object.fromEntries(app.st.fixtures.map((f) => [f.slot, f]));
  const sel = () => [...selected].sort((a, b) => a - b);

  async function clear() {
    dled.clearFixtures(sel());
    selected.clear();
    draw();
  }

  function renameDialog() {
    const first = byslot()[sel()[0]];
    ui.nameDialog('RENAME FIXTURE', first ? first.name : '', (name) => dled.renameFixtures(sel(), name));
  }

  // SET START ADDRESS: DIP switches 1-10 (the address in binary), up / down
  // per digit around a 3-digit display, Ok / Cancel.
  function addressDialog() {
    const first = byslot()[sel()[0]];
    let a = Math.min(Math.max(first ? first.address : 1, 1), 512);
    const body = ui.el('div', 'addr-dlg');
    const dips = ui.el('div', 'dips');
    const display = ui.el('div', 'addr-num');
    const set = (v) => { if (v >= 1 && v <= 512) { a = v; show(); } };
    const dipEls = [];
    for (let b = 0; b < 10; b++) {
      const d = ui.el('div', 'dip');
      const on = ui.el('div', 'h', 'on'), num = ui.el('div', 'h', String(b + 1));
      d.append(on, num);
      d.addEventListener('click', () => set(a ^ (1 << b)));
      dips.appendChild(d);
      dipEls.push({ on, num });
    }
    const arrows = (up) => {
      const r = ui.el('div', 'addr-arrows');
      for (const step of [100, 10, 1]) r.appendChild(ui.arrow(up, null, () => set(a + (up ? step : -step))));
      return r;
    };
    function show() {
      display.textContent = String(a).padStart(3, '0');
      dipEls.forEach((d, b) => {
        const lit = (a & (1 << b)) !== 0;
        d.on.classList.toggle('lit', lit);
        d.num.classList.toggle('lit', !lit);
      });
    }
    const btns = ui.el('div', 'btn-row');
    btns.append(ui.button('Ok', () => { close(); dled.addressFixtures(sel(), a); }, { width: 104 }), ui.button('Cancel', () => close(), { width: 104 }));
    body.append(dips, arrows(true), display, arrows(false), btns);
    show();
    const close = ui.panel('SET START ADDRESS', body);
  }

  // PERSONALITY LIBRARY: a-z (jumps to the first manufacturer with that
  // letter), Manufacturer / Model / Mode, Ok when a model is chosen.
  let library = null; // [{label, models: [{label, modes: [[label, hex]]}]}]
  async function loadLibrary() {
    if (library) return library;
    const text = await (await fetch('personalities.xml')).text();
    const xml = new DOMParser().parseFromString(text, 'text/xml');
    library = [...xml.getElementsByTagName('manufacturer')].map((m) => ({
      label: m.getAttribute('label') || '',
      models: [...m.getElementsByTagName('model')].map((mo) => {
        const modes = [...mo.getElementsByTagName('mode')].map((x) => [x.getAttribute('label') || '', x.textContent.trim()]);
        return { label: mo.getAttribute('label') || '', modes: modes.length ? modes : [['Default', mo.textContent.trim()]] };
      }),
    }));
    return library;
  }
  async function personalityDialog() {
    const lib = await loadLibrary();
    let mfr = null, model = null, mode = null;
    const body = ui.el('div', 'lib-dlg');
    body.style.height = `${Math.min(Math.max(app.height() - 120, 300), 760)}px`;
    const letters = ui.el('div', 'lib-az');
    const cols = ui.el('div', 'lib-cols');
    const headRow = ui.el('div', 'lib-head');
    headRow.append(ui.el('div', 'c5', 'Manufacturer'), ui.el('div', 'c5', 'Model'), ui.el('div', 'c3', 'Mode'));
    const lists = ui.el('div', 'lib-lists');
    const lm = ui.el('div', 'lib-list c5'), lmo = ui.el('div', 'lib-list c5'), lmd = ui.el('div', 'lib-list c3');
    lists.append(lm, lmo, lmd);
    const btns = ui.el('div', 'btn-row');
    const ok = ui.button('Ok', () => {
      close();
      dled.personality(sel(), mfr.label, model.label, mode[0], mode[1]);
    });
    btns.append(ok, ui.button('Cancel', () => close()));
    cols.append(headRow, lists, btns);
    body.append(letters, cols);
    for (let c = 97; c <= 122; c++) {
      const l = ui.el('div', '', String.fromCharCode(c));
      l.addEventListener('click', () => {
        const i = lib.findIndex((m) => m.label.toLowerCase().startsWith(l.textContent));
        if (i >= 0) lm.scrollTop = i * 45;
      });
      letters.appendChild(l);
    }
    // rows are only rebuilt when the items change (keeps the scroll position)
    const fill = (list, items, isSel, onPick) => {
      if (list.items !== items) {
        list.items = items;
        list.innerHTML = '';
        list.scrollTop = 0;
        items.forEach((it, i) => {
          const r = ui.el('div', 'lib-row', it.label || it[0]);
          r.addEventListener('click', () => onPick(it, i));
          list.appendChild(r);
        });
      }
      [...list.children].forEach((r, i) => r.classList.toggle('sel', isSel(items[i])));
    };
    function draw2() {
      fill(lm, lib, (m) => m === mfr, (m) => { mfr = m; model = null; mode = null; draw2(); });
      fill(lmo, mfr ? mfr.models : [], (m) => m === model, (m) => { model = m; mode = m.modes[0]; draw2(); });
      fill(lmd, model ? model.modes : [], (m) => m === mode, (m) => { mode = m; draw2(); });
      ok.disabled = !model;
    }
    draw2();
    const close = ui.panel('PERSONALITY LIBRARY', body, { padding: 0 });
  }

  // --- drawing ----------------------------------------------------------------
  function draw() {
    if (page.hidden) return;
    grid.draw(app.st.fixtures, selected, { clash: app.st.collisions || [] });
    const any = selected.size > 0;
    deselect.hidden = !any;
    [bPers, bName, bAddr, bClear, ...flagBtns].forEach((b) => { b.disabled = !any || !app.st.connected; });
  }

  return { draw };
})();
