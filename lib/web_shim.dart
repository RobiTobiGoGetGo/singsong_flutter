import 'dart:async';

class Blob {
  Blob(List<dynamic> bits, [String? type]);
}

class Url {
  static String createObjectUrlFromBlob(dynamic blob) => '';
  static void revokeObjectUrl(String url) {}
}

class AnchorElement {
  AnchorElement({String? href});
  void setAttribute(String name, String value) {}
  void click() {}
  String? href;
}

class FileUploadInputElement {
  bool? multiple;
  String? accept;
  void click() {}
  Stream<dynamic> get onChange => const Stream.empty();
  List<dynamic>? files;
}

class FileReader {
  void readAsArrayBuffer(dynamic blob) {}
  Stream<dynamic> get onLoadEnd => const Stream.empty();
  dynamic get result => null;
}

class Window {
  Navigator get navigator => Navigator();
}

class Navigator {
  Clipboard? get clipboard => null;
}

class Clipboard {
  Future<dynamic> read() async => null;
}

final Window window = Window();
