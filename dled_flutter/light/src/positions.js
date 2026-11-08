// POSITIONS (screens/positions_screen.dart), opened from EDIT with POS: 64
// stored positions on an 8 x 8 grid like the playbacks. STORE, RENAME, SWAP
// and DELETE (top bar) are armed: tap the button, then a tile. A tap on a
// stored tile with nothing armed recalls it - SELECTED: into the selected
// fixtures that are in it; WITH FIXTURES: the selection becomes its
// fixtures - and goes back to EDIT. Only pan / tilt change, per fixture.
// The positions are saved with the show file (options.js).
'use strict';

const positions = (() => {
  const page = document.getElementById('pgPositions');
  const $ = (id) => document.getElementById(id);
  const bStore = $('bPosStore'), bRename = $('bPosRename'), bSwap = $('bPosSwap'), bDelete = $('bPosDelete'), bMode = $('bPosMode');
  let armed = null, swapFirst = -1;
  let withFixtures = false;
  try { withFixtures = localStorage.getItem('dled_pos_with') === '1'; } catch (_) {}

  const arm = (a) => { armed = armed === a ? null : a; swapFirst = -1; draw(); };
  bStore.addEventListener('click', () => arm('store'));
  bRename.addEventListener('click', () => arm('rename'));
  bSwap.addEventListener('click', () => arm('swap'));
  bDelete.addEventListener('click', () => arm('delete'));
  bMode.addEventListener('click', () => {
    withFixtures = !withFixtures;
    try { localStorage.setItem('dled_pos_with', withFixtures ? '1' : '0'); } catch (_) {}
    draw();
  });

  const grid = ui.el('div', 'posgrid');
  const tiles = [];
  for (let r = 0; r < 8; r++) {
    const row = ui.el('div', 'prow');
    for (let c = 0; c < 8; c++) {
      const i = r * 8 + c;
      const t = ui.el('div', 'ptile'), name = ui.el('div', 't'), count = ui.el('div', 'c');
      t.append(name, count);
      t.addEventListener('click', () => tap(i));
      row.appendChild(t);
      tiles.push({ t, name, count });
    }
    grid.appendChild(row);
  }
  page.appendChild(grid);

  const stored = () => new Map((app.st.positions || []).map((p) => [p.tile, p]));
  const defaultName = (i) => `Pos ${i + 1}`;

  function tap(i) {
    const p = stored().get(i);
    switch (armed) {
      case 'store':
        armed = null;
        dled.positionStore(i);
        break;
      case 'rename':
        armed = null;
        if (p) ui.nameDialog('RENAME POSITION', p.name || defaultName(i),
          (name) => dled.positionRename(i, name === defaultName(i) ? '' : name), { clearTo: defaultName(i) });
        break;
      case 'delete':
        armed = null;
        dled.positionDelete(i);
        break;
      case 'swap':
        if (swapFirst < 0) { if (p) swapFirst = i; } else { dled.positionSwap(swapFirst, i); armed = null; swapFirst = -1; }
        break;
      default:
        if (!p) return;
        dled.positionRecall(i, withFixtures);
        app.show('edit');
        return;
    }
    draw();
  }

  function draw() {
    if (page.hidden) return;
    const e = app.st.edit;
    if (!e) return;
    const map = stored(), sel = new Set(e.fixtures);
    bStore.disabled = !e.storable && armed !== 'store';
    bStore.classList.toggle('lit', armed === 'store');
    bRename.classList.toggle('lit', armed === 'rename');
    bSwap.classList.toggle('lit', armed === 'swap');
    bDelete.classList.toggle('lit', armed === 'delete');
    bMode.textContent = withFixtures ? 'WITH FIXTURES' : 'SELECTED';
    tiles.forEach(({ t, name, count }, i) => {
      const p = map.get(i);
      t.classList.toggle('stored', !!p);
      t.classList.toggle('nomatch', !!p && !p.match);
      t.classList.toggle('swap', armed === 'swap' && swapFirst === i);
      name.textContent = !p ? String(i + 1) : p.name || defaultName(i);
      // fixtures in it; with a selection: how many of them are selected
      count.textContent = !p ? '' : sel.size === 0 ? `${p.slots.length} fix`
        : `${p.slots.filter((s) => sel.has(s)).length} / ${p.slots.length} fix`;
    });
  }

  function open() {
    armed = null;
    swapFirst = -1;
    app.show('positions');
  }

  return { draw, open };
})();
