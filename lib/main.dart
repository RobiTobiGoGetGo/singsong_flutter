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
  String? title;
  String? artist;

  MP3File({
    required this.name,
    required this.size,
    this.webFile,
    this.desktopPath,
    this.artwork,
    this.url,
    this.title,
    this.artist,
  });
}

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.32+33';
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
  int _currentLoadId = 0;

  String _filter = '';
  final TextEditingController _filterController = TextEditingController();

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

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

    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() { _duration = d; });
    });

    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() { _position = p; });
    });

    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) setState(() { 
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _cleanupWebUrls();
    _audioPlayer.dispose();
    _filterController.dispose();
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

  void _extractMetadata(MP3File mp3File, Uint8List bytes) {
    try {
      final id3 = MP3Instance(bytes);
      final meta = id3.getMetaTags();
      if (meta != null) {
        mp3File.title = meta['Title']?.toString();
        mp3File.artist = meta['Artist']?.toString();
        
        dynamic apicData = meta['APIC'] ?? meta['PIC'];
        if (apicData != null) {
          if (apicData is Map && apicData.containsKey('base64')) {
            mp3File.artwork = base64Decode(apicData['base64']);
          } else if (apicData is Uint8List) {
            mp3File.artwork = apicData;
          } else if (apicData is List<int>) {
            mp3File.artwork = Uint8List.fromList(apicData);
          }
        }
      }

      if (mp3File.artwork == null) {
        for (int i = 0; i < bytes.length - 10; i++) {
          if (bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF) {
            int end = (i + 500000 > bytes.length) ? bytes.length : i + 500000;
            mp3File.artwork = bytes.sublist(i, end);
            break;
          }
          if (bytes[i] == 0x89 && bytes[i+1] == 0x50 && bytes[i+2] == 0x4E && bytes[i+3] == 0x47) {
            int end = (i + 500000 > bytes.length) ? bytes.length : i + 500000;
            mp3File.artwork = bytes.sublist(i, end);
            break;
          }
          if (i > 1000000) break;
        }
      }
    } catch (e) { _log('Metadata extraction error: $e'); }
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

      _currentLoadId++;
      setState(() {
        _allFiles = loadedFiles;
        _totalFiles = loadedFiles.length;
        _filesProcessed = 0;
        _isLoading = true;
      });

      _processDesktopFiles(loadedFiles, _currentLoadId);
    } catch (e) { _log('Auto-load failed: $e'); }
  }

  Future<void> _processDesktopFiles(List<MP3File> files, int loadId) async {
    for (int i = 0; i < files.length; i++) {
      if (loadId != _currentLoadId) return;
      final mp3File = files[i];
      try {
        final file = File(mp3File.desktopPath!);
        final bytes = await file.readAsBytes();
        _extractMetadata(mp3File, bytes);
      } catch (e) { _log('Error for ${mp3File.name}: $e'); }

      if (i % 5 == 0 || i == files.length - 1) {
        if (mounted && loadId == _currentLoadId) setState(() { _filesProcessed = i + 1; });
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    if (mounted && loadId == _currentLoadId) setState(() { _isLoading = false; });
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

  Future<void> _handlePickSourceFiles() async {
    if (_isLoading) {
      final bool? reset = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Loading in Progress'),
          content: const Text('The current loading process will be terminated and all file lists will be emptied. Do you want to continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continue current load'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('Reset load MP3'),
            ),
          ],
        ),
      );

      if (reset != true) return;
      
      _currentLoadId++;
      _cleanupWebUrls();
      setState(() {
        _allFiles = [];
        _selectedFiles.clear();
        _filesProcessed = 0;
        _totalFiles = 0;
        _isLoading = false;
        _sourcePath = null;
      });
    }
    _pickSourceFiles();
  }

  Future<void> _pickSourceFiles() async {
    if (kIsWeb) {
      final input = html.FileUploadInputElement()
        ..multiple = true
        ..accept = '.mp3';
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
        _currentLoadId++;
        setState(() {
          _allFiles = initialFiles;
          _totalFiles = initialFiles.length;
          _filesProcessed = 0;
          _isLoading = true;
          _sourcePath = 'Selected Files';
        });
        _processWebFiles(initialFiles, _currentLoadId);
      });
    } else {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      
      final firstPath = result.files.first.path;
      String? folderPath;
      if (firstPath != null) {
        folderPath = p.dirname(firstPath);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('sourcePath', folderPath);
      }
      
      List<MP3File> initialFiles = result.files.map((f) => MP3File(
        name: f.name,
        size: f.size,
        desktopPath: f.path,
      )).toList();
      
      _currentLoadId++;
      setState(() {
        _allFiles = initialFiles;
        _totalFiles = initialFiles.length;
        _filesProcessed = 0;
        _isLoading = true;
        _sourcePath = folderPath;
      });
      _processDesktopFiles(initialFiles, _currentLoadId);
    }
  }

  Future<void> _processWebFiles(List<MP3File> files, int loadId) async {
    for (int i = 0; i < files.length; i++) {
      if (loadId != _currentLoadId) return;
      final mp3File = files[i];
      try {
        final reader = html.FileReader();
        reader.readAsArrayBuffer(mp3File.webFile);
        await reader.onLoadEnd.first;
        final Uint8List bytes = reader.result as Uint8List;
        _extractMetadata(mp3File, bytes);
        final blob = html.Blob([bytes]);
        mp3File.url = html.Url.createObjectUrlFromBlob(blob);
      } catch (e) { _log('Error processing ${mp3File.name}: $e'); }
      if (i % 5 == 0 || i == files.length - 1) {
        if (mounted && loadId == _currentLoadId) setState(() { _filesProcessed = i + 1; });
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    if (mounted && loadId == _currentLoadId) setState(() { _isLoading = false; });
  }

  void _handlePlayback(MP3File file) async {
    if (_currentFile == file) {
      if (_playerState == PlayerState.playing) { 
        await _audioPlayer.pause(); 
      } else if (_playerState == PlayerState.paused) { 
        await _audioPlayer.resume(); 
      } else {
        await _play(file);
      }
      return;
    }
    await _play(file);
  }

  Future<void> _play(MP3File file) async {
    _log('Playing: ${file.name}');
    try {
      setState(() { 
        _currentFile = file; 
        _position = Duration.zero;
        _duration = Duration.zero;
      });
      if (kIsWeb && file.url != null) { 
        await _audioPlayer.play(UrlSource(file.url!)); 
      } else if (!kIsWeb && file.desktopPath != null) { 
        await _audioPlayer.play(DeviceFileSource(file.desktopPath!)); 
      }
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

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    final filteredFiles = _allFiles.where((file) {
      if (_filter.isEmpty) return true;
      final query = _filter.toLowerCase();
      final nameMatch = file.name.toLowerCase().contains(query);
      final titleMatch = file.title?.toLowerCase().contains(query) ?? false;
      final artistMatch = file.artist?.toLowerCase().contains(query) ?? false;
      return nameMatch || titleMatch || artistMatch;
    }).toList();

    String sourceInfo = _sourcePath != null 
        ? '${kIsWeb ? _sourcePath : p.basename(_sourcePath!)} (${_allFiles.length} files)'
        : 'No files loaded';

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
              ElevatedButton.icon(onPressed: _handlePickSourceFiles, icon: const Icon(Icons.library_music), label: const Text('Load MP3s')),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _filterController,
              decoration: InputDecoration(
                hintText: 'Filter by name, title, or performer...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.isNotEmpty 
                  ? IconButton(icon: const Icon(Icons.clear), onPressed: () {
                      _filterController.clear();
                      setState(() { _filter = ''; });
                    })
                  : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (value) => setState(() { _filter = value; }),
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
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.7, crossAxisSpacing: 12, mainAxisSpacing: 12),
                          itemCount: filteredFiles.length,
                          itemBuilder: (context, index) {
                            final file = filteredFiles[index];
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
                                    Padding(
                                      padding: const EdgeInsets.all(6.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(file.title ?? file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                                          if (file.artist != null) Text(file.artist!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
                            title: Text(file.title ?? file.name, style: const TextStyle(fontSize: 11)),
                            subtitle: file.artist != null ? Text(file.artist!, style: const TextStyle(fontSize: 10)) : null,
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
          if (_currentFile != null) _buildPlayerBar(),
        ],
      ),
    );
  }

  Widget _buildPlayerBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, -2))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.grey[300],
                ),
                clipBehavior: Clip.antiAlias,
                child: _currentFile?.artwork != null 
                    ? Image.memory(_currentFile!.artwork!, fit: BoxFit.cover)
                    : const Icon(Icons.music_note, color: Colors.grey),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_currentFile?.title ?? _currentFile?.name ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(_currentFile?.artist ?? 'Unknown Artist', style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(_playerState == PlayerState.playing ? Icons.pause : Icons.play_arrow),
                onPressed: () => _handlePlayback(_currentFile!),
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                onPressed: () async {
                  await _audioPlayer.stop();
                  setState(() { 
                    _playerState = PlayerState.stopped;
                    _position = Duration.zero;
                  });
                },
              ),
            ],
          ),
          Row(
            children: [
              Text(_formatDuration(_position), style: const TextStyle(fontSize: 10)),
              Expanded(
                child: Slider(
                  value: _position.inMilliseconds.toDouble(),
                  max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                  onChanged: (val) {
                    _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                  },
                ),
              ),
              Text(_formatDuration(_duration), style: const TextStyle(fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}
