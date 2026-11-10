import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Central service managing creator profile details (name, bio, avatar, website).
class CreatorProfileService extends ChangeNotifier {
  static final CreatorProfileService _instance = CreatorProfileService._internal();
  factory CreatorProfileService() => _instance;
  CreatorProfileService._internal();

  String _name = 'Your Name';
  String _bio = 'Your Bio';
  String? _avatarPath;
  String? _website;
  bool _isLoaded = false;
  String? _customStorageDir;

  String get name => _name;
  String get bio => _bio;
  String? get avatarPath => _avatarPath;
  String? get website => _website;
  bool get isLoaded => _isLoaded;

  /// Reset state for test execution.
  @visibleForTesting
  void resetForTesting({
    String? name,
    String? bio,
    String? avatarPath,
    String? website,
    String? customDir,
  }) {
    _name = name ?? 'Your Name';
    _bio = bio ?? 'Your Bio';
    _avatarPath = avatarPath;
    _website = website;
    _isLoaded = true;
    _customStorageDir = customDir;
    notifyListeners();
  }

  Future<File> _getProfileFile() async {
    if (_customStorageDir != null) {
      return File('$_customStorageDir/creator_profile.json');
    }
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/creator_profile.json');
  }

  /// Load persisted creator profile from disk.
  Future<void> loadProfile({String? customDir}) async {
    if (customDir != null) _customStorageDir = customDir;
    try {
      final file = await _getProfileFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _name = (data['name'] as String?)?.trim().isNotEmpty == true
            ? data['name'] as String
            : 'Your Name';
        _bio = (data['bio'] as String?)?.trim().isNotEmpty == true
            ? data['bio'] as String
            : 'Your Bio';
        _avatarPath = data['avatarPath'] as String?;
        _website = data['website'] as String?;
      }
    } catch (e) {
      debugPrint('Error loading creator profile: $e');
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  /// Update creator profile information and save to disk.
  Future<void> updateProfile({
    required String name,
    required String bio,
    String? avatarPath,
    String? website,
  }) async {
    _name = name.trim().isEmpty ? 'Your Name' : name.trim();
    final trimmedBio = bio.trim();
    // Enforce max 32 characters as required
    _bio = trimmedBio.length > 32
        ? trimmedBio.substring(0, 32)
        : (trimmedBio.isEmpty ? 'Your Bio' : trimmedBio);
    _avatarPath = avatarPath;
    _website = (website != null && website.trim().isNotEmpty) ? website.trim() : null;

    try {
      final file = await _getProfileFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = {
        'name': _name,
        'bio': _bio,
        'avatarPath': _avatarPath,
        'website': _website,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Error saving creator profile: $e');
    }
    notifyListeners();
  }
}
