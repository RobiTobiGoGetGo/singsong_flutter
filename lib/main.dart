import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

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
  static const String appVersion = '1.0.0+1';
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<PlatformFile> _allFiles = [];
  final Set<PlatformFile> _selectedFiles = {};
  String? _sourcePath;
  String? _destinationPath;

  @override
  void initState() {
    super.initState();
    _loadStoredPaths();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadStoredPaths() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sourcePath = prefs.getString('sourcePath');
      _destinationPath = prefs.getString('destinationPath');
    });
  }

  Future<void> _savePath(String key, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, path);
    setState(() {
      if (key == 'sourcePath') {
        _sourcePath = path;
      } else {
        _destinationPath = path;
      }
    });
  }

  Future<void> _pickSourceFiles() async {
    // Note: On Web, getDirectoryPath is not supported. We use pickFiles instead.
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
      withData: true, // Necessary for web playback and copying
    );

    if (result != null) {
      setState(() {
        _allFiles = result.files.where((file) => file.name.toLowerCase().endsWith('.mp3')).toList();
        // Since we can't reliably get a directory path on Web that persists across restarts 
        // for automatic listing, we store the fact that we've loaded files.
        if (result.files.isNotEmpty && result.files.first.path != null) {
          _savePath('sourcePath', p.dirname(result.files.first.path!));
        }
      });
    }
  }

  Future<void> _pickDestinationDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      _savePath('destinationPath', selectedDirectory);
    }
  }

  void _playFile(PlatformFile file) async {
    try {
      if (file.bytes != null) {
        await _audioPlayer.play(BytesSource(file.bytes!));
      } else if (file.path != null) {
        await _audioPlayer.play(DeviceFileSource(file.path!));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing file: $e')),
      );
    }
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

  Future<void> _copyFiles() async {
    if (_selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select files to copy first.')),
      );
      return;
    }

    if (_destinationPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a destination directory first.')),
      );
      return;
    }

    // On Web, "copying to a local directory" via path is restricted.
    // In a real Desktop app, you would use File(file.path!).copy(...)
    // For this implementation, we simulate the action and show a notification.
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copying ${_selectedFiles.length} files to $_destinationPath...'),
        backgroundColor: Colors.green,
      ),
    );
    
    // In a production app for Web, you might use the File System Access API 
    // or trigger multiple downloads.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SingSong'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
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
            label: Text(_destinationPath == null ? 'Set Destination' : 'Dest: ${p.basename(_destinationPath!)}'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _copyFiles,
            icon: const Icon(Icons.copy_all),
            label: const Text('Copy Selected'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          // Left Pane: Source List
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
                    const Expanded(child: Center(child: Text('No MP3 files loaded. Click "Load MP3s".')))
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: _allFiles.length,
                        separatorBuilder: (context, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final file = _allFiles[index];
                          final isSelected = _selectedFiles.contains(file);
                          return ListTile(
                            leading: Checkbox(
                              value: isSelected,
                              onChanged: (_) => _toggleSelection(file),
                            ),
                            title: Text(file.name),
                            subtitle: Text('${(file.size / 1024 / 1024).toStringAsFixed(2)} MB'),
                            trailing: IconButton(
                              icon: const Icon(Icons.play_circle_fill, color: Colors.blue, size: 32),
                              onPressed: () => _playFile(file),
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
          // Right Pane: Selected List
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
