import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

typedef VoiceAnnouncer = Future<void> Function(String message);

/// Manages the Flutter TTS engine and serializes voice output through a queue
/// so instructions never overlap.
///
/// Accessibility path: when TalkBack / VoiceOver is active, audio is routed
/// through [VoiceAnnouncer] instead of the TTS engine so the screen reader
/// stays in control.
class TtsPlayer {
  final FlutterTts _tts = FlutterTts();

  bool _ready = false;
  bool suppressWhenAccessibilityActive = false;

  // Navigation-scoped announcer (set while a navigation session is active).
  VoiceAnnouncer? sessionAnnouncer;

  // App-scoped announcer (set once at startup, used for exploration mode etc).
  VoiceAnnouncer? permanentAnnouncer;

  Future<void> _voiceQueue = Future.value();
  int _generation = 0;

  // ── Init ─────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_ready) return;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.47);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      try {
        await _tts.setLanguage('es-CO');
      } catch (_) {
        await _tts.setLanguage('es-ES');
      }
      _ready = true;
      debugPrint('✅ TTS inicializado correctamente');
    } catch (e) {
      debugPrint('❌ Error inicializando TTS: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Speak [text], routing through the accessibility announcer when active.
  Future<void> speak(String text) => _enqueue(() => _doSpeak(text));

  /// Stop any in-flight speech and discard queued tasks.
  Future<void> stop() async {
    _generation++;
    try {
      await _tts.stop();
      debugPrint('⏹️ TTS detenido');
    } catch (e) {
      debugPrint('Error deteniendo TTS: $e');
    }
  }

  void dispose() {
    _tts.stop();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _doSpeak(String text) async {
    await init();

    final semanticsOn = SemanticsBinding.instance.semanticsEnabled;
    final accessibleNavOn = WidgetsBinding.instance.platformDispatcher
        .accessibilityFeatures.accessibleNavigation;
    final accessibilityActive =
        semanticsOn || accessibleNavOn || suppressWhenAccessibilityActive;

    if (accessibilityActive) {
      final announcer = sessionAnnouncer ?? permanentAnnouncer;
      if (announcer != null) {
        await announcer(text);
        return;
      }
    }

    if (!_ready) {
      debugPrint('❌ TTS no listo para: $text');
      return;
    }

    debugPrint('🔊 SPEAK: $text');
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('Error de voz: $e');
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final generation = _generation;
    _voiceQueue = _voiceQueue
        .then((_) async {
          if (generation != _generation) return;
          await task();
        })
        .catchError((_) {})
        .then((_) {});
    return _voiceQueue;
  }
}