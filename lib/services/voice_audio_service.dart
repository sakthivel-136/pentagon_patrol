import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VoiceAudioService {
  static const String kVoiceLanguageKey = 'pentagon_voice_language';
  static final FlutterTts _tts = FlutterTts();
  static final AudioPlayer _audioPlayer = AudioPlayer();
  static String _currentLanguage = 'ta'; // Default to Tamil
  static bool _isTtsInitialized = false;

  static String get currentLanguage => _currentLanguage;
  static bool get isTamil => _currentLanguage == 'ta';

  /// Initialize TTS and load persisted voice language preference
  static Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _currentLanguage = prefs.getString(kVoiceLanguageKey) ?? 'ta';

      await _setupTtsLanguage(_currentLanguage);
      _isTtsInitialized = true;
    } catch (e) {
      debugPrint("VoiceAudioService init error: $e");
    }
  }

  /// Change voice language ('ta' for Tamil, 'en' for English) and persist choice
  static Future<void> setLanguage(String langCode) async {
    _currentLanguage = (langCode == 'en') ? 'en' : 'ta';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kVoiceLanguageKey, _currentLanguage);

    if (_isTtsInitialized) {
      await _setupTtsLanguage(_currentLanguage);
    }
  }

  static Future<void> _setupTtsLanguage(String lang) async {
    try {
      if (lang == 'ta') {
        await _tts.setLanguage('ta-IN');
        await _tts.setSpeechRate(0.48);
        await _tts.setPitch(1.0);
      } else {
        await _tts.setLanguage('en-IN');
        await _tts.setSpeechRate(0.50);
        await _tts.setPitch(1.0);
      }
      await _tts.setVolume(1.0);
    } catch (e) {
      debugPrint("TTS setup language error: $e");
    }
  }

  // ================= SCENARIO TRIGGERS =================

  /// Checkpoint scanned successfully
  static Future<void> speakCheckpointVerified(int checkpointNum, {String? checkpointName}) async {
    _vibrate(durationMs: 120);
    _playChime();

    final message = isTamil
        ? "சோதனைச் சாவடி $checkpointNum உறுதிசெய்யப்பட்டது"
        : "Checkpoint $checkpointNum verified";

    await _speak(message);
  }

  /// Duplicate QR scan (Already scanned in this round)
  static Future<void> speakAlreadyScanned() async {
    _vibratePattern([0, 100, 80, 100]);
    _playChime();

    final message = isTamil
        ? "இந்த சுற்றில் ஏற்கனவே ஸ்கேன் செய்யப்பட்டது"
        : "Already scanned for this round";

    await _speak(message);
  }

  /// Invalid or foreign QR code scanned
  static Future<void> speakInvalidQr() async {
    _vibrate(durationMs: 350);
    _playChime();

    final message = isTamil
        ? "தவறான QR குறியீடு"
        : "Invalid QR code";

    await _speak(message);
  }

  /// Round completed (All checkpoints in current round scanned)
  static Future<void> speakRoundCompleted(int roundNum) async {
    _vibratePattern([0, 150, 100, 150, 100, 200]);
    _playChime();

    final message = isTamil
        ? "சுற்று $roundNum வெற்றிகரமாக முடிந்தது"
        : "Round $roundNum completed successfully";

    await _speak(message);
  }

  /// Helper to play audio tone safely
  static void _playChime() {
    try {
      SystemSound.play(SystemSoundType.click);
      _audioPlayer.stop();
      _audioPlayer.play(AssetSource('sounds/alert.mp3'), volume: 0.6);
    } catch (_) {}
  }

  /// Internal speak with safe fallback
  static Future<void> _speak(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint("TTS speech error: $e");
    }
  }

  /// Haptic feedback
  static void _vibrate({int durationMs = 100}) {
    try {
      Vibration.hasVibrator().then((hasVibe) {
        if (hasVibe == true) {
          Vibration.vibrate(duration: durationMs);
        } else {
          HapticFeedback.mediumImpact();
        }
      });
    } catch (_) {
      HapticFeedback.selectionClick();
    }
  }

  static void _vibratePattern(List<int> pattern) {
    try {
      Vibration.hasVibrator().then((hasVibe) {
        if (hasVibe == true) {
          Vibration.vibrate(pattern: pattern);
        } else {
          HapticFeedback.heavyImpact();
        }
      });
    } catch (_) {
      HapticFeedback.mediumImpact();
    }
  }
}
