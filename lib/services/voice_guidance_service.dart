import 'dart:math';
import 'package:flutter/foundation.dart';
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

class VoiceGuidanceService extends ChangeNotifier {
  static final VoiceGuidanceService _instance = VoiceGuidanceService._internal();
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
  List<RoutePoint> _activePolyline = [];
  int _currentStepIndex = 0;

  double _destinationLat = 0;
  double _destinationLng = 0;
  String _destinationName = '';

  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReminderAt = DateTime.fromMillisecondsSinceEpoch(0);

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

    _activePolyline = List<RoutePoint>.from(route.polyline);
    _steps
      ..clear()
      ..addAll(_buildSteps(_activePolyline));

    if (_steps.isEmpty) {
      _status = 'No hay suficientes puntos para guiar por voz.';
      notifyListeners();
      return;
    }

    _currentStepIndex = 0;
    _isNavigating = true;
    _status = 'Navegación activa hacia $_destinationName';
    _currentInstruction = _steps.first.instruction;

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
    _activePolyline = [];
    _currentStepIndex = 0;
    _isNavigating = false;
    _currentInstruction = '';
    _status = 'Navegación por voz inactiva';

    if (speak) {
      await _speakAndAnnounce('Navegación detenida.');
    } else {
      await _tts.stop();
    }

    notifyListeners();
  }

  // Método general para leer cualquier texto, independiente de la navegación
  Future<void> speak(String text) async {
    await _initTts();
    await _speakAndAnnounce(text);
  }

  Future<void> _onLocationChanged() async {
    if (!_isNavigating || _locationService?.currentLocation == null) return;

    final current = _locationService!.currentLocation!;

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

    final now = DateTime.now();
    if (distanceToStep <= step.triggerDistanceMeters) {
      _currentStepIndex++;

      if (_currentStepIndex >= _steps.length) {
        _currentInstruction = 'Has llegado a $_destinationName';
        _status = 'Destino alcanzado';
        notifyListeners();
        await _speakAndAnnounce(
          'Has llegado a $_destinationName. Navegación finalizada.',
        );
        await stopNavigation(speak: false);
        return;
      }

      _currentInstruction = _steps[_currentStepIndex].instruction;
      _status = 'Navegación activa hacia $_destinationName';
      notifyListeners();
      await _speakAndAnnounce(_currentInstruction);
      return;
    }

    if (now.difference(_lastReminderAt).inSeconds >= 20) {
      _lastReminderAt = now;
      final rounded = distanceToStep.round();
      final reference = _landmarkResolver?.call(current.latitude, current.longitude);
      final referenceText = reference == null ? '' : ' Vas pasando junto a $reference.';
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
    _steps
      ..clear()
      ..addAll(_buildSteps(_activePolyline));
    _currentStepIndex = 0;
    _currentInstruction = _steps.first.instruction;
    _status = 'Ruta actualizada hacia $_destinationName';
    notifyListeners();

    await _speakAndAnnounce('Ruta actualizada. ${_steps.first.instruction}');
  }

  List<GuidanceStep> _buildSteps(List<RoutePoint> polyline) {
    if (polyline.length < 2) return [];

    final steps = <GuidanceStep>[];
    final bearings = <double>[];
    String? lastReference;

    for (int i = 1; i < polyline.length; i++) {
      bearings.add(_bearingDegrees(polyline[i - 1], polyline[i]));
    }

    for (int i = 1; i < polyline.length; i++) {
      final from = polyline[i - 1];
      final to = polyline[i];
      final distance = _haversineMeters(
        from.latitude,
        from.longitude,
        to.latitude,
        to.longitude,
      );
      final reference = _landmarkResolver?.call(to.latitude, to.longitude);
      final includeReference = reference != null && reference != lastReference;
      if (reference != null) {
        lastReference = reference;
      }

      final mainPart = i == 1
          ? 'Inicia y camina en linea recta ${distance.round()} metros.'
          : 'Continua en linea recta ${distance.round()} metros.';

      String turnHint = '';
      if (i < bearings.length) {
        final delta = _normalizeAngle(bearings[i] - bearings[i - 1]);
        if (delta.abs() >= 30) {
          turnHint = ' Luego ${_turnHint(delta)}.';
        }
      }

      final instruction = i == polyline.length - 1
          ? '$mainPart Continua hasta llegar al destino.'
          : '$mainPart$turnHint${includeReference ? ' Pasaras junto a $reference.' : ''}';

      final trigger = max(
        _minInstructionDistanceMeters,
        min(20.0, distance * 0.35),
      );

      steps.add(
        GuidanceStep(
          endPoint: to,
          instruction: instruction,
          triggerDistanceMeters: trigger,
        ),
      );
    }

    return steps;
  }

  String _turnHint(double delta) {
    final absDelta = delta.abs();
    if (absDelta < 55) {
      return delta > 0
          ? 'haz un giro suave a la derecha'
          : 'haz un giro suave a la izquierda';
    }
    if (absDelta < 120) {
      return delta > 0 ? 'gira a la derecha' : 'gira a la izquierda';
    }
    return delta > 0
        ? 'haz un giro pronunciado a la derecha'
        : 'haz un giro pronunciado a la izquierda';
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
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) *
            cos(_toRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
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