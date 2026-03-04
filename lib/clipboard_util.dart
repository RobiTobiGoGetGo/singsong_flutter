import 'dart:typed_data';
import 'clipboard_util_stub.dart'
    if (dart.library.html) 'clipboard_util_web.dart'
    if (dart.library.io) 'clipboard_util_desktop.dart';

Future<Uint8List?> getClipboardImage() => getClipboardImageImpl();
