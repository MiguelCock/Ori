import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../geojson_service.dart';
import '../location_service.dart';
import 'navigation_messages.dart';
import 'tts_player.dart';

/// Periodically scans for nearby landmarks when the user is NOT navigating
/// ("exploration mode"). Fully self-contained — start/stop via [enable]/[disable].
class ExplorationService {
  static const Duration _scanInterval = Duration(seconds: 4);
  static const Duration _minTimeBetweenAnnouncements = Duration(seconds: 8);
  static const double _maxLandmarkDistanceMeters = 25;

  final TtsPlayer _tts;

  LocationService? locationService;
  GeoJsonService? geoJsonService;

  Timer? _timer;
  String? _lastAnnounced;
  DateTime _lastAnnouncedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isRunning => _timer != null;

  ExplorationService({required TtsPlayer tts}) : _tts = tts;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void enable() {
    if (_timer != null) return;
    _timer = Timer.periodic(_scanInterval, (_) => _scan());
    debugPrint('🔍 Modo exploración INICIADO');
  }

  void disable() {
    _timer?.cancel();
    _timer = null;
    _lastAnnounced = null;
    debugPrint('🔍 Modo exploración DETENIDO');
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _scan() async {
    final loc = locationService?.currentLocation;
    if (loc == null) return;

    final geoJson = geoJsonService;
    if (geoJson == null || !geoJson.isDataLoaded) return;

    final now = DateTime.now();
    if (now.difference(_lastAnnouncedAt) < _minTimeBetweenAnnouncements) return;

    final landmark = geoJson.getNearestLandmark(
      loc.latitude,
      loc.longitude,
      maxDistanceMeters: _maxLandmarkDistanceMeters,
    );

    if (landmark == null || landmark == _lastAnnounced) return;

    _lastAnnounced = landmark;
    _lastAnnouncedAt = now;
    debugPrint('🔍 EXPLORACIÓN: $landmark');

    await _announceExploration(NavigationMessages.passingLandmark(landmark));
  }

  Future<void> _announceExploration(String text) async {
    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    if (accessibilityOn) {
      await _tts.permanentAnnouncer?.call(text);
    } else {
      await _tts.speak(text);
    }
  }
}