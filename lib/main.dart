import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb;
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

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.7+8';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  PlatformFile? _currentFile;
  
  List<PlatformFile> _allFiles = [];
  final Set<PlatformFile> _selectedFiles = {};
  String? _sourcePath;
  String? _destinationPath;
  final List<String> _logs = [];
  String? _currentWebUrl;

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
    _cleanupWebUrl();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _cleanupWebUrl() {
    if (_currentWebUrl != null) {
      html.Url.revokeObjectUrl(_currentWebUrl!);
      _currentWebUrl = null;
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
    _log('Attempting to pick files...');
    try {
      setState(() {
        _allFiles = [];
      });

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
        withData: true, 
      );

      if (result != null && result.files.isNotEmpty) {
        final mp3Files = result.files.where((file) {
          final name = file.name.toLowerCase();
          return name.endsWith('.mp3');
        }).toList();
        
        _log('Selected ${result.files.length} total files. Found ${mp3Files.length} MP3s.');

        setState(() {
          _allFiles = mp3Files;
          if (!kIsWeb && result.files.first.path != null) {
            _savePath('sourcePath', p.dirname(result.files.first.path!));
          } else if (kIsWeb) {
            _sourcePath = 'Web Session';
          }
        });

        if (mp3Files.isEmpty) {
           ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Selected ${result.files.length} files, but none were recognized as .mp3')),
          );
        }
      } else {
        _log('File picker cancelled or no files selected.');
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

  void _handlePlayback(PlatformFile file) async {
    if (_currentFile == file && _playerState == PlayerState.playing) {
      await _audioPlayer.pause();
      return;
    }
    
    if (_currentFile == file && _playerState == PlayerState.paused) {
      await _audioPlayer.resume();
      return;
    }

    // New file or stopped
    _log('Attempting to play: ${file.name} (Size: ${file.size} bytes)');
    try {
      setState(() {
        _currentFile = file;
      });
      
      if (kIsWeb && file.bytes != null) {
        _log('Playing via Blob URL (Web fix)...');
        _cleanupWebUrl();
        final blob = html.Blob([file.bytes!]);
        _currentWebUrl = html.Url.createObjectUrlFromBlob(blob);
        await _audioPlayer.play(UrlSource(_currentWebUrl!));
      } else if (file.bytes != null) {
        _log('Playing from bytes...');
        await _audioPlayer.play(BytesSource(file.bytes!));
      } else if (file.path != null) {
        _log('Playing from path: ${file.path}');
        await _audioPlayer.play(DeviceFileSource(file.path!));
      } else {
        throw 'No file data (bytes or path) available.';
      }
    } catch (e) {
      _log('PLAYBACK ERROR for ${file.name}: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing file: $e')),
      );
    }
  }

  void _stopPlayback() async {
    await _audioPlayer.stop();
  }

  void _toggleSelection(PlatformFile file) {
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
              color: Colors.grey[50],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('Source Library', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  if (_allFiles.isEmpty)
                    const Expanded(child: Center(child: Text('No MP3 files loaded. Click "Load MP3s" and select multiple files.')))
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: _allFiles.length,
                        separatorBuilder: (context, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final file = _allFiles[index];
                          final isSelected = _selectedFiles.contains(file);
                          final isCurrent = _currentFile == file;
                          final isPlaying = isCurrent && _playerState == PlayerState.playing;
                          
                          return ListTile(
                            leading: Checkbox(
                              value: isSelected,
                              onChanged: (_) => _toggleSelection(file),
                            ),
                            title: Text(file.name, style: TextStyle(fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal, color: isCurrent ? Colors.blue : null)),
                            subtitle: Text('${(file.size / 1024 / 1024).toStringAsFixed(2)} MB'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isCurrent && _playerState != PlayerState.stopped)
                                  IconButton(
                                    icon: const Icon(Icons.stop_circle, color: Colors.red),
                                    onPressed: _stopPlayback,
                                  ),
                                IconButton(
                                  icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.blue, size: 32),
                                  onPressed: () => _handlePlayback(file),
                                ),
                              ],
                            ),
                            onTap: () => _toggleSelection(file),
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
                    const Expanded(child: Center(child: Text('Select files from the left to add them here.')))
                  else
                    Expanded(
                      child: ListView(
                        children: _selectedFiles.map((file) => ListTile(
                          leading: const Icon(Icons.audiotrack, color: Colors.orange),
                          title: Text(file.name, style: const TextStyle(fontSize: 14)),
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
