import 'dart:async';
import 'dart:math';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../geojson_service.dart';
import '../haptic_service.dart';
import '../location_service.dart';
import '../route_guidance_builder.dart';
import '../routing/routing.dart';
import 'exploration_service.dart';
import 'heading_tracker.dart';
import 'navigation_messages.dart';
import 'tts_player.dart';

export 'navigation_messages.dart';
export 'tts_player.dart' show VoiceAnnouncer;

typedef LandmarkResolver = String? Function(
  double lat,
  double lng,
  double? headingDegrees,
);
typedef NavigationArrivalHandler = Future<void> Function();

// ── Preferences keys ──────────────────────────────────────────────────────────
const _kPeriodicProgressPref = 'periodic_progress_confirmations_enabled';
const _kLandmarksPref = 'landmarks_enabled';
const _kExplorationPref = 'exploration_mode_enabled';

class VoiceGuidanceService extends ChangeNotifier {
  static final VoiceGuidanceService _instance =
      VoiceGuidanceService._internal();
  factory VoiceGuidanceService() => _instance;
  VoiceGuidanceService._internal();

  // ── Collaborators ─────────────────────────────────────────────────────────
  final TtsPlayer _tts = TtsPlayer();
  final HeadingTracker _heading = HeadingTracker();
  late final ExplorationService _exploration = ExplorationService(tts: _tts);

  // ── Session deps (set per navigation session) ─────────────────────────────
  LocationService? _locationService;
  RoutingService? _routingService;
  LandmarkResolver? _landmarkResolver;
  NavigationArrivalHandler? _onArrival;

  // ── Nav state ─────────────────────────────────────────────────────────────
  bool _isNavigating = false;
  bool _isPaused = false;
  String _status = 'Navegación por voz inactiva';
  String _currentInstruction = '';

  final List<GuidanceStep> _steps = [];
  final List<RouteLeg> _routeLegs = [];
  List<RoutePoint> _activePolyline = [];
  int _currentStepIndex = 0;

  double _destinationLat = 0;
  double _destinationLng = 0;
  String _destinationName = '';

  bool _arrivalHandled = false;
  bool _arrivalHapticTriggered = false;

  // ── Off-route detection ───────────────────────────────────────────────────
  static const int _minOffRouteSamples = 3;
  static const double _maxDistanceFromRouteMeters = 25.0;
  int _consecutiveOffRouteSamples = 0;
  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Progress reminder clock ───────────────────────────────────────────────
  static const Duration _progressInterval = Duration(seconds: 20);
  static const double _minMovementMeters = 1.8;
  static const double _minSpeedMps = 0.35;
  static const double _progressTurnBuffer = 8.0;
  Duration _movingReminderElapsed = Duration.zero;
  DateTime? _lastReminderSampleAt;
  RoutePoint? _lastReminderSamplePoint;

  // ── Landmark suppression during navigation ────────────────────────────────
  static const Duration _minTimeBetweenLandmarks = Duration(seconds: 5);
  static const double _destinationArrivalRadius = 12.0;
  String? _lastAnnouncedLandmark;
  DateTime _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Preferences ───────────────────────────────────────────────────────────
  bool _preferencesLoaded = false;
  bool _periodicProgressEnabled = true;
  bool _landmarksEnabled = true;
  bool _explorationModeEnabled = false;

  double _minInstructionDistanceMeters = 12;

  // ── Getters ───────────────────────────────────────────────────────────────

  bool get isNavigating => _isNavigating;
  bool get isPaused => _isPaused;
  String get status => _status;
  String get currentInstruction => _currentInstruction;
  int get remainingSteps => max(0, _steps.length - _currentStepIndex);
  double get minInstructionDistanceMeters => _minInstructionDistanceMeters;
  List<GuidanceStep> get guidanceSteps => List.unmodifiable(_steps);
  List<RoutePoint> get activePolyline => List.unmodifiable(_activePolyline);
  int get currentStepIndex => _currentStepIndex;
  RouteResult? get activeRoute => _routingService?.currentRoute;
  bool get periodicProgressConfirmationsEnabled => _periodicProgressEnabled;
  bool get landmarksEnabled => _landmarksEnabled;
  bool get explorationModeEnabled => _explorationModeEnabled;

  double? get mapReferenceHeadingDegrees => _heading.referenceHeading(
        _routeLegs,
        _currentStepIndex,
        _currentStepIndex == 0,
      );

  // ── Public setup API ──────────────────────────────────────────────────────

  void setLocationService(LocationService service) {
    _exploration.locationService = service;
    service.setAnnouncer(_tts.speak);
    debugPrint('📍 VoiceGuidance: LocationService asignado');
  }

  void setGeoJsonService(GeoJsonService service) {
    _exploration.geoJsonService = service;
    debugPrint('📍 VoiceGuidance: GeoJsonService asignado');
  }

  void setAnnouncer(VoiceAnnouncer announcer) {
    _tts.permanentAnnouncer = announcer;
    debugPrint('📍 VoiceGuidance: Announcer permanente asignado');
  }

  void setSuppressTtsWhenAccessibility(bool suppress) {
    _tts.suppressWhenAccessibilityActive = suppress;
  }

  Future<void> setMinInstructionDistance(double meters) async {
    _minInstructionDistanceMeters = meters.clamp(8, 25);
    notifyListeners();
  }

  // ── Preferences ───────────────────────────────────────────────────────────

  Future<void> _ensurePreferencesLoaded() async {
    if (_preferencesLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _periodicProgressEnabled =
          prefs.getBool(_kPeriodicProgressPref) ?? true;
      _landmarksEnabled = prefs.getBool(_kLandmarksPref) ?? true;
      _explorationModeEnabled = prefs.getBool(_kExplorationPref) ?? false;
    } catch (_) {}
    _preferencesLoaded = true;
    notifyListeners();

    if (_explorationModeEnabled && !_isNavigating) _exploration.enable();
  }

  Future<void> setPeriodicProgressConfirmationsEnabled(bool enabled) async {
    if (_periodicProgressEnabled == enabled) return;
    _periodicProgressEnabled = enabled;
    notifyListeners();
    await _savePref(_kPeriodicProgressPref, enabled);
  }

  void setLandmarksEnabled(bool enabled) {
    if (_landmarksEnabled == enabled) return;
    _landmarksEnabled = enabled;
    if (!enabled) _lastAnnouncedLandmark = null;
    notifyListeners();
    _savePref(_kLandmarksPref, enabled);
  }

  void setExplorationModeEnabled(bool enabled) {
    if (_explorationModeEnabled == enabled) return;
    _explorationModeEnabled = enabled;
    notifyListeners();
    _savePref(_kExplorationPref, enabled);

    if (enabled && !_isNavigating) {
      _exploration.enable();
    } else {
      _exploration.disable();
    }
  }

  Future<void> _savePref(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  // ── TTS public surface ────────────────────────────────────────────────────

  Future<void> speak(String message) async {
    await _tts.init();
    await _tts.speak(message);
  }

  Future<void> speakMessage(String message) => _tts.speak(message);

  Future<void> stopSpeaking() => _tts.stop();

  // ── Navigation lifecycle ──────────────────────────────────────────────────

  Future<void> startNavigation({
    required RouteResult route,
    required LocationService locationService,
    required RoutingService routingService,
    required String destinationName,
    required double destinationLat,
    required double destinationLng,
    required VoiceAnnouncer announceForTalkBack,
    LandmarkResolver? landmarkResolver,
    NavigationArrivalHandler? onArrival,
    bool skipInitialCalibration = false,
  }) async {
    await _ensurePreferencesLoaded();
    await _tts.init();

    _exploration.disable();
    await stopNavigation(speak: false);

    _locationService = locationService;
    _routingService = routingService;
    _tts.sessionAnnouncer = announceForTalkBack;
    _landmarkResolver = landmarkResolver;
    _onArrival = onArrival;
    _destinationName = destinationName;
    _destinationLat = destinationLat;
    _destinationLng = destinationLng;
    _lastAnnouncedLandmark = null;
    _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
    _consecutiveOffRouteSamples = 0;

    final double? initialHeading;
    if (skipInitialCalibration) {
      initialHeading = _routeLegs.isNotEmpty
          ? _routeLegs.first.bearingDegrees
          : null;
    } else {
      initialHeading = await _heading.calibrate(
        currentPosition: () {
          final loc = locationService.currentLocation;
          return loc == null
              ? null
              : RoutePoint(latitude: loc.latitude, longitude: loc.longitude);
        },
        speak: _tts.speak,
      );
    }
    _heading.initialCalibratedHeading = initialHeading;

    _rebuildRoute(route, initialHeading: initialHeading);

    if (_steps.isEmpty) {
      _status = NavigationMessages.noPointsForGuidance();
      notifyListeners();
      return;
    }

    _isNavigating = true;
    _isPaused = false;
    _status = 'Navegación activa hacia $_destinationName';
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = DateTime.now();

    final startPoint = _currentNavPoint(route);
    _lastReminderSamplePoint = startPoint;
    _heading.reset(seedPoint: startPoint);
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;

    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    await HapticService.trigger(HapticEvent.navigationStarted);

    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    final startMsg = accessibilityOn
        ? '${NavigationMessages.navigationStarted(destinationName)} '
          '${_steps.first.instruction} '
          'Toca la pantalla para repetir la indicación. '
          'Usa el botón Finalizar navegación para salir.'
        : '${NavigationMessages.navigationStarted(destinationName)} ${_steps.first.instruction}';

    await _tts.speak(startMsg);
  }

  Future<void> pauseNavigation({bool speak = true}) async {
    if (!_isNavigating || _isPaused) return;
    _locationService?.removeListener(_onLocationChanged);
    _isPaused = true;
    _status = NavigationMessages.navigationPaused();
    notifyListeners();
    await _tts.stop();
    if (speak) await _tts.speak(NavigationMessages.navigationPaused());
  }

  Future<void> resumeNavigation({
    RouteResult? route,
    bool speak = true,
  }) async {
    if (!_isNavigating && route == null) return;

    if (route != null) {
      final heading = route.polyline.length >= 2
          ? HeadingTracker.bearingDegrees(
              route.polyline[0], route.polyline[1])
          : mapReferenceHeadingDegrees;
      _rebuildRoute(route, initialHeading: heading);
    }

    if (_steps.isEmpty) {
      _status = NavigationMessages.noPointsForGuidance();
      notifyListeners();
      return;
    }

    final loc = _locationService?.currentLocation;
    final resumePoint = loc == null
        ? (_activePolyline.isEmpty ? null : _activePolyline.first)
        : RoutePoint(latitude: loc.latitude, longitude: loc.longitude);

    _isNavigating = true;
    _isPaused = false;
    _status = 'Navegación activa hacia $_destinationName';
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = DateTime.now();
    _lastReminderSamplePoint = resumePoint;
    _lastAnnouncedLandmark = null;
    _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;
    _consecutiveOffRouteSamples = 0;
    _heading.reset(seedPoint: resumePoint);

    _locationService?.removeListener(_onLocationChanged);
    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    if (speak) {
      final msg = _currentInstruction.isEmpty
          ? NavigationMessages.navigationResumed()
          : '${NavigationMessages.navigationResumed()}. $_currentInstruction';
      await _tts.speak(msg);
    }
  }

  Future<void> finishNavigation({bool speak = true}) async {
    if (speak) await _tts.speak(NavigationMessages.navigationFinished());
    await stopNavigation(speak: false);
  }

  Future<void> stopNavigation({bool speak = true}) async {
    _locationService?.removeListener(_onLocationChanged);
    _locationService?.stopSimulation();
    _locationService = null;
    _routingService = null;
    _landmarkResolver = null;
    _onArrival = null;
    _tts.sessionAnnouncer = null;

    _steps.clear();
    _routeLegs.clear();
    _activePolyline = [];
    _currentStepIndex = 0;
    _isNavigating = false;
    _isPaused = false;
    _currentInstruction = '';
    _status = 'Navegación por voz inactiva';
    _lastAnnouncedLandmark = null;
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = null;
    _lastReminderSamplePoint = null;
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;
    _consecutiveOffRouteSamples = 0;
    _heading.reset();

    if (speak) {
      await _tts.speak(NavigationMessages.navigationStopped());
    } else {
      await _tts.stop();
    }

    notifyListeners();

    if (_explorationModeEnabled) _exploration.enable();
  }

  Future<void> completeNavigationIfActive() async {
    if (!_isNavigating || _arrivalHandled) return;
    await _completeArrival();
  }

  // ── Location update handling ───────────────────────────────────────────────

  Future<void> _onLocationChanged() async {
    if (!_isNavigating ||
        _isPaused ||
        _locationService?.currentLocation == null) {
      return;
    }

    final loc = _locationService!.currentLocation!;
    final now = DateTime.now();
    final current =
        RoutePoint(latitude: loc.latitude, longitude: loc.longitude);

    // Arrival check.
    final distToDest = _haversineMeters(
      loc.latitude, loc.longitude, _destinationLat, _destinationLng,
    );
    if (!_arrivalHandled && distToDest <= _destinationArrivalRadius) {
      await _completeArrival();
      return;
    }

    _updateReminderClock(loc, now);
    _heading.update(current);
    _syncStepIndex(loc.latitude, loc.longitude);

    // Off-route detection with spike filter.
    if (_isFarFromRoute(loc.latitude, loc.longitude)) {
      _consecutiveOffRouteSamples++;
      if (_consecutiveOffRouteSamples >= _minOffRouteSamples) {
        _consecutiveOffRouteSamples = 0;
        await _maybeReroute(loc.latitude, loc.longitude);
      }
    } else {
      _consecutiveOffRouteSamples = 0;
    }

    if (_currentStepIndex >= _steps.length) return;

    final step = _steps[_currentStepIndex];
    final distToStep = _haversineMeters(
      loc.latitude, loc.longitude,
      step.endPoint.latitude, step.endPoint.longitude,
    );

    // Close-pass snap.
    if (distToStep <= 2.0) {
      _advanceStep();
      return;
    }

    // Trigger distance reached → speak instruction.
    if (distToStep <= step.triggerDistanceMeters) {
      _currentStepIndex++;
      if (_currentStepIndex >= _steps.length) {
        _currentStepIndex = _steps.length - 1;
        _updateFinalLegInstruction(loc.latitude, loc.longitude);
        notifyListeners();
        return;
      }
      _currentInstruction = _steps[_currentStepIndex].instruction;
      _heading.commitOnTurn(_currentInstruction, _routeLegs, _currentStepIndex);
      _movingReminderElapsed = Duration.zero;
      _status = 'Navegación activa hacia $_destinationName';
      notifyListeners();
      await HapticService.trigger(HapticEvent.turnInstruction);
      await _tts.speak(_currentInstruction);
      _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
      return;
    }

    // Landmark announcement during navigation.
    final enoughTimeSinceLandmark =
        now.difference(_lastLandmarkAt) >= _minTimeBetweenLandmarks;
    final notAboutToTurn = distToStep > step.triggerDistanceMeters + 10;

    if (_landmarksEnabled && enoughTimeSinceLandmark && notAboutToTurn) {
      final landmark = _landmarkResolver?.call(
        loc.latitude, loc.longitude, mapReferenceHeadingDegrees,
      );
      if (landmark != null && landmark != _lastAnnouncedLandmark) {
        _lastAnnouncedLandmark = landmark;
        _lastLandmarkAt = now;
        debugPrint('🗣️ LANDMARK: $landmark');
        try { HapticFeedback.lightImpact(); } catch (_) {}
        await _tts.speak(NavigationMessages.passingLandmark(landmark));
        return;
      }
    }

    // Keep final-leg instruction fresh.
    if (_currentStepIndex == _steps.length - 1) {
      _updateFinalLegInstruction(loc.latitude, loc.longitude);
    }

    // Periodic progress confirmation.
    if (_periodicProgressEnabled &&
        _movingReminderElapsed >= _progressInterval &&
        distToStep > step.triggerDistanceMeters + _progressTurnBuffer) {
      _movingReminderElapsed -= _progressInterval;
      final remaining = getRemainingDistance(loc.latitude, loc.longitude);
      final remainingText = _formatDistance(remaining);
      await _tts.speak(NavigationMessages.periodicProgress(
        nextInstructionMeters: distToStep.round(),
        remainingDistanceText: remainingText,
        destination: _destinationName,
      ));
    }
  }

  // ── Distance helpers ──────────────────────────────────────────────────────

  double getRemainingDistance(double lat, double lng) {
    if (_steps.isEmpty || _currentStepIndex >= _steps.length) return 0;
    double total = 0;
    for (int i = _currentStepIndex; i < _steps.length; i++) {
      final step = _steps[i];
      final from = i == _currentStepIndex
          ? RoutePoint(latitude: lat, longitude: lng)
          : _steps[i - 1].endPoint;
      total += _haversineMeters(
        from.latitude, from.longitude,
        step.endPoint.latitude, step.endPoint.longitude,
      );
    }
    return total;
  }

  Future<void> announceRemainingDistance() async {
    if (!_isNavigating || _isPaused) return;
    final loc = _locationService?.currentLocation;
    if (loc == null) return;
    final dist = getRemainingDistance(loc.latitude, loc.longitude);
    if (dist <= 0) return;
    await _tts.speak(
      'Te faltan ${_formatDistance(dist)} para llegar a $_destinationName.',
    );
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _rebuildRoute(RouteResult route, {double? initialHeading}) {
    _activePolyline = List<RoutePoint>.from(route.polyline);
    _routeLegs
      ..clear()
      ..addAll(HeadingTracker.compactLegs(_activePolyline));
    _steps
      ..clear()
      ..addAll(RouteGuidanceBuilder.buildSteps(
        polyline: _activePolyline,
        destinationLat: _destinationLat,
        destinationLng: _destinationLng,
        destinationName: _destinationName,
        landmarkResolver: _landmarkResolver,
        initialHeadingDegrees: initialHeading,
        minInstructionDistanceMeters: _minInstructionDistanceMeters,
      ));
    _currentStepIndex = 0;
    _currentInstruction = _steps.isEmpty ? '' : _steps.first.instruction;
    _consecutiveOffRouteSamples = 0;
  }

  RoutePoint? _currentNavPoint(RouteResult route) {
    final loc = _locationService?.currentLocation;
    if (loc != null) {
      return RoutePoint(latitude: loc.latitude, longitude: loc.longitude);
    }
    return route.polyline.isEmpty ? null : route.polyline.first;
  }

  void _advanceStep() {
    if (_currentStepIndex + 1 < _steps.length) {
      _currentStepIndex++;
      _currentInstruction = _steps[_currentStepIndex].instruction;
      _heading.commitOnTurn(
          _currentInstruction, _routeLegs, _currentStepIndex);
      _movingReminderElapsed = Duration.zero;
      notifyListeners();
    }
  }

  void _updateFinalLegInstruction(double lat, double lng) {
    final remaining = getRemainingDistance(lat, lng);
    final text = remaining > 0
        ? 'Continúa recto. Faltan ${_formatDistance(remaining)} para llegar a $_destinationName.'
        : 'Continúa hasta llegar a $_destinationName. Te avisaré al llegar.';
    if (_currentInstruction != text) {
      _currentInstruction = text;
      notifyListeners();
    }
  }

  void _syncStepIndex(double lat, double lng) {
    if (_steps.isEmpty || _currentStepIndex >= _steps.length) return;
    final nextIdx = _currentStepIndex + 1;
    if (nextIdx >= _steps.length) return;

    final dNext = _haversineMeters(
      lat, lng,
      _steps[nextIdx].endPoint.latitude,
      _steps[nextIdx].endPoint.longitude,
    );
    if (dNext > 12) return;

    final dCurrent = _haversineMeters(
      lat, lng,
      _steps[_currentStepIndex].endPoint.latitude,
      _steps[_currentStepIndex].endPoint.longitude,
    );
    if (dNext >= dCurrent) return;

    _currentStepIndex = nextIdx;
    _currentInstruction = _steps[_currentStepIndex].instruction;
    _heading.commitOnTurn(_currentInstruction, _routeLegs, _currentStepIndex);
    _movingReminderElapsed = Duration.zero;
    notifyListeners();
  }

  bool _isFarFromRoute(double lat, double lng) {
    if (_activePolyline.length < 2) return false;
    double best = double.infinity;
    for (int i = 0; i < _activePolyline.length - 1; i++) {
      final d = _distToSegment(
        lat, lng,
        _activePolyline[i].latitude, _activePolyline[i].longitude,
        _activePolyline[i + 1].latitude, _activePolyline[i + 1].longitude,
      );
      if (d < best) best = d;
    }
    return best > _maxDistanceFromRouteMeters;
  }

  double _distToSegment(
    double pLat, double pLng,
    double aLat, double aLng,
    double bLat, double bLng,
  ) {
    const mpdLat = 111320.0;
    final refLat = (aLat + bLat + pLat) / 3;
    final mpdLng = mpdLat * cos(_toRad(refLat));

    final ax = aLng * mpdLng, ay = aLat * mpdLat;
    final bx = bLng * mpdLng, by = bLat * mpdLat;
    final px = pLng * mpdLng, py = pLat * mpdLat;

    final abx = bx - ax, aby = by - ay;
    final ab2 = abx * abx + aby * aby;
    if (ab2 == 0) return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));

    final t = ((px - ax) * abx + (py - ay) * aby) / ab2;
    final tc = t.clamp(0.0, 1.0);
    final cx = ax + abx * tc, cy = ay + aby * tc;
    return sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  Future<void> _completeArrival() async {
    if (_arrivalHandled) return;
    _arrivalHandled = true;
    _currentInstruction =
        NavigationMessages.destinationReached(_destinationName);
    _status = 'Destino alcanzado';
    notifyListeners();

    if (!_arrivalHapticTriggered) {
      _arrivalHapticTriggered = true;
      await HapticService.trigger(HapticEvent.destinationReached);
    }
    final onArrival = _onArrival;
    if (onArrival != null) unawaited(onArrival());

    try { HapticFeedback.heavyImpact(); } catch (_) {}
    await _tts.speak(NavigationMessages.destinationReached(_destinationName));
    await stopNavigation(speak: false);
  }

  Future<void> _maybeReroute(double lat, double lng) async {
    final now = DateTime.now();
    if (now.difference(_lastRerouteAt).inSeconds < 15) return;
    _lastRerouteAt = now;

    final routing = _routingService;
    if (routing == null) return;

    await HapticService.trigger(HapticEvent.routeRecalculated);
    await _tts.speak(NavigationMessages.offRoute());

    final updated = await routing.buildRoute(
      originLat: lat,
      originLng: lng,
      destinationLat: _destinationLat,
      destinationLng: _destinationLng,
    );

    if (updated == null || updated.polyline.length < 2) {
      await HapticService.trigger(HapticEvent.error);
      await _tts.speak(NavigationMessages.rerouteFailed());
      return;
    }

    final newHeading =
        HeadingTracker.bearingDegrees(updated.polyline[0], updated.polyline[1]);
    _heading.reset(
        seedPoint: RoutePoint(latitude: lat, longitude: lng));

    _rebuildRoute(updated, initialHeading: newHeading);
    _status = 'Ruta actualizada hacia $_destinationName';
    _lastAnnouncedLandmark = null;
    _movingReminderElapsed = Duration.zero;
    notifyListeners();

    await _tts.speak(
        NavigationMessages.routeUpdated(_steps.first.instruction));
  }

  void _updateReminderClock(LocationData loc, DateTime now) {
    final lastAt = _lastReminderSampleAt;
    final lastPoint = _lastReminderSamplePoint;

    if (lastAt == null || lastPoint == null) {
      _lastReminderSampleAt = now;
      _lastReminderSamplePoint =
          RoutePoint(latitude: loc.latitude, longitude: loc.longitude);
      return;
    }

    final delta = now.difference(lastAt);
    if (delta <= Duration.zero) {
      _lastReminderSampleAt = now;
      _lastReminderSamplePoint =
          RoutePoint(latitude: loc.latitude, longitude: loc.longitude);
      return;
    }

    final moved = _haversineMeters(
      lastPoint.latitude, lastPoint.longitude,
      loc.latitude, loc.longitude,
    );

    if (moved >= _minMovementMeters ||
        (loc.speed.isFinite && loc.speed >= _minSpeedMps)) {
      _movingReminderElapsed += delta;
    }

    _lastReminderSampleAt = now;
    _lastReminderSamplePoint =
        RoutePoint(latitude: loc.latitude, longitude: loc.longitude);
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} kilómetros';
    }
    return '${meters.round()} metros';
  }

  double _haversineMeters(
      double lat1, double lon1, double lat2, double lon2) =>
      HeadingTracker.haversineMeters(lat1, lon1, lat2, lon2);

  double _toRad(double deg) => deg * pi / 180;

  @override
  void dispose() {
    _exploration.disable();
    _locationService?.removeListener(_onLocationChanged);
    _tts.dispose();
    super.dispose();
  }
}