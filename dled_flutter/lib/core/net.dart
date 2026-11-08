// net.dart -- network helpers shared by the Flutter app and the light page.

/// "192.168.1.12" -> its 4 bytes, or null when it is not a valid IPv4
/// address (the reference app then sends nothing, FINDINGS 20.18).
List<int>? parseIpv4(String s) {
  final parts = s.trim().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255 || p.isEmpty) return null;
    out.add(v);
  }
  return out;
}
