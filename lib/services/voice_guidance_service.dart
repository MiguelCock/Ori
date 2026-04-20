import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'location_service.dart';
import 'routing_service.dart';

typedef VoiceAnnouncer = Future<void> Function(String message);
typedef LandmarkResolver = String? Function(double lat, double lng);

class GuidanceStep {
  final RoutePoint endPoint;
  final String instruction;
  final double triggerDistanceMeters;

  const GuidanceStep({
    required this.endPoint,
    required this.instruction,
    required this.triggerDistanceMeters,
  });
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

  final List<GuidanceStep> _steps = [];
  final List<_RouteLeg> _routeLegs = [];
  List<RoutePoint> _activePolyline = [];
  int _currentStepIndex = 0;

  double _destinationLat = 0;
  double _destinationLng = 0;
  String _destinationName = '';

  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _movingReminderElapsed = Duration.zero;
  DateTime? _lastReminderSampleAt;
  RoutePoint? _lastReminderSamplePoint;

  static const Duration _reminderInterval = Duration(seconds: 20);
  static const double _minMovementMetersForReminderClock = 1.8;
  static const double _minSpeedMpsForReminderClock = 0.35;
  static const Duration _headingCalibrationWindow = Duration(seconds: 5);
  static const int _minHeadingSamples = 8;
  static const double _straightBearingThresholdDegrees = 18.0;
  static const double _turnBearingThresholdDegrees = 28.0;

  double _minInstructionDistanceMeters = 12;

  bool get isNavigating => _isNavigating;
  String get status => _status;
  String get currentInstruction => _currentInstruction;
  int get remainingSteps => max(0, _steps.length - _currentStepIndex);
  double get minInstructionDistanceMeters => _minInstructionDistanceMeters;

  Future<void> setMinInstructionDistance(double meters) async {
    _minInstructionDistanceMeters = meters.clamp(8, 25);
    notifyListeners();
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
    await _initTts();
    if (!_ttsReady) return;
    try {
      await _tts.stop();
      await _tts.speak(message);
    } catch (e) {
      debugPrint('Error al reproducir mensaje TTS: $e');
    }
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
  }) async {
    await _initTts();
    await stopNavigation(speak: false);

    _locationService = locationService;
    _routingService = routingService;
    _announceForTalkBack = announceForTalkBack;
    _landmarkResolver = landmarkResolver;
    _destinationName = destinationName;
    _destinationLat = destinationLat;
    _destinationLng = destinationLng;

    final calibratedHeading = await _calibrateHeadingWithMagnetometer();
    final initialHeadingDegrees =
        calibratedHeading ?? _locationService?.currentLocation?.heading;

    _activePolyline = List<RoutePoint>.from(route.polyline);
    _routeLegs
      ..clear()
      ..addAll(_compactRouteLegs(_activePolyline));
    _steps
      ..clear()
      ..addAll(
        _buildStepsFromLegs(
          _routeLegs,
          initialHeadingDegrees: initialHeadingDegrees,
        ),
      );

    if (_steps.isEmpty) {
      _status = 'No hay suficientes puntos para guiar por voz.';
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

    _locationService?.addListener(_onLocationChanged);
    notifyListeners();

    await _speakAndAnnounce(
      'Navegación iniciada hacia $_destinationName. ${_steps.first.instruction}',
    );
  }

  Future<void> stopNavigation({bool speak = true}) async {
    _locationService?.removeListener(_onLocationChanged);
    _locationService = null;
    _routingService = null;
    _landmarkResolver = null;

    _steps.clear();
    _routeLegs.clear();
    _activePolyline = [];
    _currentStepIndex = 0;
    _isNavigating = false;
    _currentInstruction = '';
    _status = 'Navegación por voz inactiva';
    _movingReminderElapsed = Duration.zero;
    _lastReminderSampleAt = null;
    _lastReminderSamplePoint = null;

    if (speak) {
      await _speakAndAnnounce('Navegación detenida.');
    } else {
      await _tts.stop();
    }

    notifyListeners();
  }

  Future<void> _onLocationChanged() async {
    if (!_isNavigating || _locationService?.currentLocation == null) return;

    final current = _locationService!.currentLocation!;
    final now = DateTime.now();
    _updateMovingReminderClock(current, now);

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

    if (distanceToStep <= step.triggerDistanceMeters) {
      _currentStepIndex++;

      if (_currentStepIndex >= _steps.length) {
        final arrivalMessage = _arrivalInstruction(_routeLegs.last);
        _currentInstruction = arrivalMessage;
        _status = 'Destino alcanzado';
        notifyListeners();
        await _speakAndAnnounce(arrivalMessage);
        await stopNavigation(speak: false);
        return;
      }

      _currentInstruction = _steps[_currentStepIndex].instruction;
      _status = 'Navegación activa hacia $_destinationName';
      _movingReminderElapsed = Duration.zero;
      notifyListeners();
      await _speakAndAnnounce(_currentInstruction);
      return;
    }

    if (_movingReminderElapsed >= _reminderInterval) {
      _movingReminderElapsed -= _reminderInterval;
      final rounded = distanceToStep.round();
      final reference = _landmarkResolver?.call(
        current.latitude,
        current.longitude,
      );
      final referenceText = reference == null
          ? ''
          : ' Vas pasando junto a $reference.';
      await _speakAndAnnounce(
        'Sigue en linea recta. Proxima indicacion en $rounded metros.$referenceText',
      );
    }
  }

  bool _isFarFromRoute(double lat, double lng) {
    if (_activePolyline.isEmpty) return false;
    double best = double.infinity;

    for (final p in _activePolyline) {
      final d = _haversineMeters(lat, lng, p.latitude, p.longitude);
      if (d < best) best = d;
    }
    return best > 28;
  }

  Future<void> _maybeReroute(double originLat, double originLng) async {
    final now = DateTime.now();
    if (now.difference(_lastRerouteAt).inSeconds < 15) return;
    _lastRerouteAt = now;

    final routing = _routingService;
    if (routing == null) return;

    await _speakAndAnnounce('Te has alejado de la ruta. Recalculando.');

    final updated = await routing.buildRoute(
      originLat: originLat,
      originLng: originLng,
      destinationLat: _destinationLat,
      destinationLng: _destinationLng,
    );

    if (updated == null || updated.polyline.length < 2) {
      await _speakAndAnnounce('No pude recalcular la ruta en este momento.');
      return;
    }

    _activePolyline = List<RoutePoint>.from(updated.polyline);
    _routeLegs
      ..clear()
      ..addAll(_compactRouteLegs(_activePolyline));
    _steps
      ..clear()
      ..addAll(
        _buildStepsFromLegs(
          _routeLegs,
          initialHeadingDegrees: _locationService?.currentLocation?.heading,
        ),
      );
    _currentStepIndex = 0;
    _currentInstruction = _steps.first.instruction;
    _status = 'Ruta actualizada hacia $_destinationName';
    _movingReminderElapsed = Duration.zero;
    notifyListeners();

    await _speakAndAnnounce('Ruta actualizada. ${_steps.first.instruction}');
  }

  Future<double?> _calibrateHeadingWithMagnetometer() async {
    await _speakAndAnnounce(
      'Sostén el celular frente a ti durante cinco segundos para calibrar tu orientación.',
    );

    final stream = FlutterCompass.events;
    if (stream == null) {
      return null;
    }

    final samples = <double>[];
    StreamSubscription<CompassEvent>? sub;

    try {
      sub = stream.listen((event) {
        final heading = event.heading;
        if (heading == null || !heading.isFinite) return;
        samples.add((heading + 360) % 360);
      }, onError: (_) {});

      await Future.delayed(_headingCalibrationWindow);
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
    }

    if (samples.length < _minHeadingSamples) {
      return null;
    }

    return _circularMeanDegrees(samples);
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

  List<GuidanceStep> _buildStepsFromLegs(
    List<_RouteLeg> legs, {
    double? initialHeadingDegrees,
  }) {
    if (legs.isEmpty) return [];

    final steps = <GuidanceStep>[];
    String? lastReference;

    for (int i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final reference = _landmarkResolver?.call(
        leg.endPoint.latitude,
        leg.endPoint.longitude,
      );
      final includeReference = reference != null && reference != lastReference;
      if (reference != null) {
        lastReference = reference;
      }

      final instruction = _legInstruction(
        leg: leg,
        previousLeg: i > 0 ? legs[i - 1] : null,
        isFinalLeg: i == legs.length - 1,
        initialHeadingDegrees: initialHeadingDegrees,
        includeReference: includeReference,
        reference: reference,
      );

      final trigger = max(
        _minInstructionDistanceMeters,
        min(20.0, leg.distanceMeters * 0.35),
      );

      steps.add(
        GuidanceStep(
          endPoint: leg.endPoint,
          instruction: instruction,
          triggerDistanceMeters: trigger,
        ),
      );
    }

    return steps;
  }

  String _legInstruction({
    required _RouteLeg leg,
    required _RouteLeg? previousLeg,
    required bool isFinalLeg,
    required double? initialHeadingDegrees,
    required bool includeReference,
    required String? reference,
  }) {
    final movementText = 'avanza ${leg.distanceMeters.round()} metros';

    String baseInstruction;

    if (previousLeg == null) {
      baseInstruction = _initialOrientationInstruction(
        from: leg.startPoint,
        to: leg.endPoint,
        distanceMeters: leg.distanceMeters,
        deviceHeadingDegrees: initialHeadingDegrees,
      );
    } else {
      final delta = _normalizeAngle(
        leg.bearingDegrees - previousLeg.bearingDegrees,
      );
      if (delta.abs() >= _turnBearingThresholdDegrees) {
        baseInstruction = 'GIRA ${_turnWord(delta)} y $movementText.';
      } else {
        baseInstruction =
            'Continúa recto ${leg.distanceMeters.round()} metros.';
      }
    }

    if (isFinalLeg) {
      final arrival = _arrivalInstruction(leg);
      if (includeReference && reference != null) {
        return '$baseInstruction $arrival. Pasarás junto a $reference.';
      }
      return '$baseInstruction $arrival.';
    }

    if (includeReference && reference != null) {
      return '$baseInstruction Pasarás junto a $reference.';
    }

    return baseInstruction;
  }

  String _initialOrientationInstruction({
    required RoutePoint from,
    required RoutePoint to,
    required double distanceMeters,
    required double? deviceHeadingDegrees,
  }) {
    if (deviceHeadingDegrees == null || deviceHeadingDegrees.isNaN) {
      return 'Avanza ${distanceMeters.round()} metros.';
    }

    final targetBearing = _bearingDegrees(from, to);
    final delta = _normalizeAngle(targetBearing - deviceHeadingDegrees);

    if (delta.abs() <= 30) {
      return 'Avanza hacia adelante ${distanceMeters.round()} metros.';
    }
    if (delta.abs() >= 150) {
      return 'Da media vuelta y avanza ${distanceMeters.round()} metros.';
    }

    return delta > 0
        ? 'GIRA a la derecha y avanza ${distanceMeters.round()} metros.'
        : 'GIRA a la izquierda y avanza ${distanceMeters.round()} metros.';
  }

  String _turnWord(double delta) {
    final absDelta = delta.abs();
    if (absDelta < 55) {
      return delta > 0 ? 'a la derecha' : 'a la izquierda';
    }
    if (absDelta < 120) {
      return delta > 0 ? 'a la derecha' : 'a la izquierda';
    }
    return delta > 0 ? 'a la derecha' : 'a la izquierda';
  }

  String _arrivalInstruction(_RouteLeg leg) {
    final destinationPoint = RoutePoint(
      latitude: _destinationLat,
      longitude: _destinationLng,
    );
    final destBearing = _bearingDegrees(leg.endPoint, destinationPoint);
    final delta = _normalizeAngle(destBearing - leg.bearingDegrees);
    final destinationText = _normalizeText(_destinationName);

    if (delta.abs() <= 30) {
      return 'Llegaste a tu destino. $destinationText al frente';
    }
    if (delta.abs() >= 150) {
      return 'Llegaste a tu destino. $destinationText detrás de ti';
    }

    return delta > 0
        ? 'Llegaste a tu destino. $destinationText a tu derecha'
        : 'Llegaste a tu destino. $destinationText a tu izquierda';
  }

  String _normalizeText(String text) {
    return text
        .replaceAll('Ã¡', 'á')
        .replaceAll('Ã©', 'é')
        .replaceAll('Ã­', 'í')
        .replaceAll('Ã³', 'ó')
        .replaceAll('Ãº', 'ú')
        .replaceAll('Ã±', 'ñ')
        .replaceAll('Â', '');
  }

  Future<void> _speakAndAnnounce(String text) async {
    try {
      await _announceForTalkBack?.call(text);
      if (_ttsReady) {
        await _tts.stop();
        await _tts.speak(text);
      }
    } catch (e) {
      debugPrint('Error de voz: $e');
    }
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
    while (a > 180) a -= 360;
    while (a < -180) a += 360;
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
