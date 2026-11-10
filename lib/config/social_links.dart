import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralized manager for social media and support links.
///
/// Private usernames and links are stored locally in `assets/config/social_links.json`
/// (which is ignored by Git via `.gitignore`), ensuring that sensitive personal info
/// is never exposed to public repositories while still remaining fully clickable in-app.
class SocialLinks {
  static String instagramUrl = const String.fromEnvironment('INSTAGRAM_URL', defaultValue: '');
  static String facebookUrl = const String.fromEnvironment('FACEBOOK_URL', defaultValue: '');
  static String tiktokUrl = const String.fromEnvironment('TIKTOK_URL', defaultValue: '');
  static String twitterUrl = const String.fromEnvironment('TWITTER_URL', defaultValue: '');
  static String linkedinUrl = const String.fromEnvironment('LINKEDIN_URL', defaultValue: '');
  static String supportMeUrl = const String.fromEnvironment('SUPPORT_ME_URL', defaultValue: '');

  static bool _isLoaded = false;
  static bool get isLoaded => _isLoaded;

  /// Loads social links from `assets/config/social_links.json` if available.
  static Future<void> load() async {
    if (_isLoaded) return;

    try {
      final jsonStr = await rootBundle.loadString('assets/config/social_links.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      if (data['instagramUrl'] is String && (data['instagramUrl'] as String).trim().isNotEmpty) {
        instagramUrl = (data['instagramUrl'] as String).trim();
      }
      if (data['facebookUrl'] is String && (data['facebookUrl'] as String).trim().isNotEmpty) {
        facebookUrl = (data['facebookUrl'] as String).trim();
      }
      if (data['tiktokUrl'] is String && (data['tiktokUrl'] as String).trim().isNotEmpty) {
        tiktokUrl = (data['tiktokUrl'] as String).trim();
      }
      if (data['twitterUrl'] is String && (data['twitterUrl'] as String).trim().isNotEmpty) {
        twitterUrl = (data['twitterUrl'] as String).trim();
      }
      if (data['linkedinUrl'] is String && (data['linkedinUrl'] as String).trim().isNotEmpty) {
        linkedinUrl = (data['linkedinUrl'] as String).trim();
      }
      if (data['supportMeUrl'] is String && (data['supportMeUrl'] as String).trim().isNotEmpty) {
        supportMeUrl = (data['supportMeUrl'] as String).trim();
      }
    } catch (_) {
      // Safe fallback when file is not found (e.g. in fresh clone or test suite)
    } finally {
      _isLoaded = true;
    }
  }

  /// Reset links for testing or dynamic mocking.
  @visibleForTesting
  static void resetForTesting({
    String instagram = '',
    String facebook = '',
    String tiktok = '',
    String twitter = '',
    String linkedin = '',
    String supportMe = '',
  }) {
    instagramUrl = instagram;
    facebookUrl = facebook;
    tiktokUrl = tiktok;
    twitterUrl = twitter;
    linkedinUrl = linkedin;
    supportMeUrl = supportMe;
    _isLoaded = true;
  }
}

