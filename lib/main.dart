import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:id3/id3.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          elevation: 0,
        ),
        textTheme: const TextTheme(
          titleMedium: TextStyle(fontFamily: 'sans-serif', fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontFamily: 'sans-serif', fontWeight: FontWeight.w300),
        ),
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
  static const String appVersion = '1.0.40+41';
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
  final FocusNode _filterFocusNode = FocusNode();
  List<String> _filterHistory = [];

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
    _filterFocusNode.dispose();
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
        _filterHistory = prefs.getStringList('filterHistory') ?? [];
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
    if (_filter.trim().isNotEmpty) {
      _onFilterSubmitted(_filter);
    }
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

  void _onFilterSubmitted(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    
    setState(() {
      _filterHistory.remove(trimmed);
      _filterHistory.insert(0, trimmed);
      if (_filterHistory.length > 20) _filterHistory.removeLast();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('filterHistory', _filterHistory);
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
        title: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SingSong', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan, fontSize: 18)),
                Text('v$appVersion', style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return RawAutocomplete<String>(
                        textEditingController: _filterController,
                        focusNode: _filterFocusNode,
                        optionsBuilder: (TextEditingValue textEditingValue) {
                          if (textEditingValue.text.isEmpty) return _filterHistory;
                          return _filterHistory.where((String option) => option.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                        },
                        onSelected: (String selection) {
                          setState(() { _filter = selection; });
                          _onFilterSubmitted(selection);
                        },
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Filter music...',
                              prefixIcon: const Icon(Icons.search, color: Colors.cyan, size: 20),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_filter.isNotEmpty) 
                                    IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () { controller.clear(); setState(() { _filter = ''; }); }),
                                  const Icon(Icons.arrow_drop_down, color: Colors.grey, size: 20),
                                  const SizedBox(width: 8),
                                ],
                              ),
                              filled: true,
                              fillColor: Colors.black26,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(vertical: 0),
                            ),
                            onChanged: (value) => setState(() { _filter = value; }),
                            onSubmitted: (value) { _onFilterSubmitted(value); onFieldSubmitted(); },
                          );
                        },
                        optionsViewBuilder: (context, onSelected, options) {
                          return Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              elevation: 8.0,
                              borderRadius: BorderRadius.circular(12),
                              color: const Color(0xFF2A2A2A),
                              child: Container(
                                width: constraints.maxWidth,
                                constraints: const BoxConstraints(maxHeight: 250),
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: options.length,
                                  itemBuilder: (BuildContext context, int index) {
                                    final String option = options.elementAt(index);
                                    return ListTile(
                                      title: Text(option, style: const TextStyle(fontSize: 13)),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                                        onPressed: () async {
                                          setState(() { _filterHistory.remove(option); });
                                          final prefs = await SharedPreferences.getInstance();
                                          await prefs.setStringList('filterHistory', _filterHistory);
                                        },
                                      ),
                                      onTap: () => onSelected(option),
                                    );
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    }
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'load') _handlePickSourceFiles();
              if (value == 'dest') _pickDestinationDirectory();
              if (value == 'logs') _downloadLogs();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'load', child: ListTile(leading: Icon(Icons.library_music_outlined, size: 20), title: Text('Load MP3s', style: TextStyle(fontSize: 14)), dense: true)),
              if (!kIsWeb) const PopupMenuItem(value: 'dest', child: ListTile(leading: Icon(Icons.folder_outlined, size: 20), title: Text('Set Destination', style: TextStyle(fontSize: 14)), dense: true)),
              const PopupMenuItem(value: 'logs', child: ListTile(leading: Icon(Icons.description_outlined, size: 20), title: Text('Download Logs', style: TextStyle(fontSize: 14)), dense: true)),
              PopupMenuItem(enabled: false, child: Text(sourceInfo, style: const TextStyle(fontSize: 11, color: Colors.grey))),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_isLoading)
                LinearProgressIndicator(
                  value: _totalFiles > 0 ? _filesProcessed / _totalFiles : 0,
                  minHeight: 2,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyan),
                ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: Container(
                        color: const Color(0xFF121212),
                        child: _allFiles.isEmpty && !_isLoading
                          ? const Center(child: Text('Open the menu to load MP3s.', style: TextStyle(color: Colors.grey)))
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.7, crossAxisSpacing: 12, mainAxisSpacing: 12),
                              itemCount: filteredFiles.length,
                              itemBuilder: (context, index) {
                                final file = filteredFiles[index];
                                final isSelected = _selectedFiles.contains(file);
                                final isCurrent = _currentFile == file;
                                final isPlaying = isCurrent && _playerState == PlayerState.playing;
                                
                                return MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _toggleSelection(file),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: BackdropFilter(
                                        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: isSelected ? Colors.cyan.withOpacity(0.15) : Colors.white.withOpacity(0.05),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(
                                              color: isSelected ? Colors.cyan.withOpacity(0.5) : Colors.white.withOpacity(0.1),
                                              width: 1.5,
                                            ),
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
                                                        decoration: BoxDecoration(
                                                          gradient: LinearGradient(
                                                            begin: Alignment.topLeft,
                                                            end: Alignment.bottomRight,
                                                            colors: [Colors.grey[800]!, Colors.grey[900]!],
                                                          ),
                                                        ),
                                                        child: const Icon(Icons.music_note, size: 48, color: Colors.white10)
                                                      ),
                                                    if (isSelected) const Positioned(top: 8, left: 8, child: Icon(Icons.check_circle, color: Colors.cyan, size: 22)),
                                                    Positioned(
                                                      bottom: 8, right: 8,
                                                      child: GestureDetector(
                                                        onTap: () => _handlePlayback(file),
                                                        child: Container(
                                                          padding: const EdgeInsets.all(8), 
                                                          decoration: BoxDecoration(
                                                            color: Colors.cyan, 
                                                            shape: BoxShape.circle,
                                                            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: const Offset(0, 2))]
                                                          ), 
                                                          child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 20)
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(10.0),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      file.title ?? file.name, 
                                                      maxLines: 1, 
                                                      overflow: TextOverflow.ellipsis, 
                                                      style: const TextStyle(
                                                        fontSize: 12, 
                                                        fontWeight: FontWeight.w600, 
                                                        color: Colors.white,
                                                        fontFamily: 'Montserrat',
                                                      ).copyWith(color: isCurrent ? Colors.cyan : Colors.white.withOpacity(0.9), fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600)
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      file.artist ?? 'Unknown Artist', 
                                                      maxLines: 1, 
                                                      overflow: TextOverflow.ellipsis, 
                                                      style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.w300, fontFamily: 'Montserrat')
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                      ),
                    ),
                    const VerticalDivider(width: 1, color: Colors.white10),
                    Expanded(
                      flex: 1,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Selected', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                Text('(${_selectedFiles.length})', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                const Spacer(),
                                ElevatedButton.icon(
                                  onPressed: _selectedFiles.isNotEmpty ? _copySelectedFiles : null, 
                                  icon: Icon(kIsWeb ? Icons.download : Icons.copy, size: 18), 
                                  label: Text(kIsWeb ? 'Download' : 'Copy Now'), 
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black, elevation: 0)
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.only(bottom: 100),
                              children: _selectedFiles.map((file) => ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[900],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: file.artwork != null 
                                      ? Image.memory(file.artwork!, fit: BoxFit.cover)
                                      : const Icon(Icons.music_note, size: 20, color: Colors.white10),
                                ),
                                title: Text(file.title ?? file.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'Montserrat'), maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(file.artist ?? 'Unknown Artist', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w300, fontFamily: 'Montserrat', color: Colors.grey)),
                                trailing: IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.grey), onPressed: () => _toggleSelection(file)),
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
          if (_currentFile != null) 
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: _buildFloatingPlayer(),
            ),
        ],
      ),
    );
  }

  Widget _buildFloatingPlayer() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F).withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white10, width: 1),
            boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tiny seek bar at the very top
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: SliderComponentShape.noThumb,
                  overlayShape: SliderComponentShape.noOverlay,
                  activeTrackColor: Colors.cyan,
                  inactiveTrackColor: Colors.white10,
                  trackShape: const RectangularSliderTrackShape(),
                ),
                child: Slider(
                  value: _position.inMilliseconds.toDouble(),
                  max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                  onChanged: (val) {
                    _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey[900],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _currentFile?.artwork != null 
                          ? Image.memory(_currentFile!.artwork!, fit: BoxFit.cover)
                          : const Icon(Icons.music_note, color: Colors.white10),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_currentFile?.title ?? _currentFile?.name ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white, fontFamily: 'Montserrat'), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text('${_formatDuration(_position)} / ${_formatDuration(_duration)}', style: const TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.w300, fontFamily: 'Montserrat')),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(_playerState == PlayerState.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32, color: Colors.cyan),
                      onPressed: () => _handlePlayback(_currentFile!),
                    ),
                    IconButton(
                      icon: const Icon(Icons.stop_rounded, size: 24, color: Colors.grey),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
