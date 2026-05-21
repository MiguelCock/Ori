import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'route_guidance_builder.dart';
import 'location_service.dart';
import 'routing_service.dart';
import 'haptic_service.dart';

typedef VoiceAnnouncer = Future<void> Function(String message);
typedef LandmarkResolver = String? Function(double lat, double lng);
typedef NavigationArrivalHandler = Future<void> Function();

// ── HU-18: Mensajes del sistema centralizados ──
// Todos los textos fijos que la app lee en voz están aquí.
// Cambiar un mensaje = cambiar solo esta clase.
class NavigationMessages {
  static String navigationStarted(String destination) =>
      'Navegación iniciada hacia $destination.';

  static String navigationStopped() => 'Navegación detenida.';

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

  static String passingLandmark(String landmark) => 'Junto a $landmark.';

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
  // Si true, cuando haya un lector de pantalla activo solo se usará
  // el anuncio accesible (TalkBack) y no se reproducirá TTS local.
  bool _suppressTtsWhenAccessibilityActive = false;

  // HU-16: Control de landmarks
  String? _lastAnnouncedLandmark;
  DateTime _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _progressConfirmationInterval = Duration(seconds: 20);
  static const Duration _minTimeBetweenLandmarks = Duration(seconds: 15);
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

  double _minInstructionDistanceMeters = 12;

  bool get isNavigating => _isNavigating;
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

  Future<void> _ensurePreferencesLoaded() async {
    if (_preferencesLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _periodicProgressConfirmationsEnabled =
          prefs.getBool(_periodicProgressPrefKey) ?? true;
    } catch (_) {
      _periodicProgressConfirmationsEnabled = true;
    }
    _preferencesLoaded = true;
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

  // ── HU-18: API pública de lectura de texto ──
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
    } catch (e) {
      _status = 'No se pudo inicializar TTS: $e';
      notifyListeners();
    }
  }

  Future<void> speakMessage(String message) async {
    await _enqueueVoiceTask(() async {
      await _initTts();
      if (!_ttsReady) return;
      try {
        await _tts.speak(message);
      } catch (e) {
        debugPrint('Error al reproducir mensaje TTS: $e');
      }
    });
  }

  // ── HU-16: Distancia restante para el chip en NavigationMapScreen ──
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

  // ── HU-16: Anuncia en voz cuánto falta ──
  Future<void> announceRemainingDistance() async {
    if (!_isNavigating || _locationService?.currentLocation == null) return;
    final loc = _locationService!.currentLocation!;
    final dist = getRemainingDistance(loc.latitude, loc.longitude);
    if (dist <= 0) return;
    final text = dist >= 1000
        ? 'Te faltan ${(dist / 1000).toStringAsFixed(1)} kilómetros para llegar a $_destinationName.'
        : 'Te faltan ${dist.round()} metros para llegar a $_destinationName.';
    await _speakAndAnnounce(text);
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
    await stopNavigation(speak: false);

    _locationService = locationService;
    _routingService = routingService;
    _announceForTalkBack = announceForTalkBack;
    _landmarkResolver = landmarkResolver;
    _onArrival = onArrival;
    _destinationName = destinationName;
    _destinationLat = destinationLat;
    _destinationLng = destinationLng;

    // HU-16: resetear landmarks
    _lastAnnouncedLandmark = null;
    _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);

    // Para la navegación automática de prueba usamos el primer tramo de la ruta
    // como referencia inicial y evitamos la espera de calibración.
    final double? initialHeadingDegrees = skipInitialCalibration
      ? (_routeLegs.isNotEmpty ? _routeLegs.first.bearingDegrees : null)
      : await _calibrateInitialHeading();
    _initialCalibratedHeadingDegrees = initialHeadingDegrees;

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

    if (_steps.isEmpty) {
      _status = NavigationMessages.noPointsForGuidance();
      notifyListeners();
      return;
    }

    _currentStepIndex = 0;
    _isNavigating = true;
    _status = 'Navegación activa hacia $_destinationName';
    _currentInstruction = _steps.first.instruction;
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = DateTime.now();
    _lastReminderSamplePoint = RoutePoint(
      latitude:
          _locationService?.currentLocation?.latitude ??
          route.polyline.first.latitude,
      longitude:
          _locationService?.currentLocation?.longitude ??
          route.polyline.first.longitude,
    );
    _lastHeadingSamplePoint = _lastReminderSamplePoint;
    _latestWalkingHeadingDegrees = null;
    _committedHeadingDegrees = null;
    _arrivalHandled = false;
    _arrivalHapticTriggered = false;

    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    // HU-17: vibración de inicio
    await HapticService.trigger(HapticEvent.navigationStarted);

    // HU-18: mensaje centralizado
    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    if (accessibilityOn) {
      await _speakAndAnnounce(
        '${NavigationMessages.navigationStarted(destinationName)} '
        'Toca una vez para repetir la instrucción. '
        'Mantén presionado para cancelar la navegación.',
      );
    } else {
      await _speakAndAnnounce(
        '${NavigationMessages.navigationStarted(destinationName)} ${_steps.first.instruction}',
      );
    }
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

    if (speak) {
      await _speakAndAnnounce(NavigationMessages.navigationStopped());
    } else {
      await _tts.stop();
    }

    notifyListeners();
  }

  Future<void> _onLocationChanged() async {
    if (!_isNavigating || _locationService?.currentLocation == null) return;

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

    if (_isFarFromRoute(current.latitude, current.longitude)) {
      await _maybeReroute(current.latitude, current.longitude);
    }

    if (_currentStepIndex >= _steps.length) return;

    final step = _steps[_currentStepIndex];
    final distanceToStep = _haversineMeters(
      current.latitude,
      current.longitude,
      step.endPoint.latitude,
      step.endPoint.longitude,
    );

    // Instrucción de navegación: prioridad máxima
    if (distanceToStep <= step.triggerDistanceMeters) {
      _currentStepIndex++;

      if (_currentStepIndex >= _steps.length) {
        // No anunciar llegada por agotamiento de pasos: solo cuando
        // realmente estemos dentro del radio del destino.
        _currentStepIndex = _steps.length - 1;
        _currentInstruction =
            'Continúa hasta llegar a $_destinationName. Te avisaré al llegar.';
        _status = 'Navegación activa hacia $_destinationName';
        notifyListeners();
        return;
      }

      _currentInstruction = _steps[_currentStepIndex].instruction;
      _commitHeadingOnTurnIfNeeded();
      _status = 'Navegación activa hacia $_destinationName';
      _movingReminderElapsed = Duration.zero;
      notifyListeners();

      // HU-17: vibración de giro
      await HapticService.trigger(HapticEvent.turnInstruction);

      await _speakAndAnnounce(_currentInstruction);
      _lastLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
      return;
    }

    // HU-16: Landmark cercano (solo si no está a punto de girar)
    final enoughTimeSinceLandmark =
        now.difference(_lastLandmarkAt) >= _minTimeBetweenLandmarks;
    final notAboutToTurn = distanceToStep > step.triggerDistanceMeters + 10;

    if (enoughTimeSinceLandmark && notAboutToTurn) {
      final landmark = _landmarkResolver?.call(
        current.latitude,
        current.longitude,
      );
      if (landmark != null && landmark != _lastAnnouncedLandmark) {
        _lastAnnouncedLandmark = landmark;
        _lastLandmarkAt = now;
        // HU-18: mensaje centralizado
        await _speakAndAnnounce(NavigationMessages.passingLandmark(landmark));
        return;
      }
    }

    // HU-12: confirmación periódica de progreso
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

    // Intento adicional de fallback háptico: algunos dispositivos/emuladores
    // pueden no respetar el canal nativo; forzamos un impacto háptico local
    // como complemento (silencioso si no está disponible).
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

    // Solo avanzar al siguiente paso inmediato, nunca saltar más de uno a la vez.
    // Esto evita que el usuario "salte" instrucciones por ruido del GPS.
    final nextIdx = _currentStepIndex + 1;
    if (nextIdx >= _steps.length) return;

    final nextPoint = _steps[nextIdx].endPoint;
    final dNext = _haversineMeters(
      lat,
      lng,
      nextPoint.latitude,
      nextPoint.longitude,
    );

    // Solo avanzar si estamos muy cerca del endPoint del próximo paso (< 12 m)
    // y más cerca de ese punto que del endPoint del paso actual.
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

    // HU-17: vibración de recálculo
    await HapticService.trigger(HapticEvent.routeRecalculated);

    // Anunciar desvío primero — el usuario sabe que algo cambió
    // mientras la ruta se recalcula en background.
    await _speakAndAnnounce(NavigationMessages.offRoute());

    final updated = await routing.buildRoute(
      originLat: originLat,
      originLng: originLng,
      destinationLat: _destinationLat,
      destinationLng: _destinationLng,
    );

    if (updated == null || updated.polyline.length < 2) {
      // HU-17: vibración de error
      await HapticService.trigger(HapticEvent.error);
      await _speakAndAnnounce(NavigationMessages.rerouteFailed());
      return;
    }

    // Usar el bearing del primer tramo de la nueva ruta como orientación inicial.
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
    notifyListeners();

    await _speakAndAnnounce(
      NavigationMessages.routeUpdated(_steps.first.instruction),
    );
  }

  // Calibración inicial de heading: pide caminar unos pasos y girar un poco.
  //
  // Estrategia:
  //   1. Pide al usuario que camine en línea recta unos pasos.
  //   2. En paralelo escucha el magnetómetro como apoyo y el GPS como base.
  //   3. En cuanto el GPS detecta >= 2.5 m de desplazamiento, calcula el
  //      bearing desde el movimiento real — eso es el heading principal.
  //   4. Si el magnetómetro también tiene muestras consistentes, lo usa solo
  //      para refinar el valor (promedio ponderado 90% GPS / 10% magnetómetro).
  //   5. Si después de 12 s no hubo suficiente movimiento, devuelve null
  //      y la primera instrucción será genérica ("avanza X metros").
  Future<double?> _calibrateInitialHeading() async {
    final loc = _locationService;
    if (loc == null) return null;

    await _speakAndAnnounce(
      'Para orientarte, mantén el teléfono apuntando al frente. '
      'Si puedes, camina en línea recta unos pasos para mejorar la precisión.',
    );

    final startPos = loc.currentLocation;
    if (startPos == null) return null;

    // Escuchar magnetómetro en paralelo, pero dar prioridad al desplazamiento GPS.
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

    // Si no hubo movimiento suficiente, usar brújula estable como respaldo.
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

      // Si GPS movió poco o hay conflicto fuerte, priorizar brújula estable.
      if (movedMeters < 4.5 || delta >= 70) {
        await _speakAndAnnounce('Orientación lista.');
        return compassHeading;
      }

      // Si ambas fuentes son razonablemente coherentes, combinarlas.
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

  // Johan: reloj de recordatorio basado en movimiento real del usuario
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

  Future<void> _speakAndAnnounce(String text) async {
    await _enqueueVoiceTask(() async {
      try {
        // Primero anunciar para servicios de accesibilidad (TalkBack/VoiceOver)
        await _announceForTalkBack?.call(text);

        // Comprobar en tiempo real si hay un lector de pantalla activo;
        // si lo hay, NO reproducimos la TTS de la app para evitar duplicidad.
        final semanticsOn = SemanticsBinding.instance.semanticsEnabled;
        final accessibleNavOn = WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .accessibleNavigation;
        final accessibilityActive =
          semanticsOn || accessibleNavOn || _suppressTtsWhenAccessibilityActive;
        if (accessibilityActive) return;

        if (_ttsReady) {
          await _tts.speak(text);
        }
      } catch (e) {
        debugPrint('Error de voz: $e');
      }
    });
  }

  Future<void> _enqueueVoiceTask(Future<void> Function() task) {
    _voiceQueue = _voiceQueue
        .then((_) => task())
        .catchError((_) {})
        .then((_) {});
    return _voiceQueue;
  }

  // Permite al UI indicar si hay un lector de pantalla activo y por tanto
  // debemos evitar reproducir TTS adicional que provoque duplicidad.
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
    _locationService?.removeListener(_onLocationChanged);
    _tts.stop();
    super.dispose();
  }
}
