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
  final Uint8List? artwork;
  final String? url; // Blob URL for web playback
  final String? path; // File path for desktop playback

  MP3File({
    required this.name,
    required this.size,
    this.artwork,
    this.url,
    this.path,
  });
}

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.9+10';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  MP3File? _currentFile;
  
  List<MP3File> _allFiles = [];
  final Set<MP3File> _selectedFiles = {};
  String? _sourcePath;
  String? _destinationPath;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _log('App started v$appVersion');
    _loadStoredPaths();
    
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playerState = state;
        });
      }
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
          html.Url.revokeObjectUrl(file.url!);
        }
      }
    }
  }

  void _log(String message) {
    final logLine = '${DateTime.now()}: $message';
    debugPrint(logLine);
    setState(() {
      _logs.add(logLine);
    });
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
      _log('Loaded paths: source=$_sourcePath, dest=$_destinationPath');
    } catch (e) {
      _log('Error loading paths: $e');
    }
  }

  Future<void> _savePath(String key, String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, path);
      setState(() {
        if (key == 'sourcePath') {
          _sourcePath = path;
        } else {
          _destinationPath = path;
        }
      });
      _log('Saved path: $key=$path');
    } catch (e) {
      _log('Error saving path $key: $e');
    }
  }

  Future<void> _pickSourceFiles() async {
    _log('Attempting to pick files with artwork extraction...');
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
        withData: true, 
      );

      if (result != null && result.files.isNotEmpty) {
        _cleanupWebUrls();
        List<MP3File> loadedFiles = [];
        
        for (var file in result.files) {
          if (!file.name.toLowerCase().endsWith('.mp3')) continue;

          Uint8List? artwork;
          String? url;

          if (file.bytes != null) {
            // Extract Artwork using ID3 1.0.2
            try {
              // Version 1.0.2 parses automatically on instantiation.
              MP3Instance mp3 = MP3Instance(file.bytes!);
              final meta = mp3.getMetaTags();
              if (meta != null && meta.containsKey('APIC')) {
                final apic = meta['APIC'];
                if (apic is Uint8List) {
                  artwork = apic;
                } else if (apic is List<int>) {
                  artwork = Uint8List.fromList(apic);
                }
              }
            } catch (e) {
              _log('Metadata extraction failed for ${file.name}: $e');
            }

            if (kIsWeb) {
              final blob = html.Blob([file.bytes!]);
              url = html.Url.createObjectUrlFromBlob(blob);
            }
          }

          loadedFiles.add(MP3File(
            name: file.name,
            size: file.size,
            artwork: artwork,
            url: url,
            path: file.path,
          ));
        }

        setState(() {
          _allFiles = loadedFiles;
          if (!kIsWeb && result.files.first.path != null) {
            _savePath('sourcePath', p.dirname(result.files.first.path!));
          } else if (kIsWeb) {
            _sourcePath = 'Web Session';
          }
        });

        _log('Loaded ${loadedFiles.length} MP3 files with artwork.');
      }
    } catch (e) {
      _log('CRITICAL ERROR picking files: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking files: $e')),
      );
    }
  }

  Future<void> _pickDestinationDirectory() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Directory picking is not supported on Web.')),
      );
      return;
    }
    
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        _savePath('destinationPath', selectedDirectory);
      }
    } catch (e) {
      _log('Error picking directory: $e');
    }
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
      setState(() {
        _currentFile = file;
      });
      
      if (kIsWeb && file.url != null) {
        await _audioPlayer.play(UrlSource(file.url!));
      } else if (file.path != null) {
        await _audioPlayer.play(DeviceFileSource(file.path!));
      } else {
        throw 'No playback source available.';
      }
    } catch (e) {
      _log('PLAYBACK ERROR: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing file: $e')),
      );
    }
  }

  void _stopPlayback() async {
    await _audioPlayer.stop();
  }

  void _toggleSelection(MP3File file) {
    setState(() {
      if (_selectedFiles.contains(file)) {
        _selectedFiles.remove(file);
      } else {
        _selectedFiles.add(file);
      }
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
            if (_sourcePath != null)
              Text('Source: ${_sourcePath == "Web Session" ? _sourcePath : p.basename(_sourcePath!)}', 
                   style: const TextStyle(fontSize: 10)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.description),
            tooltip: 'Download Error Logs',
            onPressed: _downloadLogs,
          ),
          Center(child: Text('v$appVersion', style: const TextStyle(fontSize: 12, color: Colors.grey))),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _pickSourceFiles,
            icon: const Icon(Icons.library_music),
            label: const Text('Load MP3s'),
          ),
          const VerticalDivider(),
          TextButton.icon(
            onPressed: _pickDestinationDirectory,
            icon: const Icon(Icons.folder_special),
            label: Text(kIsWeb ? 'Web Mode' : (_destinationPath == null ? 'Set Destination' : 'Dest: ${p.basename(_destinationPath!)}')),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.grey[100],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('Source Library (Extra Large Symbols)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  if (_allFiles.isEmpty)
                    const Expanded(child: Center(child: Text('No MP3 files loaded. Click "Load MP3s".')))
                  else
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          childAspectRatio: 0.8,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
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
                                side: BorderSide(
                                  color: isSelected ? Colors.blue : Colors.transparent,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: isSelected ? 4 : 1,
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
                                            child: const Icon(Icons.music_note, size: 64, color: Colors.grey),
                                          ),
                                        if (isSelected)
                                          Positioned(
                                            top: 4,
                                            left: 4,
                                            child: Icon(Icons.check_circle, color: Colors.blue[700]),
                                          ),
                                        Positioned(
                                          bottom: 4,
                                          right: 4,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (isCurrent && _playerState != PlayerState.stopped)
                                                GestureDetector(
                                                  onTap: _stopPlayback,
                                                  child: Container(
                                                    padding: const EdgeInsets.all(4),
                                                    decoration: const BoxDecoration(color: Colors.white70, shape: BoxShape.circle),
                                                    child: const Icon(Icons.stop, color: Colors.red, size: 20),
                                                  ),
                                                ),
                                              const SizedBox(width: 4),
                                              GestureDetector(
                                                onTap: () => _handlePlayback(file),
                                                child: Container(
                                                  padding: const EdgeInsets.all(4),
                                                  decoration: const BoxDecoration(color: Colors.white70, shape: BoxShape.circle),
                                                  child: Icon(
                                                    isPlaying ? Icons.pause : Icons.play_arrow,
                                                    color: Colors.blue,
                                                    size: 24,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          file.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                            color: isCurrent ? Colors.blue : null,
                                          ),
                                        ),
                                        Text(
                                          '${(file.size / 1024 / 1024).toStringAsFixed(1)} MB',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('To Be Copied', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        Chip(label: Text('${_selectedFiles.length}')),
                      ],
                    ),
                  ),
                  if (_selectedFiles.isEmpty)
                    const Expanded(child: Center(child: Text('Select files from the left.')))
                  else
                    Expanded(
                      child: ListView(
                        children: _selectedFiles.map((file) => ListTile(
                          leading: file.artwork != null 
                              ? Image.memory(file.artwork!, width: 40, height: 40, fit: BoxFit.cover)
                              : const Icon(Icons.audiotrack, color: Colors.orange),
                          title: Text(file.name, style: const TextStyle(fontSize: 12)),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => _toggleSelection(file),
                          ),
                        )).toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
