import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:id3/id3.dart';
import 'dart:io';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void main() {
  runApp(const SingSongApp());
}

class SingSongApp extends StatelessWidget {
  const SingSongApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SingSong',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const SingSongHomePage(),
    );
  }
}

class MP3File {
  final String name;
  final int size;
  Uint8List? artwork;
  String? url; 
  final dynamic webFile; 
  final String? desktopPath;

  MP3File({
    required this.name,
    required this.size,
    this.webFile,
    this.desktopPath,
    this.artwork,
    this.url,
  });
}

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.27+28';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  MP3File? _currentFile;
  
  List<MP3File> _allFiles = [];
  final Set<MP3File> _selectedFiles = {};
  String? _sourcePath;
  String? _destinationPath;
  final List<String> _logs = [];
  
  bool _isLoading = false;
  int _filesProcessed = 0;
  int _totalFiles = 0;

  @override
  void initState() {
    super.initState();
    _log('App started v$appVersion');
    _loadStoredPaths().then((_) {
      if (!kIsWeb && _sourcePath != null) {
        _autoLoadFiles(_sourcePath!);
      }
    });
    
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() { _playerState = state; });
    });
  }

  @override
  void dispose() {
    _cleanupWebUrls();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _cleanupWebUrls() {
    if (kIsWeb) {
      for (var file in _allFiles) {
        if (file.url != null) {
          try { html.Url.revokeObjectUrl(file.url!); } catch (_) {}
        }
      }
    }
  }

  void _log(String message) {
    final logLine = '${DateTime.now()}: $message';
    debugPrint(logLine);
    setState(() { _logs.add(logLine); });
  }

  void _downloadLogs() {
    if (kIsWeb) {
      final content = _logs.join('\n');
      final blob = html.Blob([content], 'text/plain');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', 'error_logs.txt')
        ..click();
      html.Url.revokeObjectUrl(url);
    }
  }

  Future<void> _loadStoredPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() { 
        _sourcePath = prefs.getString('sourcePath');
        _destinationPath = prefs.getString('destinationPath'); 
      });
    } catch (e) { _log('Error loading paths: $e'); }
  }

  Uint8List? _extractArtwork(Uint8List bytes, String fileName) {
    try {
      final id3 = MP3Instance(bytes);
      final meta = id3.getMetaTags();
      if (meta != null) {
        dynamic apicData = meta['APIC'] ?? meta['PIC'];
        if (apicData != null) {
          if (apicData is Map && apicData.containsKey('base64')) return base64Decode(apicData['base64']);
          if (apicData is Uint8List) return apicData;
          if (apicData is List<int>) return Uint8List.fromList(apicData);
        }
      }

      for (int i = 0; i < bytes.length - 10; i++) {
        if (bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF) {
          int end = (i + 500000 > bytes.length) ? bytes.length : i + 500000;
          _log('[$fileName] Recovered artwork via binary scan.');
          return bytes.sublist(i, end);
        }
        if (bytes[i] == 0x89 && bytes[i+1] == 0x50 && bytes[i+2] == 0x4E && bytes[i+3] == 0x47) {
          int end = (i + 500000 > bytes.length) ? bytes.length : i + 500000;
          _log('[$fileName] Recovered PNG artwork via binary scan.');
          return bytes.sublist(i, end);
        }
        if (i > 1000000) break;
      }
      return null;
    } catch (e) {
      _log('Scan error: $e');
      return null;
    }
  }

  Future<void> _autoLoadFiles(String path) async {
    _log('Auto-loading files from: $path');
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return;

      final entities = await dir.list().toList();
      List<MP3File> loadedFiles = [];
      for (var entity in entities) {
        if (entity is File && entity.path.toLowerCase().endsWith('.mp3')) {
          loadedFiles.add(MP3File(
            name: p.basename(entity.path),
            size: await entity.length(),
            desktopPath: entity.path,
          ));
        }
      }

      setState(() {
        _allFiles = loadedFiles;
        _totalFiles = loadedFiles.length;
        _filesProcessed = 0;
        _isLoading = true;
      });

      _processDesktopFiles(loadedFiles);
    } catch (e) { _log('Auto-load failed: $e'); }
  }

  Future<void> _processDesktopFiles(List<MP3File> files) async {
    for (int i = 0; i < files.length; i++) {
      final mp3File = files[i];
      try {
        final file = File(mp3File.desktopPath!);
        final bytes = await file.readAsBytes();
        mp3File.artwork = _extractArtwork(bytes, mp3File.name);
      } catch (e) {
        _log('Meta error for ${mp3File.name}: $e');
      }

      if (i % 5 == 0 || i == files.length - 1) {
        if (mounted) setState(() { _filesProcessed = i + 1; });
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    if (mounted) setState(() { _isLoading = false; });
  }

  Future<void> _pickDestinationDirectory() async {
    if (kIsWeb) return;
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('destinationPath', selectedDirectory);
        setState(() { _destinationPath = selectedDirectory; });
      }
    } catch (e) { _log('Error picking directory: $e'); }
  }

  Future<void> _pickSourceFiles() async {
    if (kIsWeb) {
      final input = html.FileUploadInputElement()..multiple = true..accept = '.mp3';
      input.click();
      input.onChange.listen((event) async {
        final files = input.files;
        if (files == null || files.isEmpty) return;
        _cleanupWebUrls();
        List<MP3File> initialFiles = [];
        for (var file in files) {
          if (file.name.toLowerCase().endsWith('.mp3')) {
            initialFiles.add(MP3File(name: file.name, size: file.size, webFile: file));
          }
        }
        setState(() {
          _allFiles = initialFiles;
          _totalFiles = initialFiles.length;
          _filesProcessed = 0;
          _isLoading = true;
          _sourcePath = 'Web Session';
        });
        _processWebFiles(initialFiles);
      });
    } else {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['mp3'], allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final firstPath = result.files.first.path;
      if (firstPath != null) {
        final dir = p.dirname(firstPath);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('sourcePath', dir);
        setState(() { _sourcePath = dir; });
      }
      List<MP3File> initialFiles = result.files.map((f) => MP3File(name: f.name, size: f.size, desktopPath: f.path)).toList();
      setState(() { _allFiles = initialFiles; _totalFiles = initialFiles.length; _filesProcessed = 0; _isLoading = true; });
      _processDesktopFiles(initialFiles);
    }
  }

  Future<void> _processWebFiles(List<MP3File> files) async {
    for (int i = 0; i < files.length; i++) {
      final mp3File = files[i];
      try {
        final reader = html.FileReader();
        reader.readAsArrayBuffer(mp3File.webFile);
        await reader.onLoadEnd.first;
        final Uint8List bytes = reader.result as Uint8List;
        mp3File.artwork = _extractArtwork(bytes, mp3File.name);
        final blob = html.Blob([bytes]);
        mp3File.url = html.Url.createObjectUrlFromBlob(blob);
      } catch (e) { _log('Error processing ${mp3File.name}: $e'); }
      if (i % 5 == 0 || i == files.length - 1) {
        if (mounted) setState(() { _filesProcessed = i + 1; });
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    if (mounted) setState(() { _isLoading = false; });
  }

  void _handlePlayback(MP3File file) async {
    if (_currentFile == file && _playerState == PlayerState.playing) { await _audioPlayer.pause(); return; }
    if (_currentFile == file && _playerState == PlayerState.paused) { await _audioPlayer.resume(); return; }
    _log('Playing: ${file.name}');
    try {
      setState(() { _currentFile = file; });
      if (kIsWeb && file.url != null) { await _audioPlayer.play(UrlSource(file.url!)); }
      else if (!kIsWeb && file.desktopPath != null) { await _audioPlayer.play(DeviceFileSource(file.desktopPath!)); }
    } catch (e) { _log('PLAYBACK ERROR: $e'); }
  }

  void _toggleSelection(MP3File file) {
    setState(() {
      if (_selectedFiles.contains(file)) { _selectedFiles.remove(file); }
      else { _selectedFiles.add(file); }
    });
  }

  void _copySelectedFiles() {
    if (_selectedFiles.isEmpty) return;
    if (kIsWeb) {
      for (var file in _selectedFiles) {
        final reader = html.FileReader();
        reader.readAsArrayBuffer(file.webFile);
        reader.onLoadEnd.listen((event) {
          final blob = html.Blob([reader.result], 'audio/mpeg');
          final url = html.Url.createObjectUrlFromBlob(blob);
          html.AnchorElement(href: url)..setAttribute('download', file.name)..click();
          html.Url.revokeObjectUrl(url);
        });
      }
    } else {
      if (_destinationPath == null) return;
      for (var file in _selectedFiles) {
        try { File(file.desktopPath!).copySync(p.join(_destinationPath!, file.name)); } catch (e) { _log('Copy failed: $e'); }
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied ${_selectedFiles.length} files.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    String sourceInfo = _sourcePath ?? 'No directory loaded';
    if (!kIsWeb && _sourcePath != null) {
      sourceInfo = '${p.basename(_sourcePath!)} (${_allFiles.length} files)';
    } else if (kIsWeb && _allFiles.isNotEmpty) {
      sourceInfo = 'Web Session (${_allFiles.length} files)';
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SingSong', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('v$appVersion', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          IconButton(icon: const Icon(Icons.description), onPressed: _downloadLogs),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ElevatedButton.icon(onPressed: _pickSourceFiles, icon: const Icon(Icons.library_music), label: const Text('Load MP3s')),
              Text(sourceInfo, style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
            ],
          ),
          if (!kIsWeb) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _pickDestinationDirectory, icon: const Icon(Icons.folder_open), label: Text(_destinationPath == null ? 'Set Dest' : 'Dest: ${p.basename(_destinationPath!)}')),
          ],
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.blue[50],
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.sync, color: Colors.blue),
                      const SizedBox(width: 12),
                      Text('Searching Artwork: $_filesProcessed / $_totalFiles Files (${((_filesProcessed / _totalFiles) * 100).toInt()}%)', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _totalFiles > 0 ? _filesProcessed / _totalFiles : 0, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                ],
              ),
            ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Colors.grey[100],
                    child: _allFiles.isEmpty && !_isLoading
                      ? const Center(child: Text('Click "Load MP3s" to select files.'))
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.75, crossAxisSpacing: 12, mainAxisSpacing: 12),
                          itemCount: _allFiles.length,
                          itemBuilder: (context, index) {
                            final file = _allFiles[index];
                            final isSelected = _selectedFiles.contains(file);
                            final isCurrent = _currentFile == file;
                            final isPlaying = isCurrent && _playerState == PlayerState.playing;
                            return GestureDetector(
                              onTap: () => _toggleSelection(file),
                              child: Card(
                                clipBehavior: Clip.antiAlias,
                                color: isSelected ? Colors.blue[50] : null,
                                shape: RoundedRectangleBorder(side: BorderSide(color: isSelected ? Colors.blue : Colors.transparent, width: 2), borderRadius: BorderRadius.circular(8)),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (file.artwork != null)
                                            Image.memory(file.artwork!, fit: BoxFit.cover)
                                          else
                                            Container(color: Colors.grey[300], child: const Icon(Icons.music_note, size: 48, color: Colors.grey)),
                                          if (isSelected) const Positioned(top: 4, left: 4, child: Icon(Icons.check_circle, color: Colors.blue)),
                                          Positioned(
                                            bottom: 4, right: 4,
                                            child: GestureDetector(
                                              onTap: () => _handlePlayback(file),
                                              child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Colors.white70, shape: BoxShape.circle), child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.blue)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Padding(padding: const EdgeInsets.all(6.0), child: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal))),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Selected (${_selectedFiles.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ElevatedButton.icon(onPressed: _selectedFiles.isNotEmpty ? _copySelectedFiles : null, icon: Icon(kIsWeb ? Icons.download : Icons.copy), label: Text(kIsWeb ? 'Download' : 'Copy Now'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          children: _selectedFiles.map((file) => ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: file.artwork != null 
                                  ? Image.memory(file.artwork!, fit: BoxFit.cover)
                                  : const Icon(Icons.music_note, size: 24, color: Colors.grey),
                            ),
                            title: Text(file.name, style: const TextStyle(fontSize: 11)),
                            trailing: IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => _toggleSelection(file)),
                          )).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
