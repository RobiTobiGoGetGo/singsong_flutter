import 'dart:typed_data';

abstract class PlatformSupport {
  static PlatformSupport? _instance;
  static PlatformSupport get instance {
    if (_instance == null) {
      throw UnsupportedError('PlatformSupport not initialized');
    }
    return _instance!;
  }

  static void initialize(PlatformSupport instance) {
    _instance = instance;
  }

  Future<Uint8List?> getClipboardImage();
  void downloadLogs(List<String> logs);
  void cleanupWebUrls(List<dynamic> files);
  Future<void> pickSourceFiles(Function(List<dynamic> files, String sourcePath) onFilesPicked);
  Future<String?> createWebUrl(dynamic file);
  Future<Uint8List> getFileBytes(dynamic file);
  void saveFile(Uint8List bytes, String name);
}
