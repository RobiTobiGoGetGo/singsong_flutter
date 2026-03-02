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
  static const String appVersion = '1.0.16+17';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  MP3File? _currentFile;
  
  List<MP3File> _allFiles = [];
  final Set<MP3File> _selectedFiles = {};
  final List<String> _logs = [];
  
  bool _isLoading = false;
  int _filesProcessed = 0;
  int _totalFiles = 0;

  @override
  void initState() {
    super.initState();
    _log('App started v$appVersion');
    
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
      });

      _log('PHASE 1 Complete: ${initialFiles.length} names added.');

      // CRITICAL: Delay to allow UI to render the grid of names before starting background work
      await Future.delayed(const Duration(milliseconds: 300));

      // PHASE 2: Background Artwork extraction
      _processFiles(initialFiles);

    } catch (e) {
      _log('CRITICAL ERROR during selection: $e');
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _processFiles(List<MP3File> files) async {
    for (int i = 0; i < files.length; i++) {
      final file = files[i];
      try {
        if (file.rawFile.bytes != null) {
          // Extract Artwork
          final mp3 = MP3Instance(file.rawFile.bytes!);
          final meta = mp3.getMetaTags();
          if (meta != null && meta.containsKey('APIC')) {
            final apic = meta['APIC'];
            if (apic is Uint8List) {
              file.artwork = apic;
            } else if (apic is List<int>) {
              file.artwork = Uint8List.fromList(apic);
            }
          }

          // Create Playback URL
          if (kIsWeb) {
            final blob = html.Blob([file.rawFile.bytes!]);
            file.url = html.Url.createObjectUrlFromBlob(blob);
          }
        }
      } catch (e) {
        _log('Error processing ${file.name}: $e');
      }

      // Update progress every 10 files or at the end
      if (i % 10 == 0 || i == files.length - 1) {
        setState(() { _filesProcessed = i + 1; });
        // Yield to allow browser to repaint icons
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    setState(() { _isLoading = false; });
    _log('PHASE 2 Complete: All files processed.');
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
        // Safe access to path ONLY on non-web
        String? path;
        try { path = file.rawFile.path; } catch (_) {}
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
            const Text('SingSong', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('v$appVersion', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          IconButton(icon: const Icon(Icons.description), tooltip: 'Logs', onPressed: _downloadLogs),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _pickSourceFiles,
            icon: const Icon(Icons.library_music),
            label: const Text('Load MP3s'),
          ),
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
                      Text(
                        'Processing Artwork: $_filesProcessed / $_totalFiles Files (${((_filesProcessed / _totalFiles) * 100).toInt()}%)',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _totalFiles > 0 ? _filesProcessed / _totalFiles : 0,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Container(
                    color: Colors.grey[100],
                    child: _allFiles.isEmpty && !_isLoading
                      ? const Center(child: Text('Click "Load MP3s" to select files.'))
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
                        child: Text('To Be Copied (${_selectedFiles.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
          ),
        ],
      ),
    );
  }
}
