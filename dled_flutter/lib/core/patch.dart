// patch.dart -- patch rules shared by the Flutter app and the light page.

/// The keys of the ranges that overlap another range: DMX channels
/// [start] .. start + count - 1, per universe. Two patched fixtures that
/// share DMX channels cannot be driven properly, so PATCH shows their address
/// in red and PLAYBACK / EDIT are locked until it is fixed (like the real
/// app). Ranges with count < 1 (an empty slot with only a name) never count.
Set<int> overlappingRanges(List<({int key, int start, int count, int universe})> ranges) {
  final out = <int>{};
  for (var i = 0; i < ranges.length; i++) {
    for (var j = i + 1; j < ranges.length; j++) {
      final a = ranges[i], b = ranges[j];
      if (a.count < 1 || b.count < 1 || a.universe != b.universe) continue;
      final aEnd = a.start + a.count - 1, bEnd = b.start + b.count - 1;
      if (a.start <= bEnd && b.start <= aEnd) out..add(a.key)..add(b.key);
    }
  }
  return out;
}

/// DMX channels of a fixture profile: one per two hex digits.
int profileChannels(String profileHex) => profileHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').length ~/ 2;

/// The lowest DMX address from [from] where [count] channels fit without
/// overlapping any of [used] (start, count) in 1..512; [from] when nothing
/// fits. PERSONALITY uses it so a new fixture lands in free channels.
int freeAddress(List<({int start, int count})> used, int count, {int from = 1}) {
  final n = count < 1 ? 1 : count;
  for (var s = from < 1 ? 1 : from; s + n - 1 <= 512; s++) {
    final clash = used.any((u) => u.count > 0 && s <= u.start + u.count - 1 && u.start <= s + n - 1);
    if (!clash) return s;
  }
  return from < 1 ? 1 : from;
}
