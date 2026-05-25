import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/geojson_service.dart';
import '../services/location_service.dart';
import '../services/route_guidance_builder.dart';
import '../services/routing_service.dart';
import '../services/voice_guidance_service.dart';
import '../utils/accessibility_scale.dart';
import '../services/haptic_service.dart';

class NavigationMapScreen extends StatefulWidget {
  final String destinationName;
  final double startLat;
  final double startLng;
  final double destLat;
  final double destLng;
  final String? highlightCategoryId;
  final RouteResult? initialRoute;
  final List<List<double>>? destinationPolygon;
  final bool autoStartSimulation;

  const NavigationMapScreen({
    super.key,
    required this.destinationName,
    required this.startLat,
    required this.startLng,
    required this.destLat,
    required this.destLng,
    this.highlightCategoryId,
    this.initialRoute,
    this.destinationPolygon,
    this.autoStartSimulation = false,
  });

  @override
  State<NavigationMapScreen> createState() => _NavigationMapScreenState();
}

class _NavigationMapScreenState extends State<NavigationMapScreen> {
  final MapController _mapController = MapController();

  GeoJsonService? _geoService;
  LocationService? _locationService;
  RoutingService? _routingService;
  VoiceGuidanceService? _voiceService;

  bool _isLoading = true;
  bool _hasError = false;
  bool _voiceStarted = false;
  bool _isNavigationPaused = false;
  bool _isResumingNavigation = false;
  String? _navigationLiveMessage;
  bool _usageInstructionsShown = false;
  bool _routeSimulationRunning = false;
  bool _autoSimulationScheduled = false;

  late LatLng _destination;
  late LatLng _currentUser;
  late LatLng _lastRouteOrigin;

  RouteResult? _activeRoute;
  double _currentZoom = 17;

  List<LatLng> _routePoints = [];
  List<GuidanceStep> _routeSteps = [];
  double? _routeDistanceMeters;
  // HU-16: distancia restante calculada desde VoiceGuidanceService
  double? _remainingDistanceMeters;

  DateTime _lastRouteUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnnouncedReroute = DateTime.fromMillisecondsSinceEpoch(0);
  String? _waitingExitPlaceName;
  List<List<double>>? _waitingExitPolygon;
  int _waitingExitOutsideSamples = 0;

  static const double _maxDistanceFromRouteMeters = 22.0;
  static const double _minMoveToOptionalRerouteMeters = 35.0;
  static const Duration _minTimeBetweenReroutes = Duration(seconds: 1);
  static const Duration _minTimeBetweenAnnouncements = Duration(seconds: 20);

  bool get _usesLocalRouting => widget.initialRoute != null;

  Future<void> _announce(String message) {
    return SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  Future<void> _announceAndSpeak(String message) async {
    await _announce(message);
    await _voiceService?.speakMessage(message);
  }

  Future<void> _openGuidanceSettings() async {
    final voice = _voiceService;
    if (voice == null) return;

    var periodicEnabled = voice.periodicProgressConfirmationsEnabled;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF12263A),
              title: const Text(
                'Configuración de guía',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    value: periodicEnabled,
                    onChanged: (enabled) async {
                      setDialogState(() => periodicEnabled = enabled);
                      await voice.setPeriodicProgressConfirmationsEnabled(
                        enabled,
                      );
                      if (!mounted) return;
                      final message = enabled
                          ? 'Confirmaciones periódicas de progreso activadas.'
                          : 'Confirmaciones periódicas de progreso desactivadas.';
                      await _announceAndSpeak(message);
                    },
                    title: const Text(
                      'Confirmaciones periódicas',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Recibe mensajes automáticos de avance durante la ruta.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    activeColor: const Color(0xFF82B1FF),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Cerrar',
                    style: TextStyle(color: Color(0xFF82B1FF)),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _syncVoiceGuidanceState() {
    final voice = _voiceService;
    if (voice == null || !mounted) return;

    setState(() {
      _activeRoute = voice.activeRoute;
      _routePoints = voice.activePolyline
          .map((point) => LatLng(point.latitude, point.longitude))
          .toList();
      _routeSteps = List<GuidanceStep>.from(voice.guidanceSteps);

      final routeDistance = voice.activeRoute?.totalDistanceMeters;
      if (routeDistance != null) {
        _routeDistanceMeters = routeDistance;
      }

      if (voice.isNavigating) {
        _hasError = false;
        _isLoading = false;
      }
    });
  }

  Color _areaFillColor({required bool highlighted}) {
    return highlighted
        ? const Color(0xFF7E57C2).withValues(alpha: 0.22)
        : const Color(0xFF7E57C2).withValues(alpha: 0.10);
  }

  Color _areaBorderColor({required bool highlighted}) {
    return highlighted
        ? const Color(0xFF5E35B1).withValues(alpha: 0.80)
        : const Color(0xFF5E35B1).withValues(alpha: 0.32);
  }

  LatLng _polygonLabelPoint(List<List<double>> polygon) {
    var latSum = 0.0;
    var lngSum = 0.0;
    for (final point in polygon) {
      lngSum += point[0];
      latSum += point[1];
    }
    return LatLng(latSum / polygon.length, lngSum / polygon.length);
  }

  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const metersPerDegreeLat = 111320.0;
    final avgLatRad = ((lat1 + lat2) / 2) * math.pi / 180.0;
    final metersPerDegreeLng = metersPerDegreeLat * math.cos(avgLatRad);
    final dLat = (lat2 - lat1) * metersPerDegreeLat;
    final dLng = (lng2 - lng1) * metersPerDegreeLng;
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  double _distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    const metersPerDegreeLat = 111320.0;
    final avgLatRad =
        ((a.latitude + b.latitude + p.latitude) / 3) * math.pi / 180.0;
    final metersPerDegreeLng = metersPerDegreeLat * math.cos(avgLatRad);

    final ax = a.longitude * metersPerDegreeLng;
    final ay = a.latitude * metersPerDegreeLat;
    final bx = b.longitude * metersPerDegreeLng;
    final by = b.latitude * metersPerDegreeLat;
    final px = p.longitude * metersPerDegreeLng;
    final py = p.latitude * metersPerDegreeLat;

    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;

    final ab2 = abx * abx + aby * aby;
    if (ab2 == 0) {
      final dx = px - ax;
      final dy = py - ay;
      return math.sqrt(dx * dx + dy * dy);
    }

    final t = (apx * abx + apy * aby) / ab2;
    final clamped = t.clamp(0.0, 1.0);
    final cx = ax + abx * clamped;
    final cy = ay + aby * clamped;
    final dx = px - cx;
    final dy = py - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  double _distanceToRouteMeters(LatLng p, List<LatLng> route) {
    if (route.length < 2) return double.infinity;
    var minDist = double.infinity;
    for (var i = 0; i < route.length - 1; i++) {
      final d = _distancePointToSegmentMeters(p, route[i], route[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  String _formatAccuracy(double? accuracyMeters) {
    if (accuracyMeters == null || !accuracyMeters.isFinite) return '--';
    return '±${accuracyMeters.round()} m';
  }

  int _nextStepIndex(LatLng current) {
    if (_routeSteps.isEmpty) return 0;

    for (var i = 0; i < _routeSteps.length; i++) {
      final step = _routeSteps[i];
      final d = _distanceMeters(
        current.latitude,
        current.longitude,
        step.endPoint.latitude,
        step.endPoint.longitude,
      );
      if (d > 10) return i;
    }

    return _routeSteps.length - 1;
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

  bool _isInsidePolygon(double lat, double lng, List<List<double>> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i][0], yi = polygon[i][1];
      final xj = polygon[j][0], yj = polygon[j][1];
      if (((yi > lat) != (yj > lat)) &&
          (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  Future<bool> _waitForExitIfInsideArea(LatLng origin) async {
    final geo = _geoService;
    if (geo == null) return false;

    final place = geo.getPlaceContaining(origin.latitude, origin.longitude);
    if (place == null) return false;

    final polygon = place.polygon;
    final mustWait =
        polygon != null &&
        polygon.length >= 3 &&
        _isInsidePolygon(origin.latitude, origin.longitude, polygon);

    if (!mustWait) {
      if (_waitingExitPolygon != null && mounted) {
        setState(() {
          _waitingExitPlaceName = null;
          _waitingExitPolygon = null;
          _waitingExitOutsideSamples = 0;
        });
      }
      return false;
    }

    final placeName = place.name;
    final firstTime = _waitingExitPolygon == null;
    if (mounted) {
      setState(() {
        _waitingExitPlaceName = placeName;
        _waitingExitPolygon = polygon;
        _waitingExitOutsideSamples = 0;
        _isLoading = false;
        _hasError = false;
      });
    }

    if (firstTime) {
      await _announceAndSpeak(
        'Estás dentro de ${_normalizeText(placeName)}. Sal para iniciar la navegación.',
      );
    }

    return true;
  }

  void _applyLocalRoute(RouteResult route) {
    _activeRoute = route;
    final points = route.polyline
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();

    setState(() {
      _routePoints = points;
      final voiceService = _voiceService;
      final voiceSteps =
          voiceService == null ? const <GuidanceStep>[] : voiceService.guidanceSteps;
      _routeSteps = List<GuidanceStep>.from(voiceSteps);
      _routeDistanceMeters = route.totalDistanceMeters;
      _hasError = points.length < 2;
      _isLoading = false;
    });
  }

  Future<void> _startVoiceGuidanceIfNeeded() async {
    if (_voiceStarted || _activeRoute == null) return;

    final voice = _voiceService;
    final route = _activeRoute;
    final location = _locationService;
    final routing = _routingService;

    if (voice == null || route == null || location == null || routing == null) {
      return;
    }

    _voiceStarted = true;
    // Detectar si las features de accesibilidad (p. ej. lector de pantalla)
    // están activas y, en ese caso, solicitar al servicio de voz que
    // suprima la reproducción TTS para evitar duplicidad.
    final semanticsBinding = SemanticsBinding.instance;
    final semanticsEnabled = semanticsBinding.semanticsEnabled;
    voice.setSuppressTtsWhenAccessibility(semanticsEnabled);

    if (!voice.isNavigating) {
      final geoService = _geoService;
      await voice.startNavigation(
        route: route,
        locationService: location,
        routingService: routing,
        destinationName: widget.destinationName,
        destinationLat: widget.destLat,
        destinationLng: widget.destLng,
        announceForTalkBack: _announce,
        landmarkResolver: (lat, lng) => geoService == null
            ? null
            : geoService.getNearestBlockReference(lat, lng),
        onArrival: _showArrivalOverlay,
        skipInitialCalibration: widget.autoStartSimulation,
      );
    } else {
      _syncVoiceGuidanceState();
    }

    if (widget.autoStartSimulation && !_autoSimulationScheduled) {
      _autoSimulationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _runRouteSimulation();
        }
      });
      return;
    }

    await _showUsageInstructionsIfNeeded();
  }

  String _usageInstructionsText() {
    return 'Navegación iniciada. Toca una vez la pantalla para repetir tu ubicación e indicaciones. '
        'Mantén presionada la pantalla para finalizar la navegación.';
  }

  Future<void> _showUsageInstructionsIfNeeded() async {
    if (_usageInstructionsShown || !mounted) return;
    _usageInstructionsShown = true;

    final accessibilityOn =
        SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;

    if (accessibilityOn) {
      return;
    }

    final message = _usageInstructionsText();
    await _voiceService?.speak(message);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF12263A),
          title: const Text(
            'Instrucciones de uso',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Entendido',
                style: TextStyle(color: Color(0xFF82B1FF)),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _repeatCurrentGuidanceFromGesture() async {
    final voice = _voiceService;
    if (voice == null || !voice.isNavigating) return;

    final location = _locationService?.currentLocation;
    final lat = location?.latitude ?? _currentUser.latitude;
    final lng = location?.longitude ?? _currentUser.longitude;

    final placeName = _geoService?.getPlaceContaining(lat, lng)?.name;
    final nearbyRef = _geoService?.getNearestBlockReference(lat, lng);

    final locationText = placeName != null
        ? 'Ubicación actual: ${_normalizeText(placeName)}.'
        : (nearbyRef != null
              ? 'Ubicación actual: cerca de ${_normalizeText(nearbyRef)}.'
              : 'Ubicación actual registrada.');

    final instruction = voice.currentInstruction.isNotEmpty
        ? voice.currentInstruction
      : (_routeSteps.isNotEmpty
          ? _routeSteps.first.instruction
              : 'Sin indicaciones disponibles por ahora.');

    final remaining = _remainingDistanceMeters ?? voice.getRemainingDistance(lat, lng);
    final remainingText = (remaining > 0)
        ? ' Distancia restante ${_formatDistance(remaining)}.'
        : '';

    await HapticFeedback.selectionClick();
    await voice.speak('$locationText $instruction$remainingText');
  }

  Future<void> _showArrivalOverlay() async {
    try {
      await HapticService.trigger(HapticEvent.destinationReached);
    } catch (_) {}

    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _stopRouteSimulation() async {
    final location = _locationService;
    location?.stopSimulation();
    if (!mounted) return;
    setState(() {
      _routeSimulationRunning = false;
    });
    await _announce('Simulación detenida.');
  }

  Future<void> _runRouteSimulation() async {
    if (_routeSimulationRunning) return;

    final voice = _voiceService;
    final location = _locationService;
    if (voice == null || location == null) return;

    final simulationPath = _routePoints.isNotEmpty
      ? List<LatLng>.from(_routePoints)
      : _routeSteps
          .map((step) => LatLng(step.endPoint.latitude, step.endPoint.longitude))
          .toList();

    if (simulationPath.length < 2) {
      await _announce('No hay una ruta suficiente para simular.');
      return;
    }

    if (!voice.isNavigating) {
      await _announce('Primero inicia una navegación para simularla.');
      return;
    }

    setState(() {
      _routeSimulationRunning = true;
    });

    location.startSimulation();

    try {
      await _announceAndSpeak('Simulación de navegación iniciada.');

      final firstPoint = simulationPath.first;
      location.seedLocation(
        LocationData(
          latitude: firstPoint.latitude,
          longitude: firstPoint.longitude,
          accuracy: 5,
          speed: 0,
          heading: null,
          timestamp: DateTime.now(),
        ),
      );

      for (var i = 1; i < simulationPath.length && mounted; i++) {
        if (!_routeSimulationRunning) break;

        final currentPoint = simulationPath[i];
        location.setSimulatedLocation(
          LocationData(
            latitude: currentPoint.latitude,
            longitude: currentPoint.longitude,
            accuracy: 5,
            speed: i == simulationPath.length - 1 ? 0.6 : 1.2,
            heading: null,
            timestamp: DateTime.now(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 3600));
      }

      await voice.completeNavigationIfActive();
    } finally {
      location.stopSimulation();
      if (mounted) {
        setState(() {
          _routeSimulationRunning = false;
        });
      } else {
        _routeSimulationRunning = false;
      }
    }
  }

  Future<void> _finishNavigationFromLongPress() async {
    if (_routeSimulationRunning) {
      await _stopRouteSimulation();
    }
    await _finishNavigation();
  }

  Future<void> _loadLocalRoute({required LatLng origin}) async {
    try {
      final routing = _routingService;
      if (routing == null) {
        throw Exception('Servicio de rutas no disponible');
      }

      final route = await routing.buildRoute(
        originLat: origin.latitude,
        originLng: origin.longitude,
        destinationLat: _destination.latitude,
        destinationLng: _destination.longitude,
        originPolygon: _geoService
            ?.getPlaceContaining(origin.latitude, origin.longitude)
            ?.polygon,
        destinationPolygon: widget.destinationPolygon,
      );

      if (route == null) {
        throw Exception('No hay ruta local disponible');
      }

      if (!mounted) return;
      _applyLocalRoute(route);
      await _startVoiceGuidanceIfNeeded();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _routePoints = [];
        _routeSteps = [];
        _routeDistanceMeters = null;
        _isLoading = false;
      });
    }
  }

  Future<RouteResult?> _recalculateLocalRoute({
    required LatLng newOrigin,
    bool force = false,
    bool announceReroute = true,
  }) async {
    final now = DateTime.now();
    final enoughTime =
        now.difference(_lastRouteUpdate) >= _minTimeBetweenReroutes;

    final movedSinceLastOrigin = _distanceMeters(
      _lastRouteOrigin.latitude,
      _lastRouteOrigin.longitude,
      newOrigin.latitude,
      newOrigin.longitude,
    );

    final offRouteDistance = _distanceToRouteMeters(newOrigin, _routePoints);
    final isOffRoute = offRouteDistance > _maxDistanceFromRouteMeters;

    if (!force && !enoughTime) return _activeRoute;
    if (!force &&
        !(isOffRoute ||
            movedSinceLastOrigin >= _minMoveToOptionalRerouteMeters)) {
      return _activeRoute;
    }

    final routing = _routingService;
    if (routing == null) return null;

    _lastRouteOrigin = newOrigin;
    _lastRouteUpdate = now;

    setState(() {
      _currentUser = newOrigin;
      _isLoading = true;
      _hasError = false;
    });

    final updated = await routing.buildRoute(
      originLat: newOrigin.latitude,
      originLng: newOrigin.longitude,
      destinationLat: _destination.latitude,
      destinationLng: _destination.longitude,
      originPolygon: _geoService
          ?.getPlaceContaining(newOrigin.latitude, newOrigin.longitude)
          ?.polygon,
      destinationPolygon: widget.destinationPolygon,
    );

    if (!mounted) return null;
    if (updated == null) {
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
      return null;
    }

    _applyLocalRoute(updated);

    if (announceReroute &&
        now.difference(_lastAnnouncedReroute) >= _minTimeBetweenAnnouncements) {
      _lastAnnouncedReroute = now;
      _announce('Ruta local recalculada por cambio de ubicación.');
    }

    return updated;
  }

  void _onLocationChanged() {
    final here = _locationService?.currentLocation;
    if (here == null) return;
    if (_isNavigationPaused) return;

    final next = LatLng(here.latitude, here.longitude);

    if (!mounted) return;

    // HU-16: actualizar distancia restante desde VoiceGuidanceService
    final voice = _voiceService;
    final remaining = voice?.getRemainingDistance(
      here.latitude,
      here.longitude,
    );

    setState(() {
      _currentUser = next;
      _remainingDistanceMeters = (remaining != null && remaining > 0)
          ? remaining
          : _routeDistanceMeters;
    });

    if (voice?.isNavigating == true) {
      return;
    }

    final waitingPolygon = _waitingExitPolygon;
    if (waitingPolygon != null && waitingPolygon.length >= 3) {
      final stillInside = _isInsidePolygon(
        next.latitude,
        next.longitude,
        waitingPolygon,
      );
      if (stillInside) {
        if (_waitingExitOutsideSamples != 0) {
          setState(() {
            _waitingExitOutsideSamples = 0;
          });
        }
        return;
      }

      final nextOutsideSamples = _waitingExitOutsideSamples + 1;
      if (nextOutsideSamples < 3) {
        setState(() {
          _waitingExitOutsideSamples = nextOutsideSamples;
        });
        return;
      }

      final placeName = _waitingExitPlaceName;
      setState(() {
        _waitingExitPlaceName = null;
        _waitingExitPolygon = null;
        _waitingExitOutsideSamples = 0;
        _isLoading = true;
      });
      _announceAndSpeak(
        'Perfecto. Ya saliste de ${_normalizeText(placeName ?? 'el bloque')}. Iniciando ruta.',
      );
      _loadLocalRoute(origin: next);
      return;
    }

    _recalculateLocalRoute(newOrigin: next);
  }

  List<Polygon> _buildCampusPolygons(GeoJsonService geo) {
    final result = <Polygon>[];

    for (final place in geo.allPlaces) {
      final poly = place.polygon;
      if (poly == null || poly.length < 3) continue;

      final points = poly.map((c) => LatLng(c[1], c[0])).toList();
      final highlighted = widget.highlightCategoryId == null
          ? true
          : place.categories.contains(widget.highlightCategoryId);

      result.add(
        Polygon(
          points: points,
          color: _areaFillColor(highlighted: highlighted),
          borderColor: _areaBorderColor(highlighted: highlighted),
          borderStrokeWidth: highlighted ? 1.4 : 0.8,
        ),
      );
    }

    return result;
  }

  List<Marker> _buildPolygonLabels(GeoJsonService geo) {
    final labels = <Marker>[];

    for (final place in geo.allPlaces) {
      final poly = place.polygon;
      if (poly == null || poly.length < 3) continue;

      labels.add(
        Marker(
          point: _polygonLabelPoint(poly),
          width: 120,
          height: 34,
          child: IgnorePointer(
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                _normalizeText(place.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return labels;
  }

  int? _nearestRoutePointIndex() {
    if (_routePoints.isEmpty) return null;

    var bestIndex = 0;
    var bestDistance = double.infinity;

    for (var i = 0; i < _routePoints.length; i++) {
      final point = _routePoints[i];
      final distance = _distanceMeters(
        _currentUser.latitude,
        _currentUser.longitude,
        point.latitude,
        point.longitude,
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }

    return bestIndex;
  }

  @override
  void initState() {
    super.initState();
    _destination = LatLng(widget.destLat, widget.destLng);
    _currentUser = LatLng(widget.startLat, widget.startLng);
    _lastRouteOrigin = _currentUser;
    _lastRouteUpdate = DateTime.now();
    _currentZoom = 17;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_usesLocalRouting && widget.autoStartSimulation) {
        _announce('Mostrando ruta local a ${widget.destinationName}.');
        _applyLocalRoute(widget.initialRoute!);
        await _startVoiceGuidanceIfNeeded();
        return;
      }

      final mustWaitForExit = await _waitForExitIfInsideArea(_currentUser);
      if (mustWaitForExit) return;

      if (_usesLocalRouting && widget.initialRoute != null) {
        _announce('Mostrando ruta local a ${widget.destinationName}.');
        _applyLocalRoute(widget.initialRoute!);
        await _startVoiceGuidanceIfNeeded();
        return;
      }

      _announce('Mostrando ruta a ${widget.destinationName}.');
      await _loadLocalRoute(origin: _currentUser);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final nextGeo = Provider.of<GeoJsonService>(context, listen: false);
    if (!identical(_geoService, nextGeo)) {
      _geoService = nextGeo;
    }

    final nextLoc = Provider.of<LocationService>(context, listen: false);
    if (!identical(_locationService, nextLoc)) {
      _locationService?.removeListener(_onLocationChanged);
      _locationService = nextLoc;
      _locationService?.addListener(_onLocationChanged);
    }

    final nextRouting = Provider.of<RoutingService>(context, listen: false);
    if (!identical(_routingService, nextRouting)) {
      _routingService = nextRouting;
    }

    final nextVoice = Provider.of<VoiceGuidanceService>(context, listen: false);
    if (!identical(_voiceService, nextVoice)) {
      _voiceService?.removeListener(_syncVoiceGuidanceState);
      _voiceService = nextVoice;
      _voiceService?.addListener(_syncVoiceGuidanceState);
    }

    final here = _locationService?.currentLocation;
    if (here != null && !_isNavigationPaused) {
      _currentUser = LatLng(here.latitude, here.longitude);
      _lastRouteOrigin = _currentUser;
    }
  }

  @override
  void dispose() {
    _locationService?.removeListener(_onLocationChanged);
    _voiceService?.removeListener(_syncVoiceGuidanceState);
    super.dispose();
  }

  void _setNavigationLiveMessage(String message) {
    if (!mounted) return;
    setState(() {
      _navigationLiveMessage = message;
    });
  }

  Future<void> _pauseNavigation() async {
    if (_isNavigationPaused) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _isNavigationPaused = true;
      _isLoading = false;
      _navigationLiveMessage = NavigationMessages.navigationPaused();
    });

    await _voiceService?.pauseNavigation(speak: false);
    await _announceAndSpeak(NavigationMessages.navigationPaused());
  }

  Future<void> _resumeNavigation() async {
    if (!_isNavigationPaused || _isResumingNavigation) return;

    final here = _locationService?.currentLocation;
    final origin = here == null
        ? _currentUser
        : LatLng(here.latitude, here.longitude);

    HapticFeedback.mediumImpact();
    setState(() {
      _isResumingNavigation = true;
      _isLoading = true;
      _hasError = false;
      _currentUser = origin;
    });

    final resumedRoute = await _recalculateLocalRoute(
      newOrigin: origin,
      force: true,
      announceReroute: false,
    );

    if (!mounted) return;
    if (resumedRoute == null) {
      setState(() {
        _isResumingNavigation = false;
        _isLoading = false;
        _hasError = true;
      });
      await _announceAndSpeak('No se pudo reanudar la navegación.');
      return;
    }

    final voice = _voiceService;
    if (voice != null && voice.isNavigating) {
      await voice.resumeNavigation(route: resumedRoute, speak: false);
    } else {
      _voiceStarted = false;
      await _startVoiceGuidanceIfNeeded();
    }
    if (!mounted) return;

    setState(() {
      _isNavigationPaused = false;
      _isResumingNavigation = false;
      _isLoading = false;
      _navigationLiveMessage = NavigationMessages.navigationResumed();
    });

    final currentInstruction = _voiceService?.currentInstruction ?? '';
    final message = currentInstruction.isEmpty
        ? NavigationMessages.navigationResumed()
        : '${NavigationMessages.navigationResumed()}. $currentInstruction';
    await _announceAndSpeak(message);
  }

  Future<void> _finishNavigation() async {
    HapticFeedback.heavyImpact();
    _setNavigationLiveMessage(NavigationMessages.navigationFinished());

    final voice = _voiceService;
    await _announceAndSpeak(NavigationMessages.navigationFinished());
    await voice?.finishNavigation(speak: false);
    _routingService?.clearCurrentRoute();

    if (!mounted) return;
    setState(() {
      _isNavigationPaused = false;
      _isResumingNavigation = false;
      _voiceStarted = false;
      _activeRoute = null;
      _routePoints = [];
      _routeSteps = [];
      _routeDistanceMeters = null;
      _remainingDistanceMeters = null;
      _waitingExitPlaceName = null;
      _waitingExitPolygon = null;
      _waitingExitOutsideSamples = 0;
    });

    Navigator.of(context).pop();
  }

  Widget _buildNavigationLiveRegion(TextScaler textScaler) {
    final message = _navigationLiveMessage;
    if (message == null) return const SizedBox.shrink();

    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isNavigationPaused
                ? const Color(0xFF5D4037).withValues(alpha: 0.50)
                : const Color(0xFF1B5E20).withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            message,
            textScaler: textScaler,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteControlButton({
    required String label,
    required String semanticsLabel,
    required String hint,
    required IconData icon,
    required VoidCallback? onPressed,
    Color color = const Color(0xFF82B1FF),
  }) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticsLabel,
      hint: hint,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            disabledForegroundColor: Colors.white38,
            side: BorderSide(color: onPressed == null ? Colors.white24 : color),
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationControls() {
    return Row(
      children: [
        Expanded(
          child: _buildRouteControlButton(
            label: 'Pausar',
            semanticsLabel: 'Pausar navegación',
            hint: 'Detiene temporalmente las instrucciones de guía.',
            icon: Icons.pause_circle_filled_rounded,
            onPressed: _isNavigationPaused || _isResumingNavigation
                ? null
                : _pauseNavigation,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildRouteControlButton(
            label: 'Reanudar',
            semanticsLabel: 'Reanudar navegación',
            hint: 'Continúa la ruta desde tu ubicación actual.',
            icon: Icons.play_circle_fill_rounded,
            onPressed: !_isNavigationPaused || _isResumingNavigation
                ? null
                : _resumeNavigation,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildRouteControlButton(
            label: 'Finalizar',
            semanticsLabel: 'Finalizar navegación',
            hint: 'Cancela la ruta activa y vuelve a la pantalla principal.',
            icon: Icons.stop_circle_rounded,
            color: const Color(0xFFFF8A80),
            onPressed: _finishNavigation,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    final titleScaler = clampedTextScaler(context, maxScale: 1.3);
    final textScale = clampScaleFactor(context, maxScale: 1.5);
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final polygons = _buildCampusPolygons(geo);
    final polygonLabels = _buildPolygonLabels(geo);
    final selectedLabel = widget.highlightCategoryId == null
        ? null
        : geo.categoryById(widget.highlightCategoryId!)?.label;
    final nextIndex = _nextStepIndex(_currentUser);
    final nextSteps = _routeSteps.skip(nextIndex).take(3).toList();
    final waitingExitText = _waitingExitPlaceName == null
        ? 'Estás dentro de un área. Sal para iniciar la navegación.'
        : 'Estás dentro de ${_normalizeText(_waitingExitPlaceName!)}. Sal para iniciar la navegación.';

    final routeNodeMarkers = <Marker>[];
    if (_routePoints.length >= 2) {
      final nearestRoutePointIndex = _nearestRoutePointIndex();
      for (var i = 1; i < _routePoints.length; i++) {
        final point = _routePoints[i];
        final isDestinationNode = i == _routePoints.length - 1;
        final isCurrentNode = nearestRoutePointIndex == i;
        routeNodeMarkers.add(
          Marker(
            point: point,
            width: isDestinationNode || isCurrentNode ? 20 : 12,
            height: isDestinationNode || isCurrentNode ? 20 : 12,
            child: Container(
              decoration: BoxDecoration(
                color: isCurrentNode
                    ? const Color(0xFF43A047)
                    : const Color(0xFFFFD54F),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isCurrentNode
                      ? const Color(0xFF1B5E20)
                      : const Color(0xFFF9A825),
                  width: isDestinationNode || isCurrentNode ? 2.6 : 1.4,
                ),
              ),
            ),
          ),
        );
      }
    }

    final userMarker = Marker(
      point: _currentUser,
      width: 18,
      height: 18,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF43A047),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF1B5E20), width: 2),
        ),
      ),
    );

    const maxZoom = 24.0;
    const minZoom = 3.0;

    return WillPopScope(
      onWillPop: () async {
        await _finishNavigation();
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: Semantics(
          container: true,
          label: 'Pantalla de navegación activa',
          hint: 'Toca dos veces para repetir la instrucción actual. Mantén presionado para cancelar la navegación.',
          onTapHint: 'Repetir instrucción',
          onLongPressHint: 'Cancelar navegación',
          onTap: _repeatCurrentGuidanceFromGesture,
          onLongPress: _finishNavigationFromLongPress,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _repeatCurrentGuidanceFromGesture,
            onLongPress: _finishNavigationFromLongPress,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final mapHeight = constraints.maxHeight * (textScale > 1.3 ? 0.28 : 1 / 3);
                final topHeight = constraints.maxHeight - mapHeight;

            return Stack(
              children: [
                Column(
                  children: [
                    SizedBox(
                      height: topHeight,
                      child: SafeArea(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            responsiveSpace(context, 12),
                            responsiveSpace(context, 8),
                            responsiveSpace(context, 12),
                            responsiveSpace(context, 8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Fila: botón finalizar + nombre destino
                              Row(
                                children: [
                                  Semantics(
                                    button: true,
                                    label: 'Finalizar navegación',
                                    child: Material(
                                      color: const Color(0xCC1A237E),
                                      borderRadius: BorderRadius.circular(12),
                                      child: IconButton(
                                        constraints: const BoxConstraints(
                                          minWidth: 48,
                                          minHeight: 48,
                                        ),
                                        onPressed: _finishNavigation,
                                        icon: const Icon(
                                          Icons.stop_circle_rounded,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xCC0D1B2A),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.white24,
                                        ),
                                      ),
                                      child: Text(
                                        _normalizeText(widget.destinationName),
                                        textScaler: titleScaler,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Semantics(
                                    button: true,
                                    label: 'Configuración de guía',
                                    child: Material(
                                      color: const Color(0xCC1A237E),
                                      borderRadius: BorderRadius.circular(12),
                                      child: IconButton(
                                        constraints: const BoxConstraints(
                                          minWidth: 48,
                                          minHeight: 48,
                                        ),
                                        onPressed: _openGuidanceSettings,
                                        icon: const Icon(
                                          Icons.tune_rounded,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              // Filtro de categoría (si aplica)
                              if (selectedLabel != null) ...[
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC0D1B2A),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: Text(
                                      'Filtro: ${_normalizeText(selectedLabel)}',
                                      textScaler: textScaler,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),

                              // Panel principal de métricas e indicaciones
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xD90D1B2A),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: SingleChildScrollView(
                                    physics: const ClampingScrollPhysics(),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _buildNavigationLiveRegion(textScaler),
                                        if (_navigationLiveMessage != null)
                                          const SizedBox(height: 10),
                                        _buildNavigationControls(),
                                        const SizedBox(height: 12),

                                        // Chips de métricas
                                        Row(
                                          children: [
                                            // HU-16: chip de distancia restante
                                            Expanded(
                                              child: Semantics(
                                                label:
                                                    _remainingDistanceMeters ==
                                                        null
                                                    ? 'Distancia restante no disponible'
                                                    : 'Distancia restante: ${_formatDistance(_remainingDistanceMeters!)}',
                                                child: _MetricChip(
                                                  icon:
                                                      Icons.straighten_rounded,
                                                  label: 'Distancia restante',
                                                  value:
                                                      _remainingDistanceMeters ==
                                                          null
                                                      ? '--'
                                                      : _formatDistance(
                                                          _remainingDistanceMeters!,
                                                        ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: _MetricChip(
                                                icon: Icons.gps_fixed_rounded,
                                                label: 'Error GPS',
                                                value: _formatAccuracy(
                                                  _locationService
                                                      ?.currentLocation
                                                      ?.accuracy,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),

                                        const SizedBox(height: 10),

                                        // HU-16: botón "¿Cuánto falta?"
                                        Semantics(
                                          button: true,
                                          enabled:
                                              !_isNavigationPaused &&
                                              !_isResumingNavigation,
                                          label: _isNavigationPaused
                                              ? 'Escuchar distancia restante no disponible mientras la navegación está pausada'
                                              : 'Escuchar distancia restante',
                                          hint: _isNavigationPaused
                                              ? 'Reanuda la navegación para escuchar la distancia restante.'
                                              : 'Toca dos veces para escuchar cuánto falta para llegar',
                                          child: SizedBox(
                                            width: double.infinity,
                                            child: OutlinedButton.icon(
                                              onPressed:
                                                  _isNavigationPaused ||
                                                      _isResumingNavigation
                                                  ? null
                                                  : () => _voiceService
                                                        ?.announceRemainingDistance(),
                                              icon: const Icon(
                                                Icons.record_voice_over_rounded,
                                                size: 18,
                                              ),
                                              label: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  '¿Cuánto falta?',
                                                  textScaler: textScaler,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Colors.white,
                                                side: const BorderSide(
                                                  color: Color(0xFF82B1FF),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 10,
                                                    ),
                                                minimumSize: const Size(
                                                  double.infinity,
                                                  48,
                                                ),
                                                textStyle: const TextStyle(
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),

                                        const SizedBox(height: 14),

                                        Text(
                                          'Próximas indicaciones',
                                          textScaler: textScaler,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        if (nextSteps.isEmpty)
                                          Align(
                                            alignment: Alignment.topLeft,
                                            child: Text(
                                              _waitingExitPolygon != null
                                                  ? waitingExitText
                                                  : 'Sin indicaciones disponibles todavía.',
                                              textScaler: textScaler,
                                              softWrap: true,
                                              style: const TextStyle(
                                                color: Colors.white60,
                                              ),
                                            ),
                                          )
                                        else
                                          ListView.separated(
                                            shrinkWrap: true,
                                            physics:
                                                const NeverScrollableScrollPhysics(),
                                            itemCount: nextSteps.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 8),
                                            itemBuilder: (context, i) {
                                              return Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Container(
                                                    width: 22,
                                                    height: 22,
                                                    alignment: Alignment.center,
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFF1565C0,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            11,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      '${i + 1}',
                                                      textScaler: textScaler,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      _normalizeText(
                                                        nextSteps[i]
                                                            .instruction,
                                                      ),
                                                      textScaler: textScaler,
                                                      softWrap: true,
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                        height: 1.3,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Mapa en el tercio inferior
                    SafeArea(
                      top: false,
                      child: SizedBox(
                        height: mapHeight,
                        width: double.infinity,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(18),
                            topRight: Radius.circular(18),
                          ),
                          child: ExcludeSemantics(
                            child: FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: _currentUser,
                                initialZoom: _currentZoom,
                                minZoom: minZoom,
                                maxZoom: maxZoom,
                                interactionOptions: const InteractionOptions(
                                  flags:
                                      InteractiveFlag.drag |
                                      InteractiveFlag.pinchZoom |
                                      InteractiveFlag.doubleTapZoom |
                                      InteractiveFlag.scrollWheelZoom,
                                ),
                                onPositionChanged: (camera, hasGesture) {
                                  _currentZoom = camera.zoom;
                                },
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate:
                                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'campus_guia',
                                ),
                                if (polygons.isNotEmpty)
                                  PolygonLayer(polygons: polygons),
                                if (_routePoints.length >= 2)
                                  PolylineLayer(
                                    polylines: [
                                      Polyline(
                                        points: _routePoints,
                                        strokeWidth: 5,
                                        color: const Color(0xFF1976D2),
                                      ),
                                    ],
                                  ),
                                MarkerLayer(
                                  markers: [
                                    ...polygonLabels,
                                    ...routeNodeMarkers,
                                    userMarker,
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_isLoading)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF82B1FF),
                        ),
                      ),
                    ),
                  ),
                if (_hasError)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No se pudo cargar la ruta.',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF82B1FF), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

