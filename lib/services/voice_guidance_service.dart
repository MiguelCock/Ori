import 'dart:async';
import 'dart:math';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geojson_service.dart';
import 'haptic_service.dart';
import 'location_service.dart';
import 'route_guidance_builder.dart';
import 'routing/routing.dart';

typedef VoiceAnnouncer = Future<void> Function(String message);
typedef LandmarkResolver = String? Function(
  double lat,
  double lng,
  double? headingDegrees,
);
typedef NavigationArrivalHandler = Future<void> Function();

// Mensajes del sistema centralizados
class NavigationMessages {
  static String navigationStarted(String destination) =>
      'Navegación iniciada hacia $destination.';

  static String navigationStopped() => 'Navegación detenida.';

  static String navigationPaused() => 'Navegación pausada';

  static String navigationResumed() => 'Navegación reanudada';

  static String navigationFinished() => 'Navegación finalizada';

  static String destinationReached(String destination) =>
      'Has llegado a $destination. Navegación finalizada.';

  static String offRoute() => 'Te has alejado de la ruta. Recalculando.';

  static String routeUpdated(String firstInstruction) =>
      'Ruta actualizada. $firstInstruction';

  static String rerouteFailed() =>
      'No pude recalcular la ruta en este momento.';

  static String periodicProgress({
    required int nextInstructionMeters,
    required String remainingDistanceText,
    required String destination,
  }) =>
      'Vas correctamente por la ruta. Próxima indicación en $nextInstructionMeters metros. '
      'Faltan $remainingDistanceText para llegar a $destination.';

  static String passingLandmark(String landmark) =>
      'Estás pasando junto a $landmark.';

  static String noPointsForGuidance() =>
      'No hay suficientes puntos para guiar por voz.';
}

class _RouteLeg {
  final RoutePoint startPoint;
  final RoutePoint endPoint;
  final double distanceMeters;
  final double bearingDegrees;

  const _RouteLeg({
    required this.startPoint,
    required this.endPoint,
    required this.distanceMeters,
    required this.bearingDegrees,
  });
}

class VoiceGuidanceService extends ChangeNotifier {
  static final VoiceGuidanceService _instance =
      VoiceGuidanceService._internal();
  factory VoiceGuidanceService() => _instance;
  VoiceGuidanceService._internal();

  final FlutterTts _tts = FlutterTts();

  bool _ttsReady = false;
  bool _isNavigating = false;
  bool _isPaused = false;
  String _status = 'Navegación por voz inactiva';
  String _currentInstruction = '';

  LocationService? _locationService;
  RoutingService? _routingService;
  VoiceAnnouncer? _announceForTalkBack;
  LandmarkResolver? _landmarkResolver;
  NavigationArrivalHandler? _onArrival;

  final List<GuidanceStep> _steps = [];
  final List<_RouteLeg> _routeLegs = [];
  List<RoutePoint> _activePolyline = [];
  int _currentStepIndex = 0;

  double _destinationLat = 0;
  double _destinationLng = 0;
  String _destinationName = '';
  double? _initialCalibratedHeadingDegrees;

  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _movingReminderElapsed = Duration.zero;
  DateTime? _lastReminderSampleAt;
  RoutePoint? _lastReminderSamplePoint;
  RoutePoint? _lastHeadingSamplePoint;
  double? _latestWalkingHeadingDegrees;
  double? _committedHeadingDegrees;
  bool _periodicProgressConfirmationsEnabled = true;
  bool _preferencesLoaded = false;
  bool _arrivalHandled = false;
  bool _arrivalHapticTriggered = false;
  Future<void> _voiceQueue = Future<void>.value();
  int _voiceTaskGeneration = 0;
  bool _suppressTtsWhenAccessibilityActive = false;

  // HU-16: Control de landmarks durante navegación
  String? _lastAnnouncedLandmark;
  DateTime _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);

  // BUG-08: flag que habilita los anuncios de puntos de referencia
  bool _landmarksEnabled = true;

  // NUEVO: Modo exploración (landmarks sin navegación)
  bool _explorationModeEnabled = false;
  Timer? _explorationTimer;
  String? _lastExplorationLandmark;
  DateTime _lastExplorationLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Referencias permanentes para modo exploración
  LocationService? _permanentLocationService;
  GeoJsonService? _geoJsonServiceRef;
  VoiceAnnouncer? _permanentAnnouncer;

  static const Duration _progressConfirmationInterval = Duration(seconds: 20);
  static const Duration _minTimeBetweenLandmarks = Duration(seconds: 5);
  static const Duration _minTimeBetweenExplorationLandmarks = Duration(seconds: 8);
  static const double _minMovementMetersForReminderClock = 1.8;
  static const double _minSpeedMpsForReminderClock = 0.35;
  static const int _minHeadingSamples = 3;
  static const double _minMovementMetersForInitialHeading = 2.5;
  static const Duration _maxWaitForInitialHeading = Duration(seconds: 12);
  static const double _maxCompassHeadingDeviationDegrees = 30.0;
  static const double _minCompassConsistencyRatio = 0.75;
  static const double _straightBearingThresholdDegrees = 18.0;
  static const double _maxDistanceFromRouteMeters = 25.0;
  static const double _minMovementMetersForHeadingUpdate = 2.5;
  static const double _destinationArrivalRadiusMeters = 12.0;
  static const double _progressConfirmationTurnBufferMeters = 8.0;
  static const String _periodicProgressPrefKey =
      'periodic_progress_confirmations_enabled';
  static const String _landmarksEnabledPrefKey = 'landmarks_enabled';
  static const String _explorationModePrefKey = 'exploration_mode_enabled';

  // FIX recálculo falso: mínimo de muestras consecutivas fuera de ruta antes
  // de considerar que el usuario realmente se alejó. Evita que una lectura
  // GPS errática (spike) dispare un rerouting innecesario.
  static const int _minOffRouteSamplesBeforeReroute = 3;
  int _consecutiveOffRouteSamples = 0;

  double _minInstructionDistanceMeters = 12;

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
  bool get periodicProgressConfirmationsEnabled =>
      _periodicProgressConfirmationsEnabled;
  bool get landmarksEnabled => _landmarksEnabled;
  bool get explorationModeEnabled => _explorationModeEnabled;

  Future<void> _ensurePreferencesLoaded() async {
    if (_preferencesLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _periodicProgressConfirmationsEnabled =
          prefs.getBool(_periodicProgressPrefKey) ?? true;
      _landmarksEnabled = prefs.getBool(_landmarksEnabledPrefKey) ?? true;
      _explorationModeEnabled = prefs.getBool(_explorationModePrefKey) ?? false;
      debugPrint('📌 Preferencias cargadas - Exploración: $_explorationModeEnabled');
    } catch (_) {
      _periodicProgressConfirmationsEnabled = true;
      _landmarksEnabled = true;
      _explorationModeEnabled = false;
    }
    _preferencesLoaded = true;
    notifyListeners();

    if (_explorationModeEnabled && !_isNavigating) {
      _startExplorationMode();
    }
  }

  Future<void> setPeriodicProgressConfirmationsEnabled(bool enabled) async {
    await _ensurePreferencesLoaded();
    if (_periodicProgressConfirmationsEnabled == enabled) return;
    _periodicProgressConfirmationsEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_periodicProgressPrefKey, enabled);
    } catch (_) {}
  }

  void setLandmarksEnabled(bool enabled) {
    if (_landmarksEnabled == enabled) return;
    _landmarksEnabled = enabled;
    if (!enabled) {
      _lastAnnouncedLandmark = null;
    }
    notifyListeners();
    _saveLandmarksPreference();
  }

  Future<void> _saveLandmarksPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_landmarksEnabledPrefKey, _landmarksEnabled);
      debugPrint('💾 Preferencia landmarks guardada: $_landmarksEnabled');
    } catch (e) {
      debugPrint('Error guardando preferencia de landmarks: $e');
    }
  }

  void setExplorationModeEnabled(bool enabled) async {
    if (_explorationModeEnabled == enabled) return;
    _explorationModeEnabled = enabled;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_explorationModePrefKey, enabled);
      debugPrint('💾 Preferencia exploración guardada: $enabled');
    } catch (_) {}

    if (enabled && !_isNavigating) {
      _startExplorationMode();
    } else if (!enabled) {
      _stopExplorationMode();
    }
  }

  void setLocationService(LocationService service) {
    _permanentLocationService = service;
    // FIX: conectar el announcer del GPS para que sus mensajes lleguen al usuario.
    service.setAnnouncer((message) async {
      await _speakAndAnnounce(message);
    });
    debugPrint('📍 VoiceGuidance: LocationService permanente asignado');
  }

  void setGeoJsonService(GeoJsonService service) {
    _geoJsonServiceRef = service;
    debugPrint('📍 VoiceGuidance: GeoJsonService permanente asignado');
  }

  void setAnnouncer(VoiceAnnouncer announcer) {
    _permanentAnnouncer = announcer;
    debugPrint('📍 VoiceGuidance: Announcer permanente asignado');
  }

  void _startExplorationMode() {
    if (_explorationTimer != null) return;
    if (_isNavigating) return;

    _explorationTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      await _checkExplorationLandmarks();
    });

    debugPrint('🔍 Modo exploración INICIADO');
  }

  void _stopExplorationMode() {
    _explorationTimer?.cancel();
    _explorationTimer = null;
    _lastExplorationLandmark = null;
    debugPrint('🔍 Modo exploración DETENIDO');
  }

  Future<void> _checkExplorationLandmarks() async {
    if (!_explorationModeEnabled || _isNavigating) return;

    final location = _permanentLocationService;
    if (location?.currentLocation == null) return;

    final geoJson = _geoJsonServiceRef;
    if (geoJson == null || !geoJson.isLoaded) return;

    final loc = location!.currentLocation!;
    final now = DateTime.now();

    if (now.difference(_lastExplorationLandmarkAt).inSeconds < 8) return;

    final landmark = geoJson.getNearestLandmark(
      loc.latitude,
      loc.longitude,
      maxDistanceMeters: 25,
    );

    if (landmark != null && landmark != _lastExplorationLandmark) {
      _lastExplorationLandmark = landmark;
      _lastExplorationLandmarkAt = now;
      debugPrint('🔍 EXPLORACIÓN: $landmark');
      await _speakLandmarkExploration(landmark);
    }
  }

  Future<void> _speakLandmarkExploration(String landmark) async {
    final text = NavigationMessages.passingLandmark(landmark);

    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    if (accessibilityOn) {
      await _permanentAnnouncer?.call(text);
    } else {
      await _speakAndAnnounce(text);
    }
  }

  double? get mapReferenceHeadingDegrees {
    if (!_isNavigating) return null;
    if (_currentStepIndex == 0 && _initialCalibratedHeadingDegrees != null) {
      return _initialCalibratedHeadingDegrees;
    }
    if (_committedHeadingDegrees != null) {
      return _committedHeadingDegrees;
    }
    if (_latestWalkingHeadingDegrees != null) {
      return _latestWalkingHeadingDegrees;
    }
    if (_routeLegs.isNotEmpty) {
      final idx = _currentStepIndex < _routeLegs.length
          ? _currentStepIndex
          : _routeLegs.length - 1;
      return _routeLegs[idx].bearingDegrees;
    }
    return _initialCalibratedHeadingDegrees;
  }

  Future<void> setMinInstructionDistance(double meters) async {
    _minInstructionDistanceMeters = meters.clamp(8, 25);
    notifyListeners();
  }

  Future<void> speak(String message) async {
    await _initTts();
    await _speakAndAnnounce(message);
  }

  Future<void> _initTts() async {
    if (_ttsReady) return;
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
      _ttsReady = true;
      debugPrint('✅ TTS inicializado correctamente');
    } catch (e) {
      _status = 'No se pudo inicializar TTS: $e';
      debugPrint('❌ Error inicializando TTS: $e');
      notifyListeners();
    }
  }

  Future<void> speakMessage(String message) async {
    await _enqueueVoiceTask(() async {
      await _initTts();
      if (!_ttsReady) return;
      try {
        await _tts.speak(message);
        debugPrint('🔊 SPEAK: $message');
      } catch (e) {
        debugPrint('Error al reproducir mensaje TTS: $e');
      }
    });
  }

  /// Detener cualquier reproducción TTS en curso.
  Future<void> stopSpeaking() async {
    _voiceTaskGeneration++;
    try {
      await _tts.stop();
      debugPrint('⏹️ TTS detenido');
    } catch (e) {
      debugPrint('Error deteniendo TTS: $e');
    }
  }

  double getRemainingDistance(double currentLat, double currentLng) {
    if (_steps.isEmpty || _currentStepIndex >= _steps.length) return 0;

    double total = 0;
    for (int i = _currentStepIndex; i < _steps.length; i++) {
      final step = _steps[i];
      if (i == _currentStepIndex) {
        total += _haversineMeters(
          currentLat,
          currentLng,
          step.endPoint.latitude,
          step.endPoint.longitude,
        );
      } else {
        total += _haversineMeters(
          _steps[i - 1].endPoint.latitude,
          _steps[i - 1].endPoint.longitude,
          step.endPoint.latitude,
          step.endPoint.longitude,
        );
      }
    }
    return total;
  }

  Future<void> announceRemainingDistance() async {
    if (!_isNavigating ||
        _isPaused ||
        _locationService?.currentLocation == null) {
      return;
    }
    final loc = _locationService!.currentLocation!;
    final dist = getRemainingDistance(loc.latitude, loc.longitude);
    if (dist <= 0) return;
    final text = dist >= 1000
        ? 'Te faltan ${(dist / 1000).toStringAsFixed(1)} kilómetros para llegar a $_destinationName.'
        : 'Te faltan ${dist.round()} metros para llegar a $_destinationName.';
    await _speakAndAnnounce(text);
  }

  void _replaceActiveRoute(
    RouteResult route, {
    required double? initialHeadingDegrees,
  }) {
    _activePolyline = List<RoutePoint>.from(route.polyline);
    _routeLegs
      ..clear()
      ..addAll(_compactRouteLegs(_activePolyline));
    _steps
      ..clear()
      ..addAll(
        RouteGuidanceBuilder.buildSteps(
          polyline: _activePolyline,
          destinationLat: _destinationLat,
          destinationLng: _destinationLng,
          destinationName: _destinationName,
          landmarkResolver: _landmarkResolver,
          initialHeadingDegrees: initialHeadingDegrees,
          minInstructionDistanceMeters: _minInstructionDistanceMeters,
        ),
      );
    _currentStepIndex = 0;
    _currentInstruction = _steps.isEmpty ? '' : _steps.first.instruction;
    // Resetear contador de muestras fuera de ruta al reemplazar la ruta.
    _consecutiveOffRouteSamples = 0;
  }

  RoutePoint? _currentNavigationPoint(RouteResult route) {
    final current = _locationService?.currentLocation;
    if (current != null) {
      return RoutePoint(
        latitude: current.latitude,
        longitude: current.longitude,
      );
    }

    if (route.polyline.isEmpty) return null;
    return route.polyline.first;
  }

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
    await _initTts();

    if (_explorationModeEnabled) {
      _stopExplorationMode();
    }

    await stopNavigation(speak: false);

    _locationService = locationService;
    _routingService = routingService;
    _announceForTalkBack = announceForTalkBack;
    _landmarkResolver = landmarkResolver;
    _onArrival = onArrival;
    _destinationName = destinationName;
    _destinationLat = destinationLat;
    _destinationLng = destinationLng;

    _lastAnnouncedLandmark = null;
    _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
    _consecutiveOffRouteSamples = 0;

    final double? initialHeadingDegrees = skipInitialCalibration
      ? (_routeLegs.isNotEmpty ? _routeLegs.first.bearingDegrees : null)
      : await _calibrateInitialHeading();
    _initialCalibratedHeadingDegrees = initialHeadingDegrees;

    _replaceActiveRoute(route, initialHeadingDegrees: initialHeadingDegrees);

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
    _lastReminderSamplePoint = _currentNavigationPoint(route);
    _lastHeadingSamplePoint = _lastReminderSamplePoint;
    _latestWalkingHeadingDegrees = null;
    _committedHeadingDegrees = null;
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;

    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    await HapticService.trigger(HapticEvent.navigationStarted);

    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    if (accessibilityOn) {
      // FIX: mensaje corregido — ya no menciona "mantén presionado"
      await _speakAndAnnounce(
        '${NavigationMessages.navigationStarted(destinationName)} '
        '${_steps.first.instruction} '
        'Toca la pantalla para repetir la indicación. '
        'Usa el botón Finalizar navegación para salir.',
      );
    } else {
      await _speakAndAnnounce(
        '${NavigationMessages.navigationStarted(destinationName)} ${_steps.first.instruction}',
      );
    }
  }

  Future<void> pauseNavigation({bool speak = true}) async {
    if (!_isNavigating || _isPaused) return;

    _locationService?.removeListener(_onLocationChanged);
    _isPaused = true;
    _status = NavigationMessages.navigationPaused();
    notifyListeners();

    await _tts.stop();
    if (speak) {
      await _speakAndAnnounce(NavigationMessages.navigationPaused());
    }
  }

  Future<void> resumeNavigation({RouteResult? route, bool speak = true}) async {
    if (!_isNavigating && route == null) return;

    if (route != null) {
      final double? resumeHeadingDegrees = route.polyline.length >= 2
          ? _bearingDegrees(route.polyline[0], route.polyline[1])
          : mapReferenceHeadingDegrees;
      _replaceActiveRoute(route, initialHeadingDegrees: resumeHeadingDegrees);
    }

    if (_steps.isEmpty) {
      _status = NavigationMessages.noPointsForGuidance();
      notifyListeners();
      return;
    }

    final current = _locationService?.currentLocation;
    final RoutePoint? resumePoint = current == null
        ? (_activePolyline.isEmpty ? null : _activePolyline.first)
        : RoutePoint(latitude: current.latitude, longitude: current.longitude);

    _isNavigating = true;
    _isPaused = false;
    _status = 'Navegación activa hacia $_destinationName';
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = DateTime.now();
    _lastReminderSamplePoint = resumePoint;
    _lastHeadingSamplePoint = resumePoint;
    _latestWalkingHeadingDegrees = null;
    _committedHeadingDegrees = null;
    _lastAnnouncedLandmark = null;
    _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;
    _consecutiveOffRouteSamples = 0;

    _locationService?.removeListener(_onLocationChanged);
    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    if (speak) {
      final message = _currentInstruction.isEmpty
          ? NavigationMessages.navigationResumed()
          : '${NavigationMessages.navigationResumed()}. $_currentInstruction';
      await _speakAndAnnounce(message);
    }
  }

  Future<void> finishNavigation({bool speak = true}) async {
    if (speak) {
      await _speakAndAnnounce(NavigationMessages.navigationFinished());
    }
    await stopNavigation(speak: false);
  }

  Future<void> stopNavigation({bool speak = true}) async {
    _locationService?.removeListener(_onLocationChanged);
    _locationService?.stopSimulation();
    _locationService = null;
    _routingService = null;
    _landmarkResolver = null;
    _onArrival = null;

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
    _lastHeadingSamplePoint = null;
    _latestWalkingHeadingDegrees = null;
    _committedHeadingDegrees = null;
    _initialCalibratedHeadingDegrees = null;
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;
    _consecutiveOffRouteSamples = 0;

    if (speak) {
      await _speakAndAnnounce(NavigationMessages.navigationStopped());
    } else {
      await _tts.stop();
    }

    notifyListeners();

    if (_explorationModeEnabled && !_isNavigating) {
      _startExplorationMode();
    }
  }

  Future<void> _onLocationChanged() async {
    if (!_isNavigating ||
        _isPaused ||
        _locationService?.currentLocation == null) {
      return;
    }

    final current = _locationService!.currentLocation!;
    final now = DateTime.now();

    final distanceToDestination = _haversineMeters(
      current.latitude,
      current.longitude,
      _destinationLat,
      _destinationLng,
    );
    if (!_arrivalHandled &&
        distanceToDestination <= _destinationArrivalRadiusMeters) {
      await _completeArrival();
      return;
    }

    _updateMovingReminderClock(current, now);
    _updateWalkingHeading(current);
    _syncStepIndexWithProgress(current.latitude, current.longitude);

    // FIX recálculo falso: acumular muestras consecutivas fuera de ruta.
    // Solo recalcular cuando hay suficientes muestras seguidas, lo que
    // descarta spikes GPS puntuales que no representan una desviación real.
    if (_isFarFromRoute(current.latitude, current.longitude)) {
      _consecutiveOffRouteSamples++;
      if (_consecutiveOffRouteSamples >= _minOffRouteSamplesBeforeReroute) {
        _consecutiveOffRouteSamples = 0;
        await _maybeReroute(current.latitude, current.longitude);
      }
    } else {
      // En ruta: resetear el contador
      _consecutiveOffRouteSamples = 0;
    }

    if (_currentStepIndex >= _steps.length) return;

    final step = _steps[_currentStepIndex];
    final distanceToStep = _haversineMeters(
      current.latitude,
      current.longitude,
      step.endPoint.latitude,
      step.endPoint.longitude,
    );

    if (distanceToStep <= 2.0) {
      if (_currentStepIndex + 1 < _steps.length) {
        _currentStepIndex++;
        _currentInstruction = _steps[_currentStepIndex].instruction;
        _commitHeadingOnTurnIfNeeded();
        _movingReminderElapsed = Duration.zero;
        notifyListeners();
      }
      return;
    }

    if (distanceToStep <= step.triggerDistanceMeters) {
      _currentStepIndex++;

      if (_currentStepIndex >= _steps.length) {
        _currentStepIndex = _steps.length - 1;

        // FIX instrucción final estática: incluir distancia restante
        // para que al tocar la pantalla el usuario sepa cuánto falta.
        final remaining = getRemainingDistance(
          current.latitude,
          current.longitude,
        );
        final remainingText = remaining > 0
            ? _formatDistance(remaining)
            : '';
        _currentInstruction = remainingText.isNotEmpty
            ? 'Continúa recto. Faltan $remainingText para llegar a $_destinationName.'
            : 'Continúa hasta llegar a $_destinationName. Te avisaré al llegar.';

        _status = 'Navegación activa hacia $_destinationName';
        notifyListeners();
        return;
      }

      _currentInstruction = _steps[_currentStepIndex].instruction;
      _commitHeadingOnTurnIfNeeded();
      _status = 'Navegación activa hacia $_destinationName';
      _movingReminderElapsed = Duration.zero;
      notifyListeners();

      await HapticService.trigger(HapticEvent.turnInstruction);

      await _speakAndAnnounce(_currentInstruction);
      _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
      return;
    }

    // Landmarks durante navegación (solo si el toggle está activado)
    final enoughTimeSinceLandmark =
        now.difference(_lastLandmarkAt) >= _minTimeBetweenLandmarks;
    final notAboutToTurn = distanceToStep > step.triggerDistanceMeters + 10;

    if (_landmarksEnabled && enoughTimeSinceLandmark && notAboutToTurn) {
      final headingDegrees = mapReferenceHeadingDegrees;
      final landmark = _landmarkResolver?.call(
        current.latitude,
        current.longitude,
        headingDegrees,
      );
      if (landmark != null && landmark != _lastAnnouncedLandmark) {
        _lastAnnouncedLandmark = landmark;
        _lastLandmarkAt = now;
        debugPrint('🗣️ LANDMARK (navegación): $landmark');
        await _speakLandmark(NavigationMessages.passingLandmark(landmark));
        return;
      }
    }
    
    if (_currentStepIndex == _steps.length - 1) {
      final remaining = getRemainingDistance(
        current.latitude,
        current.longitude,
      );
      final remainingText = remaining > 0 ? _formatDistance(remaining) : '';
      if (remainingText.isNotEmpty) {
        _currentInstruction =
            'Continúa recto. Faltan $remainingText para llegar a $_destinationName.';
        notifyListeners();
      }
    }

    final shouldConfirmProgress =
        _periodicProgressConfirmationsEnabled &&
        _movingReminderElapsed >= _progressConfirmationInterval &&
        distanceToStep >
            step.triggerDistanceMeters + _progressConfirmationTurnBufferMeters;

    if (shouldConfirmProgress) {
      _movingReminderElapsed -= _progressConfirmationInterval;
      final remainingMeters = getRemainingDistance(
        current.latitude,
        current.longitude,
      );
      final remainingText = remainingMeters >= 1000
          ? '${(remainingMeters / 1000).toStringAsFixed(1)} kilómetros'
          : '${remainingMeters.round()} metros';
      await _speakAndAnnounce(
        NavigationMessages.periodicProgress(
          nextInstructionMeters: distanceToStep.round(),
          remainingDistanceText: remainingText,
          destination: _destinationName,
        ),
      );
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} kilómetros';
    return '${meters.round()} metros';
  }

  Future<void> _completeArrival() async {
    if (_arrivalHandled) return;
    _arrivalHandled = true;

    _currentInstruction = NavigationMessages.destinationReached(
      _destinationName,
    );
    _status = 'Destino alcanzado';
    notifyListeners();

    if (!_arrivalHapticTriggered) {
      _arrivalHapticTriggered = true;
      await HapticService.trigger(HapticEvent.destinationReached);
    }

    final onArrival = _onArrival;
    if (onArrival != null) {
      unawaited(onArrival());
    }

    try {
      HapticFeedback.heavyImpact();
    } catch (_) {}

    await _speakAndAnnounce(
      NavigationMessages.destinationReached(_destinationName),
    );
    await stopNavigation(speak: false);
  }

  bool _isFarFromRoute(double lat, double lng) {
    if (_activePolyline.length < 2) return false;
    double best = double.infinity;
    for (var i = 0; i < _activePolyline.length - 1; i++) {
      final d = _distanceToSegmentMeters(
        lat,
        lng,
        _activePolyline[i].latitude,
        _activePolyline[i].longitude,
        _activePolyline[i + 1].latitude,
        _activePolyline[i + 1].longitude,
      );
      if (d < best) best = d;
    }
    return best > _maxDistanceFromRouteMeters;
  }

  double _distanceToSegmentMeters(
    double pLat,
    double pLng,
    double aLat,
    double aLng,
    double bLat,
    double bLng,
  ) {
    const metersPerDegreeLat = 111320.0;
    final refLat = (aLat + bLat + pLat) / 3;
    final metersPerDegreeLng = metersPerDegreeLat * cos(_toRad(refLat));

    final ax = aLng * metersPerDegreeLng, ay = aLat * metersPerDegreeLat;
    final bx = bLng * metersPerDegreeLng, by = bLat * metersPerDegreeLat;
    final px = pLng * metersPerDegreeLng, py = pLat * metersPerDegreeLat;

    final abx = bx - ax, aby = by - ay;
    final apx = px - ax, apy = py - ay;
    final ab2 = abx * abx + aby * aby;
    if (ab2 == 0) return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));

    final t = ((apx * abx) + (apy * aby)) / ab2;
    final tc = t.clamp(0.0, 1.0);
    final cx = ax + abx * tc, cy = ay + aby * tc;
    return sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  void _syncStepIndexWithProgress(double lat, double lng) {
    if (_steps.isEmpty || _currentStepIndex >= _steps.length) return;

    final nextIdx = _currentStepIndex + 1;
    if (nextIdx >= _steps.length) return;

    final nextPoint = _steps[nextIdx].endPoint;
    final dNext = _haversineMeters(
      lat,
      lng,
      nextPoint.latitude,
      nextPoint.longitude,
    );

    if (dNext > 12) return;

    final currentPoint = _steps[_currentStepIndex].endPoint;
    final dCurrent = _haversineMeters(
      lat,
      lng,
      currentPoint.latitude,
      currentPoint.longitude,
    );
    if (dNext >= dCurrent) return;

    _currentStepIndex = nextIdx;
    _currentInstruction = _steps[_currentStepIndex].instruction;
    _commitHeadingOnTurnIfNeeded();
    _movingReminderElapsed = Duration.zero;
    notifyListeners();
  }

  Future<void> _maybeReroute(double originLat, double originLng) async {
    final now = DateTime.now();
    if (now.difference(_lastRerouteAt).inSeconds < 15) return;
    _lastRerouteAt = now;

    final routing = _routingService;
    if (routing == null) return;

    await HapticService.trigger(HapticEvent.routeRecalculated);

    await _speakAndAnnounce(NavigationMessages.offRoute());

    final updated = await routing.buildRoute(
      originLat: originLat,
      originLng: originLng,
      destinationLat: _destinationLat,
      destinationLng: _destinationLng,
    );

    if (updated == null || updated.polyline.length < 2) {
      await HapticService.trigger(HapticEvent.error);
      await _speakAndAnnounce(NavigationMessages.rerouteFailed());
      return;
    }

    final newInitialHeading = _bearingDegrees(
      updated.polyline[0],
      updated.polyline[1],
    );

    _activePolyline = List<RoutePoint>.from(updated.polyline);
    _routeLegs
      ..clear()
      ..addAll(_compactRouteLegs(_activePolyline));
    _steps
      ..clear()
      ..addAll(
        RouteGuidanceBuilder.buildSteps(
          polyline: _activePolyline,
          destinationLat: _destinationLat,
          destinationLng: _destinationLng,
          destinationName: _destinationName,
          landmarkResolver: _landmarkResolver,
          initialHeadingDegrees: newInitialHeading,
          minInstructionDistanceMeters: _minInstructionDistanceMeters,
        ),
      );
    _currentStepIndex = 0;
    _currentInstruction = _steps.first.instruction;
    _status = 'Ruta actualizada hacia $_destinationName';
    _lastAnnouncedLandmark = null;
    _movingReminderElapsed = Duration.zero;
    _lastHeadingSamplePoint = RoutePoint(
      latitude: originLat,
      longitude: originLng,
    );
    _latestWalkingHeadingDegrees = null;
    _committedHeadingDegrees = null;
    _consecutiveOffRouteSamples = 0;
    notifyListeners();

    await _speakAndAnnounce(
      NavigationMessages.routeUpdated(_steps.first.instruction),
    );
  }

  Future<double?> _calibrateInitialHeading() async {
    final loc = _locationService;
    if (loc == null) return null;

    await _speakAndAnnounce(
      'Para orientarte, mantén el teléfono apuntando al frente. '
      'Si puedes, camina en línea recta unos pasos para mejorar la precisión.',
    );

    final startPos = loc.currentLocation;
    if (startPos == null) return null;

    final compassSamples = <double>[];
    StreamSubscription<CompassEvent>? compassSub;
    final compassStream = FlutterCompass.events;
    if (compassStream != null) {
      compassSub = compassStream.listen((event) {
        final h = event.heading;
        if (h != null && h.isFinite) compassSamples.add((h + 360) % 360);
      }, onError: (_) {});
    }

    double? gpsHeading;
    double movedMeters = 0;
    const checkInterval = Duration(milliseconds: 400);
    var elapsed = Duration.zero;

    try {
      while (elapsed < _maxWaitForInitialHeading) {
        await Future<void>.delayed(checkInterval);
        elapsed += checkInterval;

        final current = loc.currentLocation;
        if (current == null) continue;

        movedMeters = _haversineMeters(
          startPos.latitude,
          startPos.longitude,
          current.latitude,
          current.longitude,
        );

        if (movedMeters >= _minMovementMetersForInitialHeading) {
          gpsHeading = _bearingDegrees(
            RoutePoint(
              latitude: startPos.latitude,
              longitude: startPos.longitude,
            ),
            RoutePoint(
              latitude: current.latitude,
              longitude: current.longitude,
            ),
          );
          break;
        }
      }
    } finally {
      await compassSub?.cancel();
    }

    final compassHeading = _stableCompassHeading(compassSamples);

    if (gpsHeading == null) {
      if (compassHeading != null) {
        await _speakAndAnnounce('Orientación lista con brújula.');
        return compassHeading;
      }

      await _speakAndAnnounce(
        'No se detectó movimiento. '
        'La primera indicación puede no tener dirección precisa.',
      );
      return null;
    }

    if (compassHeading != null) {
      final delta = _normalizeAngle(compassHeading - gpsHeading).abs();

      if (movedMeters < 4.5 || delta >= 70) {
        await _speakAndAnnounce('Orientación lista.');
        return compassHeading;
      }

      final gpsRad = _toRad(gpsHeading);
      final compassRad = _toRad(compassHeading);
      final sinMean = 0.8 * sin(gpsRad) + 0.2 * sin(compassRad);
      final cosMean = 0.8 * cos(gpsRad) + 0.2 * cos(compassRad);
      final combined = (atan2(sinMean, cosMean) * 180 / pi + 360) % 360;
      await _speakAndAnnounce('Orientación lista.');
      return combined;
    }

    await _speakAndAnnounce('Orientación lista.');
    return gpsHeading;
  }

  double? _stableCompassHeading(List<double> samples) {
    if (samples.length < _minHeadingSamples) return null;

    final mean = _circularMeanDegrees(samples);
    var consistentCount = 0;

    for (final sample in samples) {
      final deviation = _normalizeAngle(sample - mean).abs();
      if (deviation <= _maxCompassHeadingDeviationDegrees) {
        consistentCount++;
      }
    }

    final consistency = consistentCount / samples.length;
    if (consistency < _minCompassConsistencyRatio) return null;
    return mean;
  }

  double _circularMeanDegrees(List<double> samples) {
    double sumSin = 0;
    double sumCos = 0;

    for (final heading in samples) {
      final rad = _toRad(heading);
      sumSin += sin(rad);
      sumCos += cos(rad);
    }

    if (sumSin.abs() < 1e-9 && sumCos.abs() < 1e-9) {
      return samples.last;
    }

    final meanRad = atan2(sumSin / samples.length, sumCos / samples.length);
    return (meanRad * 180.0 / pi + 360) % 360;
  }

  void _updateMovingReminderClock(LocationData current, DateTime now) {
    final lastAt = _lastReminderSampleAt;
    final lastPoint = _lastReminderSamplePoint;

    if (lastAt == null || lastPoint == null) {
      _lastReminderSampleAt = now;
      _lastReminderSamplePoint = RoutePoint(
        latitude: current.latitude,
        longitude: current.longitude,
      );
      return;
    }

    final delta = now.difference(lastAt);
    if (delta <= Duration.zero) {
      _lastReminderSampleAt = now;
      _lastReminderSamplePoint = RoutePoint(
        latitude: current.latitude,
        longitude: current.longitude,
      );
      return;
    }

    final movedMeters = _haversineMeters(
      lastPoint.latitude,
      lastPoint.longitude,
      current.latitude,
      current.longitude,
    );
    final movingByDistance = movedMeters >= _minMovementMetersForReminderClock;
    final movingBySpeed =
        current.speed.isFinite && current.speed >= _minSpeedMpsForReminderClock;

    if (movingByDistance || movingBySpeed) {
      _movingReminderElapsed += delta;
    }

    _lastReminderSampleAt = now;
    _lastReminderSamplePoint = RoutePoint(
      latitude: current.latitude,
      longitude: current.longitude,
    );
  }

  void _updateWalkingHeading(LocationData current) {
    final currentPoint = RoutePoint(
      latitude: current.latitude,
      longitude: current.longitude,
    );
    final lastPoint = _lastHeadingSamplePoint;

    if (lastPoint == null) {
      _lastHeadingSamplePoint = currentPoint;
      return;
    }

    final movedMeters = _haversineMeters(
      lastPoint.latitude,
      lastPoint.longitude,
      currentPoint.latitude,
      currentPoint.longitude,
    );

    if (movedMeters >= _minMovementMetersForHeadingUpdate) {
      _latestWalkingHeadingDegrees = _bearingDegrees(lastPoint, currentPoint);
      _lastHeadingSamplePoint = currentPoint;
    }
  }

  void _commitHeadingOnTurnIfNeeded() {
    if (_currentStepIndex < 0 || _currentStepIndex >= _steps.length) return;
    final instruction = _steps[_currentStepIndex].instruction.toUpperCase();
    final isTurn =
        instruction.contains('GIRA') || instruction.contains('MEDIA VUELTA');
    if (!isTurn) return;

    if (_latestWalkingHeadingDegrees != null) {
      _committedHeadingDegrees = _latestWalkingHeadingDegrees;
    } else if (_routeLegs.isNotEmpty) {
      final idx = _currentStepIndex < _routeLegs.length
          ? _currentStepIndex
          : _routeLegs.length - 1;
      _committedHeadingDegrees = _routeLegs[idx].bearingDegrees;
    }
  }

  List<_RouteLeg> _compactRouteLegs(List<RoutePoint> polyline) {
    if (polyline.length < 2) return const [];

    final legs = <_RouteLeg>[];
    var segmentStart = polyline.first;
    var segmentEnd = polyline[1];
    var segmentDistance = _haversineMeters(
      segmentStart.latitude,
      segmentStart.longitude,
      segmentEnd.latitude,
      segmentEnd.longitude,
    );
    var segmentBearing = _bearingDegrees(segmentStart, segmentEnd);

    for (var i = 2; i < polyline.length; i++) {
      final nextPoint = polyline[i];
      final nextBearing = _bearingDegrees(segmentEnd, nextPoint);
      final delta = _normalizeAngle(nextBearing - segmentBearing);

      if (delta.abs() <= _straightBearingThresholdDegrees) {
        segmentDistance += _haversineMeters(
          segmentEnd.latitude,
          segmentEnd.longitude,
          nextPoint.latitude,
          nextPoint.longitude,
        );
        segmentEnd = nextPoint;
        continue;
      }

      legs.add(
        _RouteLeg(
          startPoint: segmentStart,
          endPoint: segmentEnd,
          distanceMeters: segmentDistance,
          bearingDegrees: segmentBearing,
        ),
      );

      segmentStart = segmentEnd;
      segmentEnd = nextPoint;
      segmentDistance = _haversineMeters(
        segmentStart.latitude,
        segmentStart.longitude,
        segmentEnd.latitude,
        segmentEnd.longitude,
      );
      segmentBearing = _bearingDegrees(segmentStart, segmentEnd);
    }

    legs.add(
      _RouteLeg(
        startPoint: segmentStart,
        endPoint: segmentEnd,
        distanceMeters: segmentDistance,
        bearingDegrees: segmentBearing,
      ),
    );

    return legs;
  }

  Future<void> _speakLandmark(String text) async {
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}

    debugPrint('🔊 REPRODUCIENDO LANDMARK: $text');
    await _speakAndAnnounce(text);
  }

  Future<void> _speakAndAnnounce(String text) async {
    await _enqueueVoiceTask(() async {
      try {
        await _initTts();

        final semanticsOn = SemanticsBinding.instance.semanticsEnabled;
        final accessibleNavOn = WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .accessibleNavigation;

        final accessibilityActive = semanticsOn || accessibleNavOn || _suppressTtsWhenAccessibilityActive;

        if (accessibilityActive) {
          if (_announceForTalkBack != null) {
            await _announceForTalkBack!.call(text);
            return;
          }
          if (_permanentAnnouncer != null) {
            await _permanentAnnouncer!.call(text);
            return;
          }
        }

        if (!_ttsReady) {
          debugPrint('❌ TTS no listo para: $text');
          return;
        }

        debugPrint('🔊 SPEAK: $text');
        await _tts.speak(text);
      } catch (e) {
        debugPrint('Error de voz: $e');
      }
    });
  }

  Future<void> _enqueueVoiceTask(Future<void> Function() task) {
    final generation = _voiceTaskGeneration;
    _voiceQueue = _voiceQueue
        .then((_) async {
          if (generation != _voiceTaskGeneration) return;
          await task();
        })
        .catchError((_) {})
        .then((_) {});
    return _voiceQueue;
  }

  void setSuppressTtsWhenAccessibility(bool suppress) {
    _suppressTtsWhenAccessibilityActive = suppress;
  }

  Future<void> completeNavigationIfActive() async {
    if (!_isNavigating || _arrivalHandled) return;
    await _completeArrival();
  }

  double _bearingDegrees(RoutePoint a, RoutePoint b) {
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final bearing = atan2(y, x) * 180.0 / pi;
    return (bearing + 360) % 360;
  }

  double _normalizeAngle(double angle) {
    double a = angle;
    while (a > 180) {
      a -= 360;
    }
    while (a < -180) {
      a += 360;
    }
    return a;
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return earthRadius * 2 * asin(sqrt(a));
  }

  double _toRad(double deg) => deg * pi / 180.0;

  @override
  void dispose() {
    _stopExplorationMode();
    _locationService?.removeListener(_onLocationChanged);
    _tts.stop();
    super.dispose();
  }
}