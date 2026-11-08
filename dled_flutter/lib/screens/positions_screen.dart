// positions_screen.dart -- POSITIONS (opened from EDIT): 64 stored positions
// on an 8 x 8 grid like the playbacks.
//
// STORE, RENAME, SWAP and DELETE are armed like the playback page's buttons:
// tap the button, then a tile; the window stays open. A tap on a stored tile
// with nothing armed recalls it in the mode the right-hand button shows
// (SELECTED: into the selected fixtures that are in it; WITH FIXTURES: the
// selection becomes its fixtures) and goes back to EDIT, which applies it
// (the screen returns the position).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/show_model.dart';
import '../widgets/app_button.dart';
import '../widgets/app_theme.dart';
import '../widgets/dialogs.dart';

class PositionsScreen extends StatefulWidget {
  /// The fixtures STORE would store now: every selected fixture with pan /
  /// tilt and its own position in EDIT.
  final List<StoredFixture> Function() toStore;

  /// EDIT's selected fixtures (how many of a tile's fixtures are selected).
  final Set<int> selected;

  const PositionsScreen({super.key, required this.toStore, required this.selected});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  String? _armed; // 'store' | 'rename' | 'swap' | 'delete'
  int _swapFirst = -1;

  late final ShowModel _model = context.read<ShowModel>();
  PositionStore get _store => _model.positions;

  void _arm(String action) => setState(() {
        _armed = _armed == action ? null : action;
        _swapFirst = -1;
      });

  void _tapTile(int tile) {
    final p = _store[tile];
    switch (_armed) {
      case 'store':
        setState(() => _armed = null);
        if (_store.store(tile, widget.toStore())) _model.positionsChanged();
      case 'rename':
        setState(() => _armed = null);
        if (p != null) _rename(tile, p);
      case 'delete':
        setState(() => _armed = null);
        if (_store.delete(tile)) _model.positionsChanged();
      case 'swap':
        if (_swapFirst < 0) {
          if (p != null) setState(() => _swapFirst = tile);
        } else {
          final a = _swapFirst;
          setState(() {
            _armed = null;
            _swapFirst = -1;
          });
          if (_store.swap(a, tile)) _model.positionsChanged();
        }
      default:
        if (p != null) Navigator.of(context).pop(p);
    }
  }

  void _rename(int tile, StoredPosition p) => showDialog(
        context: context,
        builder: (_) => NameDialog(
          title: 'RENAME POSITION',
          initial: p.name.isEmpty ? _defaultName(tile) : p.name,
          clearTo: _defaultName(tile),
          onOk: (name) {
            _store.rename(tile, name == _defaultName(tile) ? '' : name);
            _model.positionsChanged();
          },
        ),
      );

  static String _defaultName(int tile) => 'Pos ${tile + 1}';

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ShowModel>();
    final canStore = widget.toStore().isNotEmpty;
    final withFixtures = model.positionsWithFixtures;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
        AppTopBar(
          connected: model.liveConnected,
          left: [
            AppButton('BACK', onTap: () => Navigator.of(context).pop()),
            AppButton('STORE', lit: _armed == 'store', onTap: canStore || _armed == 'store' ? () => _arm('store') : null),
            AppButton('RENAME', lit: _armed == 'rename', onTap: () => _arm('rename')),
            AppButton('SWAP', lit: _armed == 'swap', onTap: () => _arm('swap')),
            AppButton('DELETE', lit: _armed == 'delete', onTap: () => _arm('delete')),
          ],
          right: [
            AppButton(withFixtures ? 'WITH FIXTURES' : 'SELECTED', width: 150, onTap: () {
              model.positionsWithFixtures = !withFixtures;
              setState(() {});
            }),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Container(
              color: const Color(0xFF212123), // between the tiles, like the playback grid
              child: Column(
                children: List.generate(
                  8,
                  (row) => Expanded(
                    child: Row(
                      children: List.generate(8, (col) {
                        final tile = row * 8 + col;
                        return Expanded(
                          child: GestureDetector(
                            key: ValueKey('position_tile_$tile'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _tapTile(tile),
                            child: _PositionTile(
                              tile: tile,
                              position: _store[tile],
                              fixtures: model.fixtures,
                              selected: widget.selected,
                              swapFirst: _armed == 'swap' && _swapFirst == tile,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// Stored: blue; empty: the playback grid's slate blue. Dimmed when no stored
// fixture matches the patch (same slot and model): it still recalls
// (the user's choice: apply anyway).
const _tileStored = Color(0xFF1D4F86);
const _tileEmpty = Color(0xFF1E2E3E);

class _PositionTile extends StatelessWidget {
  final int tile;
  final StoredPosition? position;
  final List<FixturePatch> fixtures;
  final Set<int> selected;
  final bool swapFirst;
  const _PositionTile({
    required this.tile,
    required this.position,
    required this.fixtures,
    required this.selected,
    required this.swapFirst,
  });

  @override
  Widget build(BuildContext context) {
    final p = position;
    final bySlot = {for (final f in fixtures) if (f.isPatched) f.slot: f};
    final matches = p != null && p.fixtures.values.any((s) => bySlot[s.slot]?.model == s.model);
    final fill = p == null ? _tileEmpty : (matches ? _tileStored : Color.lerp(_tileStored, _tileEmpty, 0.6)!);
    final edge = Color.lerp(fill, Colors.black, 0.35)!;
    final text = Colors.white.withValues(alpha: p == null ? 0.54 : (matches ? 1.0 : 0.6));
    final inSelection = p == null ? 0 : p.fixtures.keys.where(selected.contains).length;
    return Container(
      margin: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [edge, fill, fill, edge],
          stops: const [0.0, 0.1, 0.9, 1.0],
        ),
        border: Border.all(color: swapFirst ? const Color(0xFF4A8AEA) : edge, width: swapFirst ? 2.5 : 1),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 3),
      child: LayoutBuilder(builder: (context, box) {
        final f = (box.maxWidth / 75).clamp(0.7, 1.0);
        return Stack(clipBehavior: Clip.hardEdge, children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Text(
              p == null ? '${tile + 1}' : (p.name.isEmpty ? 'Pos ${tile + 1}' : p.name),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: text, fontSize: 12 * f, height: 1.15),
            ),
          ),
          if (p != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // fixtures in it; with a selection: how many of them are selected
              child: Text(
                selected.isEmpty ? '${p.fixtures.length} fix' : '$inSelection / ${p.fixtures.length} fix',
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(color: text.withValues(alpha: text.a * 0.85), fontSize: 11 * f),
              ),
            ),
        ]);
      }),
    );
  }
}
