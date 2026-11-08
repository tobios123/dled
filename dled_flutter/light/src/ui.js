// Shared look of the light page: the dialogs (widgets/dialogs.dart):
// a panel with a grey vertical title strip, flat outlined buttons, text
// fields, check boxes and segment rows.
'use strict';

const ui = {
  el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  },

  /// A dialog: grey strip with [title], [body] next to it. Returns close().
  panel(title, body, { strip = 'grey', padding } = {}) {
    const back = ui.el('div', 'dlg-back');
    const p = ui.el('div', 'dlg');
    const s = ui.el('div', 'dlg-strip ' + strip, title);
    const b = ui.el('div', 'dlg-body');
    if (padding != null) b.style.padding = padding + 'px';
    b.appendChild(body);
    p.append(s, b);
    back.appendChild(p);
    document.getElementById('dialogs').appendChild(back);
    return () => back.remove();
  },

  button(text, onTap, { width } = {}) {
    const b = ui.el('button', 'cbtn', text);
    if (width) b.style.width = width + 'px';
    if (onTap) b.addEventListener('click', onTap); else b.disabled = true;
    return b;
  },

  row(label, control) {
    const r = ui.el('div', 'crow');
    r.append(ui.el('span', 'crow-l', label), control);
    return r;
  },

  checkbox(value, onChange) {
    const c = ui.el('div', 'ccheck' + (value ? ' on' : ''));
    c.addEventListener('click', () => {
      value = !value;
      c.classList.toggle('on', value);
      onChange(value);
    });
    return c;
  },

  segments(options, selected, onChange) {
    const s = ui.el('div', 'cseg');
    options.forEach((o, i) => {
      const b = ui.el('div', i === selected ? 'sel' : '', o);
      b.addEventListener('click', () => {
        [...s.children].forEach((x, j) => x.classList.toggle('sel', j === i));
        onChange(i);
      });
      s.appendChild(b);
    });
    return s;
  },

  /// RENAME PLAYBACK and other names: field with the name selected, X puts
  /// back [clearTo], Ok (or Enter) saves, Cancel closes.
  nameDialog(title, initial, onOk, { clearTo = '' } = {}) {
    const body = ui.el('div', 'name-dlg');
    const f = ui.el('input', 'cfield');
    f.value = initial;
    const ok = () => { close(); onOk(f.value.trim()); };
    f.addEventListener('keydown', (e) => { if (e.key === 'Enter') ok(); });
    const top = ui.el('div', 'name-row');
    top.append(f, ui.button('X', () => { f.value = clearTo; f.focus(); }, { width: 36 }));
    const bottom = ui.el('div', 'btn-row');
    bottom.append(ui.button('Ok', ok), ui.button('Cancel', () => close()));
    body.append(top, bottom);
    const close = ui.panel(title, body);
    setTimeout(() => { f.focus(); f.select(); });
  },

  /// ARE YOU SURE? (yellow): [question], Ok / Cancel. Promise of true on Ok.
  confirm(question) {
    return new Promise((done) => {
      const body = ui.el('div', 'small-dlg');
      body.appendChild(ui.el('div', 'q', question));
      const btns = ui.el('div', 'btn-row');
      const ok = ui.button('Ok', () => { close(); done(true); });
      const no = ui.button('Cancel', () => { close(); done(false); });
      ok.classList.add('yellow'); no.classList.add('yellow');
      btns.append(ok, no);
      body.appendChild(btns);
      const close = ui.panel('ARE YOU SURE?', body, { strip: 'yellow' });
    });
  },

  /// LOADING... (yellow): progress bar, what is being done, Abort.
  /// Returns {set(fraction, text), close()}; [onAbort] once.
  loading(onAbort) {
    const body = ui.el('div', 'small-dlg');
    const bar = ui.el('div', 'pbar'), fill = ui.el('div', 'pfill'), text = ui.el('div', 'ptext', 'Opening show file...');
    bar.appendChild(fill);
    const btns = ui.el('div', 'btn-row');
    const abort = ui.button('Abort', () => { abort.disabled = true; onAbort(); });
    btns.appendChild(abort);
    body.append(ui.el('div', 'phead', 'PROGRESS'), bar, text, btns);
    const close = ui.panel('LOADING...', body, { strip: 'yellow' });
    return {
      set(f, t) {
        if (f >= 0) fill.style.width = `${Math.min(Math.max(f, 0), 1) * 100}%`;
        if (t) text.textContent = t;
      },
      close,
    };
  },

  arrow(up, width, onTap) {
    const b = ui.button('', onTap, { width });
    b.classList.add(up ? 'up' : 'down', 'arrow');
    return b;
  },

  /// ART-NET: Enabled, sub.uni (subnet and universe 0-15, an up / down pair
  /// each). onOk(enabled, raw = subnet x 16 + universe).
  artNetDialog(enabled, raw, onOk) {
    let on = enabled, sub = Math.floor(raw / 16) % 16, uni = raw % 16;
    const body = ui.el('div', 'num-dlg');
    const value = ui.el('div', 'numbox wide');
    const show = () => { value.textContent = `${sub}.${uni}`; };
    const pair = (up) => {
      const r = ui.el('div', 'num-pad');
      r.append(ui.arrow(up, 96, () => { sub = (sub + (up ? 1 : 15)) % 16; show(); }),
        ui.arrow(up, 96, () => { uni = (uni + (up ? 1 : 15)) % 16; show(); }));
      return r;
    };
    const btns = ui.el('div', 'num-pad');
    btns.append(ui.button('Ok', () => { close(); onOk(on, sub * 16 + uni); }), ui.button('Cancel', () => close()));
    body.append(ui.row('Enabled', ui.checkbox(on, (v) => { on = v; })), pair(true), ui.row('sub.uni', value), pair(false), btns);
    body.querySelectorAll('.crow-l').forEach((l) => { l.style.width = '64px'; });
    show();
    const close = ui.panel('ART-NET', body);
  },

  /// sACN: Enabled, universe 1-63999 with one up / down pair.
  sacnDialog(enabled, universe, onOk) {
    let on = enabled, u = Math.min(Math.max(universe, 1), 63999);
    const body = ui.el('div', 'num-dlg');
    const value = ui.el('div', 'numbox');
    const show = () => { value.textContent = String(u); };
    const one = (up) => {
      const r = ui.el('div', 'num-pad');
      r.appendChild(ui.arrow(up, 200, () => { u = up ? (u >= 63999 ? 1 : u + 1) : (u <= 1 ? 63999 : u - 1); show(); }));
      return r;
    };
    const btns = ui.el('div', 'num-pad');
    btns.append(ui.button('Ok', () => { close(); onOk(on, u); }), ui.button('Cancel', () => close()));
    body.append(ui.row('Enabled', ui.checkbox(on, (v) => { on = v; })), one(true), ui.row('sub.uni', value), one(false), btns);
    body.querySelectorAll('.crow-l').forEach((l) => { l.style.width = '64px'; });
    show();
    const close = ui.panel('SACN', body);
  },

  /// The 64 fixture slots (widgets/fixture_grid.dart) of PATCH and EDIT: tap
  /// toggles a slot; dragging selects the rectangle from the slot where it
  /// started to the one under the pointer (starting on a selected slot
  /// deselects), slots that leave the rectangle go back. [onSelect](Set) gets
  /// the new selection; draw(...) shows it. [flags]: the PATCH bottom row.
  fixtureGrid({ flags = true, onSelect }) {
    const grid = ui.el('div', 'fgrid' + (flags ? '' : ' edit'));
    const tiles = [];
    for (let i = 0; i < 64; i++) {
      const t = ui.el('div', 'ftile');
      const name = ui.el('div', 'fname'), info = ui.el('div', 'finfo');
      t.append(name, info);
      const tile = { t, name, info };
      if (flags) {
        const bottom = ui.el('div', 'fbot');
        tile.flags = ui.el('span', 'fflags');
        tile.addr = ui.el('span', 'faddr');
        bottom.append(tile.flags, tile.addr);
        t.appendChild(bottom);
      }
      t.dataset.slot = i;
      grid.appendChild(t);
      tiles.push(tile);
    }
    let sel = new Set(), anchor = null, deselecting = false, before = null, moved = false;
    const slotAt = (x, y) => {
      const el = document.elementFromPoint(x, y);
      const t = el && el.closest('.ftile');
      return t && grid.contains(t) ? Number(t.dataset.slot) : null;
    };
    grid.addEventListener('pointerdown', (e) => {
      const s = slotAt(e.clientX, e.clientY);
      if (s == null) return;
      grid.setPointerCapture(e.pointerId);
      anchor = s; deselecting = sel.has(s); before = new Set(sel); moved = false;
    });
    grid.addEventListener('pointermove', (e) => {
      if (anchor == null) return;
      const s = slotAt(e.clientX, e.clientY);
      if (s == null || (s === anchor && !moved)) return;
      moved = true;
      const r0 = Math.min(Math.floor(anchor / 8), Math.floor(s / 8)), r1 = Math.max(Math.floor(anchor / 8), Math.floor(s / 8));
      const c0 = Math.min(anchor % 8, s % 8), c1 = Math.max(anchor % 8, s % 8);
      const next = new Set(before);
      for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) deselecting ? next.delete(r * 8 + c) : next.add(r * 8 + c);
      sel = next;
      onSelect(next);
    });
    grid.addEventListener('pointerup', () => {
      if (anchor != null && !moved) {
        const next = new Set(sel);
        next.has(anchor) ? next.delete(anchor) : next.add(anchor);
        sel = next;
        onSelect(next);
      }
      anchor = null;
    });
    grid.addEventListener('pointercancel', () => { anchor = null; });

    /// fixtures: state().fixtures; selected: Set; recorded (EDIT): the
    /// loaded cue's slots (red, white for an empty slot); clash: red addresses.
    function draw(fixtures, selected, { recorded = null, clash = [] } = {}) {
      sel = new Set(selected);
      const fx = Object.fromEntries(fixtures.map((f) => [f.slot, f]));
      const rec = new Set(recorded || []), red = new Set(clash);
      tiles.forEach((tile, i) => {
        const f = fx[i], s = sel.has(i);
        tile.t.classList.toggle('sel', s);
        tile.t.classList.toggle('rec', rec.has(i) && !(f && f.patched));
        tile.t.classList.toggle('red', rec.has(i) && !!(f && f.patched));
        tile.name.textContent = f && f.name ? f.name : String(i + 1);
        const lines = f ? [f.mfr, f.model, f.mode].filter((x) => x) : [];
        if (tile.info.dataset.v !== lines.join('\n')) {
          tile.info.dataset.v = lines.join('\n');
          tile.info.innerHTML = '';
          for (const line of lines) tile.info.appendChild(ui.el('div', '', line));
        }
        if (tile.flags) {
          tile.flags.textContent = !f ? '----' : `${f.p ? 'P' : '-'}${f.t ? 'T' : '-'}${f.s ? 'S' : '-'}${f.d ? 'D' : '-'}`;
          tile.addr.textContent = f ? String(f.address) : '';
          tile.addr.classList.toggle('clash', red.has(i));
        }
      });
    }
    return { el: grid, draw };
  },

  /// SET IP ADDRESS: DHCP / Static, IP address, subnet mask. onOk(dhcp, ip,
  /// mask) returns false for an invalid address (the dialog then stays open).
  ipDialog(dhcp, ip, mask, onOk) {
    const body = ui.el('div', 'ip-dlg');
    const fIp = ui.el('input', 'cfield'), fMask = ui.el('input', 'cfield');
    fIp.value = ip; fMask.value = mask;
    const enable = () => { fIp.disabled = fMask.disabled = dhcp; };
    const seg = ui.segments(['DHCP', 'Static'], dhcp ? 0 : 1, (i) => { dhcp = i === 0; enable(); });
    seg.classList.add('right');
    const btns = ui.el('div', 'btn-row');
    btns.append(ui.button('Ok', () => { if (onOk(dhcp, fIp.value.trim(), fMask.value.trim()) !== false) close(); }),
      ui.button('Cancel', () => close()));
    const r1 = ui.row('IP Address', fIp), r2 = ui.row('Subnet mask', fMask);
    body.append(seg, r1, r2, btns);
    enable();
    const close = ui.panel('SET IP ADDRESS', body);
  },
};
