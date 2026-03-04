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
          titleMedium: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w300),
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

  // Convert to JSON for persistence
  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'title': title,
    'artist': artist,
    'desktopPath': desktopPath,
    'artwork': artwork != null ? base64Encode(artwork!) : null,
  };

  // Create from JSON
  factory MP3File.fromJson(Map<String, dynamic> json) => MP3File(
    name: json['name'],
    size: json['size'],
    title: json['title'],
    artist: json['artist'],
    desktopPath: json['desktopPath'],
    artwork: json['artwork'] != null ? base64Decode(json['artwork']) : null,
  );

  // Display Logic: Artist Group
  String get displayArtist {
    return artist?.trim().isNotEmpty == true ? artist! : 'Unknown Artist';
  }

  // Display Logic: Title Group
  String get displayTitle {
    return title?.trim().isNotEmpty == true ? title! : name;
  }
}

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.46+47';
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

  bool _isEasyMode = false;

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
      } else if (kIsWeb) {
        _loadWebCache();
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
        _isEasyMode = prefs.getBool('easyMode') ?? false;
      });
    } catch (e) { _log('Error loading paths: $e'); }
  }

  Future<void> _loadWebCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('webCache');
      if (cached != null) {
        final List<dynamic> decoded = jsonDecode(cached);
        setState(() {
          _allFiles = decoded.map((item) => MP3File.fromJson(item)).toList();
          _sourcePath = 'Web Cache (Grant access to play)';
        });
        _log('Loaded ${_allFiles.length} files from web cache.');
      }
    } catch (e) { _log('Error loading web cache: $e'); }
  }

  Future<void> _saveWebCache() async {
    if (!kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_allFiles.map((f) => f.toJson()).toList());
      await prefs.setString('webCache', json);
      _log('Saved ${_allFiles.length} files to web cache.');
    } catch (e) { _log('Error saving web cache: $e'); }
  }

  void _extractMetadata(MP3File mp3File, Uint8List bytes) {
    try {
      final id3 = MP3Instance(bytes);
      id3.parseTagsSync();
      final meta = id3.getMetaTags();
      if (meta != null) {
        _log('--- DEBUG: RAW METADATA for ${mp3File.name} ---');
        meta.forEach((key, value) {
          if (key != 'APIC' && key != 'PIC') {
            _log('  $key: $value');
          }
        });

        mp3File.title = meta['Title']?.toString() ?? meta['title']?.toString();
        mp3File.artist = meta['Artist']?.toString() ?? meta['artist']?.toString();
        
        _log('Captured: Title=${mp3File.title}, Artist=${mp3File.artist}');

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
      } else {
        _log('DEBUG: No metadata found for ${mp3File.name}');
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
    if (mounted && loadId == _currentLoadId) {
      setState(() { _isLoading = false; });
      _saveWebCache();
    }
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
    if (kIsWeb && file.webFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please reload files to grant playback access.')));
      return;
    }
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

  Future<void> _toggleEasyMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isEasyMode = !_isEasyMode;
      prefs.setBool('easyMode', _isEasyMode);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _isEasyMode ? 1.4 : 1.0;
    
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
        toolbarHeight: 64 * scale,
        title: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('SingSong', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan, fontSize: 18 * scale, fontFamily: 'Montserrat')),
                if (!_isEasyMode) Text('v$appVersion', style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'Montserrat', fontWeight: FontWeight.w300)),
              ],
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 500 * scale),
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
                            style: TextStyle(fontSize: 14 * scale, fontFamily: 'Montserrat'),
                            decoration: InputDecoration(
                              hintText: _isEasyMode ? 'Search' : 'Filter music...',
                              prefixIcon: Icon(Icons.search, color: Colors.cyan, size: 20 * scale),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_filter.isNotEmpty) 
                                    IconButton(icon: Icon(Icons.clear, size: 16 * scale), onPressed: () { controller.clear(); setState(() { _filter = ''; }); }),
                                  Icon(Icons.arrow_drop_down, color: Colors.grey, size: 20 * scale),
                                  const SizedBox(width: 8),
                                ],
                              ),
                              filled: true,
                              fillColor: Colors.black26,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20 * scale), borderSide: BorderSide.none),
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
                                constraints: BoxConstraints(maxHeight: 250 * scale),
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: options.length,
                                  itemBuilder: (BuildContext context, int index) {
                                    final String option = options.elementAt(index);
                                    return ListTile(
                                      title: Text(option, style: TextStyle(fontSize: 13 * scale, fontFamily: 'Montserrat')),
                                      trailing: IconButton(
                                        icon: Icon(Icons.close, size: 16 * scale, color: Colors.grey),
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
          IconButton(
            icon: Icon(_isEasyMode ? Icons.zoom_in : Icons.zoom_out, color: _isEasyMode ? Colors.cyan : Colors.grey, size: 24 * scale),
            onPressed: _toggleEasyMode,
            tooltip: 'Toggle Easy Mode',
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 24 * scale),
            onSelected: (value) {
              if (value == 'load') _handlePickSourceFiles();
              if (value == 'dest') _pickDestinationDirectory();
              if (value == 'logs') _downloadLogs();
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'load', child: ListTile(leading: Icon(Icons.library_music_outlined, size: 20 * scale), title: Text(_isEasyMode ? 'Load' : 'Load MP3s', style: TextStyle(fontSize: 14 * scale, fontFamily: 'Montserrat')), dense: true)),
              if (!kIsWeb) PopupMenuItem(value: 'dest', child: ListTile(leading: Icon(Icons.folder_outlined, size: 20 * scale), title: Text(_isEasyMode ? 'Save to' : 'Set Destination', style: TextStyle(fontSize: 14 * scale, fontFamily: 'Montserrat')), dense: true)),
              PopupMenuItem(value: 'logs', child: ListTile(leading: Icon(Icons.description_outlined, size: 20 * scale), title: Text(_isEasyMode ? 'Logs' : 'Download Logs', style: TextStyle(fontSize: 14 * scale, fontFamily: 'Montserrat')), dense: true)),
              PopupMenuItem(enabled: false, child: Text(sourceInfo, style: TextStyle(fontSize: 11 * scale, color: Colors.grey, fontFamily: 'Montserrat'))),
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
                  minHeight: 2 * scale,
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
                          ? Center(child: Text(_isEasyMode ? 'Press menu to start.' : 'Load MP3s to begin.', style: TextStyle(color: Colors.grey, fontFamily: 'Montserrat', fontSize: 16 * scale)))
                          : GridView.builder(
                              padding: EdgeInsets.fromLTRB(16, 16, 16, 120 * scale),
                              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180 * scale, childAspectRatio: 0.7, crossAxisSpacing: 12 * scale, mainAxisSpacing: 12 * scale),
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
                                      borderRadius: BorderRadius.circular(16 * scale),
                                      child: BackdropFilter(
                                        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: isSelected ? Colors.cyan.withOpacity(0.15) : Colors.white.withOpacity(0.05),
                                            borderRadius: BorderRadius.circular(16 * scale),
                                            border: Border.all(
                                              color: isSelected ? Colors.cyan : Colors.white.withOpacity(0.1),
                                              width: isSelected ? 2.5 : 1.5,
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
                                                        child: Icon(Icons.music_note, size: 48 * scale, color: Colors.white10)
                                                      ),
                                                    if (isSelected) Positioned(top: 8 * scale, left: 8 * scale, child: Icon(Icons.check_circle, color: Colors.cyan, size: 24 * scale)),
                                                    Positioned(
                                                      bottom: 8 * scale, right: 8 * scale,
                                                      child: GestureDetector(
                                                        onTap: () => _handlePlayback(file),
                                                        child: Container(
                                                          padding: EdgeInsets.all(8 * scale), 
                                                          decoration: BoxDecoration(
                                                            color: Colors.cyan, 
                                                            shape: BoxShape.circle,
                                                            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: const Offset(0, 2))]
                                                          ), 
                                                          child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 24 * scale)
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Padding(
                                                padding: EdgeInsets.all(10.0 * scale),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      file.displayTitle, 
                                                      maxLines: 1, 
                                                      overflow: TextOverflow.ellipsis, 
                                                      style: TextStyle(
                                                        fontSize: 12 * scale, 
                                                        fontWeight: FontWeight.w600, 
                                                        color: isCurrent ? Colors.cyan : Colors.white.withOpacity(0.9),
                                                        fontFamily: 'Montserrat',
                                                      )
                                                    ),
                                                    SizedBox(height: 2 * scale),
                                                    Text(
                                                      file.displayArtist, 
                                                      maxLines: 1, 
                                                      overflow: TextOverflow.ellipsis, 
                                                      style: TextStyle(fontSize: 10 * scale, color: Colors.white54, fontWeight: FontWeight.w300, fontFamily: 'Montserrat')
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
                    VerticalDivider(width: 1, color: Colors.white10),
                    Expanded(
                      flex: 1,
                      child: Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.all(16.0 * scale),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_isEasyMode ? 'Selected' : 'Selected Files', style: TextStyle(fontSize: 14 * scale, fontWeight: FontWeight.bold, fontFamily: 'Montserrat')),
                                Text('(${_selectedFiles.length})', style: TextStyle(fontSize: 12 * scale, color: Colors.grey, fontFamily: 'Montserrat')),
                                const Spacer(),
                                ElevatedButton.icon(
                                  onPressed: _selectedFiles.isNotEmpty ? _copySelectedFiles : null, 
                                  icon: Icon(kIsWeb ? Icons.download : Icons.copy, size: 18 * scale), 
                                  label: Text(kIsWeb ? (_isEasyMode ? 'Get' : 'Download') : (_isEasyMode ? 'Save' : 'Copy Now'), style: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600, fontSize: 13 * scale)), 
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black, elevation: 0, padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale))
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              padding: EdgeInsets.only(bottom: 120 * scale),
                              children: _selectedFiles.map((file) => ListTile(
                                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4 * scale),
                                leading: Container(
                                  width: 40 * scale,
                                  height: 40 * scale,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[900],
                                    borderRadius: BorderRadius.circular(8 * scale),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: file.artwork != null 
                                      ? Image.memory(file.artwork!, fit: BoxFit.cover)
                                      : Icon(Icons.music_note, size: 20 * scale, color: Colors.white10),
                                ),
                                title: Text(file.displayTitle, style: TextStyle(fontSize: 12 * scale, fontWeight: FontWeight.w600, fontFamily: 'Montserrat'), maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(file.displayArtist, style: TextStyle(fontSize: 10 * scale, fontWeight: FontWeight.w300, fontFamily: 'Montserrat', color: Colors.grey)),
                                trailing: IconButton(icon: Icon(Icons.close, size: 16 * scale, color: Colors.grey), onPressed: () => _toggleSelection(file)),
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
              left: 20 * scale,
              right: 20 * scale,
              bottom: 20 * scale,
              child: _buildFloatingPlayer(scale),
            ),
        ],
      ),
    );
  }

  Widget _buildFloatingPlayer(double scale) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20 * scale),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F).withOpacity(0.85),
            borderRadius: BorderRadius.circular(20 * scale),
            border: Border.all(color: Colors.white10, width: 1),
            boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2 * scale,
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
                padding: EdgeInsets.fromLTRB(16 * scale, 8 * scale, 16 * scale, 12 * scale),
                child: Row(
                  children: [
                    Container(
                      width: 44 * scale, height: 44 * scale,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8 * scale),
                        color: Colors.grey[900],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _currentFile?.artwork != null 
                          ? Image.memory(_currentFile!.artwork!, fit: BoxFit.cover)
                          : Icon(Icons.music_note, color: Colors.white10, size: 24 * scale),
                    ),
                    SizedBox(width: 16 * scale),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_currentFile?.displayTitle ?? 'Unknown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * scale, color: Colors.white, fontFamily: 'Montserrat'), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text('${_formatDuration(_position)} / ${_formatDuration(_duration)}', style: TextStyle(color: Colors.grey, fontSize: 10 * scale, fontWeight: FontWeight.w300, fontFamily: 'Montserrat')),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(_playerState == PlayerState.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36 * scale, color: Colors.cyan),
                      onPressed: () => _handlePlayback(_currentFile!),
                    ),
                    IconButton(
                      icon: Icon(Icons.stop_rounded, size: 28 * scale, color: Colors.grey),
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
