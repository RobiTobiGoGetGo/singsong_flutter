import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:id3/id3.dart';
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
  final PlatformFile rawFile;

  MP3File({
    required this.name,
    required this.size,
    required this.rawFile,
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
  static const String appVersion = '1.0.15+16';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  MP3File? _currentFile;
  
  List<MP3File> _allFiles = [];
  final Set<MP3File> _selectedFiles = {};
  String? _sourcePath;
  final List<String> _logs = [];
  
  bool _isLoading = false;
  int _filesProcessed = 0;
  int _totalFiles = 0;

  @override
  void initState() {
    super.initState();
    _log('App started v$appVersion');
    _loadStoredPaths();
    
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
        if (file.url != null) html.Url.revokeObjectUrl(file.url!);
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
      setState(() { _sourcePath = prefs.getString('sourcePath'); });
    } catch (e) { _log('Error loading paths: $e'); }
  }

  Future<void> _pickSourceFiles() async {
    _log('Picking files...');
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
        withData: true, 
      );

      if (result == null || result.files.isEmpty) return;

      _cleanupWebUrls();
      
      // PHASE 1: Add filenames immediately
      List<MP3File> initialFiles = [];
      for (var file in result.files) {
        if (file.name.toLowerCase().endsWith('.mp3')) {
          initialFiles.add(MP3File(
            name: file.name,
            size: file.size,
            rawFile: file,
          ));
        }
      }

      setState(() {
        _allFiles = initialFiles;
        _totalFiles = initialFiles.length;
        _filesProcessed = 0;
        _isLoading = true;
        _sourcePath = kIsWeb ? 'Web Session' : 'Local Drive';
      });

      _log('Added ${initialFiles.length} names to grid. Starting background extraction...');

      // Give a tiny delay so the UI shows the names before processing images
      await Future.delayed(const Duration(milliseconds: 100));

      // PHASE 2: Process in background
      _extractArtworkInBackground();

    } catch (e) {
      _log('CRITICAL ERROR picking files: $e');
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _extractArtworkInBackground() async {
    for (int i = 0; i < _allFiles.length; i++) {
      final file = _allFiles[i];
      try {
        if (file.rawFile.bytes != null) {
          MP3Instance mp3 = MP3Instance(file.rawFile.bytes!);
          final meta = mp3.getMetaTags();
          if (meta != null && meta.containsKey('APIC')) {
            final apic = meta['APIC'];
            if (apic is Uint8List) {
              file.artwork = apic;
            } else if (apic is List<int>) {
              file.artwork = Uint8List.fromList(apic);
            }
          }

          if (kIsWeb) {
            final blob = html.Blob([file.rawFile.bytes!]);
            file.url = html.Url.createObjectUrlFromBlob(blob);
          }
        }
      } catch (e) {
        _log('Meta error for ${file.name}: $e');
      }

      if (i % 10 == 0 || i == _allFiles.length - 1) {
        setState(() { _filesProcessed = i + 1; });
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    setState(() { _isLoading = false; });
  }

  void _handlePlayback(MP3File file) async {
    if (_currentFile == file && _playerState == PlayerState.playing) {
      await _audioPlayer.pause();
      return;
    }
    if (_currentFile == file && _playerState == PlayerState.paused) {
      await _audioPlayer.resume();
      return;
    }

    _log('Playing: ${file.name}');
    try {
      setState(() { _currentFile = file; });
      if (kIsWeb && file.url != null) {
        await _audioPlayer.play(UrlSource(file.url!));
      } else if (!kIsWeb) {
        final path = file.rawFile.path;
        if (path != null) {
          await _audioPlayer.play(DeviceFileSource(path));
        } else if (file.rawFile.bytes != null) {
          await _audioPlayer.play(BytesSource(file.rawFile.bytes!));
        }
      } else if (file.rawFile.bytes != null) {
        await _audioPlayer.play(BytesSource(file.rawFile.bytes!));
      }
    } catch (e) { _log('PLAYBACK ERROR: $e'); }
  }

  void _toggleSelection(MP3File file) {
    setState(() {
      if (_selectedFiles.contains(file)) { _selectedFiles.remove(file); }
      else { _selectedFiles.add(file); }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SingSong'),
            Text('v$appVersion', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          if (_isLoading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${((_filesProcessed / _totalFiles) * 100).toInt()}% Loaded (${_filesProcessed}/${_totalFiles})',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                ),
              ),
            ),
          IconButton(icon: const Icon(Icons.description), onPressed: _downloadLogs),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _pickSourceFiles,
            icon: const Icon(Icons.library_music),
            label: const Text('Load MP3s'),
          ),
          const SizedBox(width: 16),
        ],
        bottom: _isLoading ? PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _filesProcessed / _totalFiles,
            color: Colors.blue,
            backgroundColor: Colors.white,
          ),
        ) : null,
      ),
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.grey[100],
              child: _allFiles.isEmpty && !_isLoading
                ? const Center(child: Text('Click "Load MP3s" to start.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 0.75,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
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
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: isSelected ? Colors.blue : Colors.transparent, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
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
                                      Container(
                                        color: Colors.grey[300],
                                        child: const Icon(Icons.music_note, size: 48, color: Colors.grey),
                                      ),
                                    if (isSelected)
                                      const Positioned(top: 4, left: 4, child: Icon(Icons.check_circle, color: Colors.blue)),
                                    Positioned(
                                      bottom: 4,
                                      right: 4,
                                      child: GestureDetector(
                                        onTap: () => _handlePlayback(file),
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: const BoxDecoration(color: Colors.white70, shape: BoxShape.circle),
                                          child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.blue),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(6.0),
                                child: Text(
                                  file.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal),
                                ),
                              ),
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
                  child: Text('Selected: ${_selectedFiles.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: ListView(
                    children: _selectedFiles.map((file) => ListTile(
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
    );
  }
}
