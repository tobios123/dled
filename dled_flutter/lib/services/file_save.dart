// Save bytes to a file the user picks (desktop / mobile).
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Ask where to save [fileName]; returns the path, or null when cancelled.
Future<String?> saveFileAs(String fileName, Uint8List bytes) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Export show',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['show'],
    bytes: bytes, // Android / iOS write the file themselves
  );
  if (path == null) return null;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // Desktop only returns the chosen path.
    await File(path.toLowerCase().endsWith('.show') ? path : '$path.show').writeAsBytes(bytes);
  }
  return path;
}
