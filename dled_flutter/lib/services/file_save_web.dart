// Save bytes in a browser: the file is offered as a download.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<String?> saveFileAs(String fileName, Uint8List bytes) async {
  await FilePicker.platform.saveFile(fileName: fileName, bytes: bytes);
  return fileName;
}
