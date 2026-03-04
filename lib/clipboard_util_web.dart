import 'dart:html' as html;
import 'dart:typed_data';

Future<Uint8List?> getClipboardImageImpl() async {
  try {
    final dynamic data = await html.window.navigator.clipboard?.read();
    if (data != null) {
      final List<dynamic> items = List.from(data);
      for (var item in items) {
        if (item.types.contains('image/png')) {
          final blob = await item.getType('image/png');
          final reader = html.FileReader();
          reader.readAsArrayBuffer(blob);
          await reader.onLoadEnd.first;
          return reader.result as Uint8List;
        } else if (item.types.contains('image/jpeg')) {
          final blob = await item.getType('image/jpeg');
          final reader = html.FileReader();
          reader.readAsArrayBuffer(blob);
          await reader.onLoadEnd.first;
          return reader.result as Uint8List;
        }
      }
    }
  } catch (e) {
    rethrow;
  }
  return null;
}
