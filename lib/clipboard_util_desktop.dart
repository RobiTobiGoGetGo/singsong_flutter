import 'dart:typed_data';
import 'package:pasteboard/pasteboard.dart';

Future<Uint8List?> getClipboardImageImpl() async {
  return await Pasteboard.image;
}
