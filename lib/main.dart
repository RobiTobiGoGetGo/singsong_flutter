import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:id3/id3.dart';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
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
  dynamic webFile; 
  String? desktopPath;
  
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

  // Identity helper for matching cached files
  String get identity => '$name-$size';
}

enum ArtworkFilter { all, hasArtwork, missingArtwork }

class SingSongHomePage extends StatefulWidget {
  const SingSongHomePage({super.key});

  @override
  State<SingSongHomePage> createState() => _SingSongHomePageState();
}

class _SingSongHomePageState extends State<SingSongHomePage> {
  static const String appVersion = '1.0.52+53';
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  MP3File? _currentFile;
  bool _isPlaylistMode = false;
  
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
  ArtworkFilter _artworkFilter = ArtworkFilter.all;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _log('App started v$appVersion');
    _initializeLibrary();
    
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
      if (mounted) {
        if (_isPlaylistMode) {
          _playNext();
        } else {
          _stopPlayback();
        }
      }
    });
  }

  Future<void> _initializeLibrary() async {
    await _loadStoredPaths();
    await _loadLibraryCache();
    
    if (!kIsWeb && _sourcePath != null) {
      _autoRefreshDesktopFiles(_sourcePath!);
    } else if (kIsWeb && _allFiles.isNotEmpty) {
      _log('Web library restored from cache. Grant access to play.');
    }
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
          file.url = null;
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
      List<String> history = prefs.getStringList('filterHistory') ?? [];
      
      try {
        final defaults = await rootBundle.loadString('defaultFilterTerms.txt');
        final defaultTerms = defaults.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty);
        for (var term in defaultTerms) {
          if (!history.contains(term)) history.add(term);
        }
      } catch (e) { _log('Error loading default filter terms: $e'); }

      history.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      setState(() { 
        _sourcePath = prefs.getString('sourcePath');
        _destinationPath = prefs.getString('destinationPath'); 
        _filterHistory = history;
        _isEasyMode = prefs.getBool('easyMode') ?? false;
      });
    } catch (e) { _log('Error loading paths: $e'); }
  }

  Future<void> _loadLibraryCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('libraryCache');
      if (cached != null) {
        final List<dynamic> decoded = jsonDecode(cached);
        setState(() {
          _allFiles = decoded.map((item) => MP3File.fromJson(item)).toList();
          if (kIsWeb && _allFiles.isNotEmpty) {
            _sourcePath = 'Cached Library (Grant access to play)';
          }
        });
        _log('Loaded ${_allFiles.length} files from library cache.');
      }
    } catch (e) { _log('Error loading library cache: $e'); }
  }

  Future<void> _saveLibraryCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_allFiles.map((f) => f.toJson()).toList());
      await prefs.setString('libraryCache', json);
      _log('Saved ${_allFiles.length} files to library cache.');
    } catch (e) { 
      _log('Error saving library cache: $e'); 
      if (kIsWeb && e.toString().contains('QuotaExceededError')) {
        _log('WARNING: Library cache too large for LocalStorage.');
      }
    }
  }

  void _extractMetadata(MP3File mp3File, Uint8List bytes) {
    try {
      final id3 = MP3Instance(bytes);
      id3.parseTagsSync();
      final meta = id3.getMetaTags();
      if (meta != null) {
        mp3File.title = meta['Title']?.toString() ?? meta['title']?.toString();
        mp3File.artist = meta['Artist']?.toString() ?? meta['artist']?.toString();
        
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

  Future<void> _autoRefreshDesktopFiles(String path) async {
    _log('Refreshing desktop library from: $path');
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return;

      final entities = await dir.list().toList();
      Map<String, MP3File> cachedMap = { for (var f in _allFiles) f.identity : f };
      List<MP3File> updatedList = [];
      List<MP3File> filesToProcess = [];

      for (var entity in entities) {
        if (entity is File && entity.path.toLowerCase().endsWith('.mp3')) {
          final stat = await entity.stat();
          final identity = '${p.basename(entity.path)}-${stat.size}';
          
          if (cachedMap.containsKey(identity)) {
            final cachedFile = cachedMap[identity]!;
            cachedFile.desktopPath = entity.path; // Update path in case it changed
            updatedList.add(cachedFile);
          } else {
            final newFile = MP3File(
              name: p.basename(entity.path), 
              size: stat.size, 
              desktopPath: entity.path
            );
            updatedList.add(newFile);
            filesToProcess.add(newFile);
          }
        }
      }

      _currentLoadId++;
      setState(() {
        _allFiles = updatedList;
        if (filesToProcess.isNotEmpty) {
          _totalFiles = filesToProcess.length;
          _filesProcessed = 0;
          _isLoading = true;
          _processDesktopFiles(filesToProcess, _currentLoadId);
        }
      });
    } catch (e) { _log('Auto-refresh failed: $e'); }
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
    if (mounted && loadId == _currentLoadId) {
      setState(() { _isLoading = false; });
      _saveLibraryCache();
    }
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
          content: const Text('The current loading process will be terminated. Do you want to continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continue current load'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('Reset and Load New'),
            ),
          ],
        ),
      );
      if (reset != true) return;
      _currentLoadId++;
    }
    _pickSourceFiles();
  }

  Future<void> _pickSourceFiles() async {
    if (kIsWeb) {
      final input = html.FileUploadInputElement()..multiple = true..accept = '.mp3';
      input.click();
      input.onChange.listen((event) async {
        final files = input.files;
        if (files == null || files.isEmpty) return;
        
        _cleanupWebUrls();
        Map<String, MP3File> cachedMap = { for (var f in _allFiles) f.identity : f };
        List<MP3File> updatedLibrary = [];
        List<MP3File> filesToProcess = [];

        for (var file in files) {
          if (file.name.toLowerCase().endsWith('.mp3')) {
            final identity = '${file.name}-${file.size}';
            if (cachedMap.containsKey(identity)) {
              final cached = cachedMap[identity]!;
              cached.webFile = file;
              updatedLibrary.add(cached);
            } else {
              final newFile = MP3File(name: file.name, size: file.size, webFile: file);
              updatedLibrary.add(newFile);
              filesToProcess.add(newFile);
            }
          }
        }

        _currentLoadId++;
        setState(() {
          _allFiles = updatedLibrary;
          _sourcePath = 'Selected Files';
          if (filesToProcess.isNotEmpty) {
            _totalFiles = filesToProcess.length;
            _filesProcessed = 0;
            _isLoading = true;
            _processWebFiles(filesToProcess, _currentLoadId);
          } else {
            _isLoading = false;
            _log('Restored all selected files from cache.');
            _refreshWebUrls();
          }
        });
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
      
      setState(() { _sourcePath = folderPath; });
      if (folderPath != null) {
        _autoRefreshDesktopFiles(folderPath);
      }
    }
  }

  Future<void> _refreshWebUrls() async {
    if (!kIsWeb) return;
    for (var file in _allFiles) {
      if (file.webFile != null && file.url == null) {
        try {
          final reader = html.FileReader();
          reader.readAsArrayBuffer(file.webFile);
          await reader.onLoadEnd.first;
          final Uint8List bytes = reader.result as Uint8List;
          final blob = html.Blob([bytes]);
          file.url = html.Url.createObjectUrlFromBlob(blob);
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
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
      _saveLibraryCache();
    }
  }

  void _handlePlayback(MP3File file) async {
    if (_currentFile == file) {
      if (_playerState == PlayerState.playing) { 
        await _audioPlayer.pause(); 
      } else if (_playerState == PlayerState.paused) { 
        await _audioPlayer.resume(); 
      } else {
        await _play(file, playlistMode: _isPlaylistMode);
      }
      return;
    }
    await _play(file);
  }

  Future<void> _play(MP3File file, {bool playlistMode = false}) async {
    if (kIsWeb && file.webFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please re-select files to grant playback access.')));
      return;
    }
    _log('Playing: ${file.name} (Playlist: $playlistMode)');
    if (_filter.trim().isNotEmpty) {
      _onFilterSubmitted(_filter);
    }
    try {
      setState(() { 
        _currentFile = file; 
        _isPlaylistMode = playlistMode;
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

  void _playNext() {
    if (_selectedFiles.isEmpty || _currentFile == null) {
      _stopPlayback();
      return;
    }
    final selectedList = _selectedFiles.toList();
    final currentIndex = selectedList.indexOf(_currentFile!);
    if (currentIndex != -1 && currentIndex < selectedList.length - 1) {
      _play(selectedList[currentIndex + 1], playlistMode: true);
    } else {
      _stopPlayback();
    }
  }

  void _playPrevious() {
    if (_selectedFiles.isEmpty || _currentFile == null) return;
    final selectedList = _selectedFiles.toList();
    final currentIndex = selectedList.indexOf(_currentFile!);
    if (currentIndex > 0) {
      _play(selectedList[currentIndex - 1], playlistMode: true);
    }
  }

  void _stopPlayback() {
    if (mounted) {
      setState(() {
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
        _isPlaylistMode = false;
      });
    }
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
        if (file.webFile == null) continue;
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
      if (!_filterHistory.contains(trimmed)) {
        _filterHistory.add(trimmed);
        _filterHistory.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }
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

  void _showFileContextMenu(BuildContext context, Offset position, MP3File file) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Rect.fromLTWH(0, 0, overlay.size.width, overlay.size.height),
      ),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: const Color(0xFF2A2A2A),
      items: [
        PopupMenuItem(
          onTap: () {
            Clipboard.setData(ClipboardData(text: file.name));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied: ${file.name}'), duration: const Duration(seconds: 1)));
          },
          child: Row(
            children: [
              const Icon(Icons.copy, color: Colors.cyan, size: 20),
              const SizedBox(width: 12),
              const Text('Copy File Name', style: TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Montserrat')),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _isEasyMode ? 1.4 : 1.0;
    final filteredFiles = _allFiles.where((file) {
      // 1. Apply multi-word search filter
      if (_filter.isNotEmpty) {
        final query = _filter.toLowerCase();
        final words = query.split(' ').where((w) => w.isNotEmpty).toList();
        final matchesWords = words.every((word) => 
          file.name.toLowerCase().contains(word) || 
          (file.title?.toLowerCase().contains(word) ?? false) || 
          (file.artist?.toLowerCase().contains(word) ?? false)
        );
        if (!matchesWords) return false;
      }

      // 2. Apply Artwork Radio Button Filter
      switch (_artworkFilter) {
        case ArtworkFilter.hasArtwork:
          return file.artwork != null;
        case ArtworkFilter.missingArtwork:
          return file.artwork == null;
        case ArtworkFilter.all:
        default:
          return true;
      }
    }).toList();

    String sourceInfo = _sourcePath ?? 'No library loaded';

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
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
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
                  const SizedBox(width: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildArtworkRadio('All', ArtworkFilter.all, scale),
                      _buildArtworkRadio('Has artwork', ArtworkFilter.hasArtwork, scale),
                      _buildArtworkRadio('Artwork missing', ArtworkFilter.missingArtwork, scale),
                    ],
                  ),
                ],
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
                                    onSecondaryTapDown: (details) => _showFileContextMenu(context, details.globalPosition, file),
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
                                if (_selectedFiles.isNotEmpty) ...[
                                  IconButton(
                                    onPressed: () => _play(_selectedFiles.first, playlistMode: true),
                                    icon: Icon(Icons.play_circle_fill, size: 28 * scale, color: Colors.cyan),
                                    tooltip: 'Play All',
                                  ),
                                  SizedBox(width: 4 * scale),
                                ],
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
                              children: _selectedFiles.map((file) => Listener(
                                onPointerDown: (event) {
                                  if (event.kind == PointerDeviceKind.mouse && event.buttons == 2) {
                                    _showFileContextMenu(context, event.position, file);
                                  }
                                },
                                child: ListTile(
                                  onTap: () => _play(file, playlistMode: true),
                                  hoverColor: Colors.white10,
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
                                  title: Text(file.displayTitle, 
                                    style: TextStyle(
                                      fontSize: 12 * scale, 
                                      fontWeight: FontWeight.w600, 
                                      fontFamily: 'Montserrat',
                                      color: _currentFile == file ? Colors.cyan : Colors.white,
                                    ), 
                                    maxLines: 1, 
                                    overflow: TextOverflow.ellipsis
                                  ),
                                  subtitle: Text(file.displayArtist, style: TextStyle(fontSize: 10 * scale, fontWeight: FontWeight.w300, fontFamily: 'Montserrat', color: Colors.grey)),
                                  trailing: IconButton(icon: Icon(Icons.close, size: 16 * scale, color: Colors.grey), onPressed: () => _toggleSelection(file)),
                                ),
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

  Widget _buildArtworkRadio(String label, ArtworkFilter value, double scale) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Radio<ArtworkFilter>(
          value: value,
          groupValue: _artworkFilter,
          activeColor: Colors.cyan,
          onChanged: (v) {
            if (v != null) setState(() { _artworkFilter = v; });
          },
        ),
        GestureDetector(
          onTap: () => setState(() { _artworkFilter = value; }),
          child: Text(label, style: TextStyle(fontSize: 12 * scale, fontFamily: 'Montserrat', color: _artworkFilter == value ? Colors.cyan : Colors.white70)),
        ),
        const SizedBox(width: 8),
      ],
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
                      icon: Icon(Icons.skip_previous_rounded, size: 28 * scale, color: _isPlaylistMode ? Colors.white : Colors.grey),
                      onPressed: _isPlaylistMode ? _playPrevious : null,
                    ),
                    IconButton(
                      icon: Icon(_playerState == PlayerState.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36 * scale, color: Colors.cyan),
                      onPressed: () => _handlePlayback(_currentFile!),
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next_rounded, size: 28 * scale, color: _isPlaylistMode ? Colors.white : Colors.grey),
                      onPressed: _isPlaylistMode ? _playNext : null,
                    ),
                    IconButton(
                      icon: Icon(Icons.stop_rounded, size: 28 * scale, color: Colors.grey),
                      onPressed: () async {
                        await _audioPlayer.stop();
                        _stopPlayback();
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
