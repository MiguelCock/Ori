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

  static const double _fixedZoom = 20.0;

  GeoJsonService? _geoService;
  LocationService? _locationService;
  RoutingService? _routingService;
  VoiceGuidanceService? _voiceService;

  bool _isLoading = true;
  bool _hasError = false;
  bool _voiceStarted = false;
  bool _routeSimulationRunning = false;
  bool _autoSimulationScheduled = false;

  late LatLng _destination;
  late LatLng _currentUser;
  late LatLng _lastRouteOrigin;

  RouteResult? _activeRoute;

  List<LatLng> _routePoints = [];
  List<GuidanceStep> _routeSteps = [];
  double? _routeDistanceMeters;
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

  bool get _accessibilityActive {
    return SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;
  }

  Future<void> _announceAndSpeak(String message) async {
    if (_accessibilityActive) {
      await _announce(message);
      return;
    }

    await _voiceService?.speakMessage(message);
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

    // Cuando la posición del usuario cambia, re-centrar el mapa en el GPS.
    _centerMapOnUser();
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
        landmarkResolver: (lat, lng, headingDegrees) => geoService == null
            ? null
            : geoService.getNearestBlockReference(
                lat,
                lng,
              ),
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
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ArrivalCelebrationDialog(destination: widget.destinationName),
    );

    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _togglePauseNavigation() async {
    final voice = _voiceService;
    if (voice == null) return;
    if (voice.isPaused) {
      await voice.resumeNavigation();
      await _announce('Navegación reanudada.');
    } else {
      await voice.pauseNavigation();
      await _announce('Navegación pausada.');
    }
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

  Future<void> _recalculateLocalRoute({
    required LatLng newOrigin,
    bool force = false,
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

    if (!force && !enoughTime) return;
    if (!force &&
        !(isOffRoute ||
            movedSinceLastOrigin >= _minMoveToOptionalRerouteMeters)) {
      return;
    }

    final routing = _routingService;
    if (routing == null) return;

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

    if (!mounted) return;
    if (updated == null) {
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
      return;
    }

    _applyLocalRoute(updated);

    if (now.difference(_lastAnnouncedReroute) >= _minTimeBetweenAnnouncements) {
      _lastAnnouncedReroute = now;
      _announce('Ruta local recalculada por cambio de ubicación.');
    }
  }

  /// Centra el mapa sobre la posición actual del usuario con el zoom fijo.
  void _centerMapOnUser() {
    try {
      _mapController.move(_currentUser, _fixedZoom);
    } catch (_) {
      // El controlador puede no estar listo todavía; se ignora silenciosamente.
    }
  }

  void _onLocationChanged() {
    final here = _locationService?.currentLocation;
    if (here == null) return;
    final next = LatLng(here.latitude, here.longitude);

    if (!mounted) return;

    final voice = _voiceService;
    final destinationPolygon = widget.destinationPolygon;
    if (voice?.isNavigating == true &&
        !voice!.isPaused &&
        destinationPolygon != null &&
        destinationPolygon.length >= 3 &&
        _isInsidePolygon(
          next.latitude,
          next.longitude,
          destinationPolygon,
        )) {
      voice.completeNavigationIfActive();
      return;
    }

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

    // Re-centrar el mapa sobre el GPS cada vez que la posición cambie.
    _centerMapOnUser();

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
    if (here != null) {
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

  Future<void> _cancelNavigation() async {
    HapticFeedback.heavyImpact();
    final voice = _voiceService;
    if (voice != null) {
      try {
        await voice.stopSpeaking();
      } catch (_) {}
      await voice.stopNavigation(speak: false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Construye el label semántico del título para TalkBack.
  /// Formato: "Ubicación, cerca de <referencia>, Destino <nombre>"
  String _buildTitleSemanticLabel() {
    final location = _locationService?.currentLocation;
    final lat = location?.latitude ?? _currentUser.latitude;
    final lng = location?.longitude ?? _currentUser.longitude;

    final placeName = _geoService?.getPlaceContaining(lat, lng)?.name;
    final nearbyRef = _geoService?.getNearestBlockReference(lat, lng);

    final locationPart = placeName != null
        ? 'Ubicación, ${_normalizeText(placeName)}'
        : (nearbyRef != null
            ? 'Ubicación, cerca de ${_normalizeText(nearbyRef)}'
            : 'Ubicación actual');

    return '$locationPart. Destino: ${_normalizeText(widget.destinationName)}';
  }

  @override
  Widget build(BuildContext context) {
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final polygons = _buildCampusPolygons(geo);
    final polygonLabels = _buildPolygonLabels(geo);
    final voice = _voiceService;

    final currentInstruction = voice != null && voice.currentInstruction.isNotEmpty
        ? voice.currentInstruction
        : (_routeSteps.isNotEmpty
            ? _routeSteps.first.instruction
            : 'Sin indicaciones disponibles todavía.');

    final waitingExitText = _waitingExitPlaceName == null
        ? 'Estás dentro de un área. Sal para iniciar la navegación.'
        : 'Estás dentro de ${_normalizeText(_waitingExitPlaceName!)}. Sal para iniciar la navegación.';

    final displayedInstruction = _waitingExitPolygon != null
        ? waitingExitText
        : _normalizeText(currentInstruction);

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

    const maxZoom = _fixedZoom;
    const minZoom = 3.0;

    return WillPopScope(
      onWillPop: () async {
        await _cancelNavigation();
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final mapHeight = constraints.maxHeight / 3;
            final topHeight = constraints.maxHeight - mapHeight;

            return Stack(
              children: [
                // ── Capa 1: columna con header + mapa ──────────────────────
                Column(
                  children: [
                    // Header: botón volver + título + indicación
                    SizedBox(
                      height: topHeight,
                      child: SafeArea(
                        bottom: false,
                        child: Stack(
                          children: [
                            // ── Contenido visual (excluido de semantics) ──────
                            // Todo lo visual se dibuja aquí, pero TalkBack lo
                            // ignora por completo. Los nodos semánticos reales
                            // son el botón y el título declarados abajo.
                            ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    // Fila visual: ← + título
                                    SizedBox(
                                      height: 48,
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          const SizedBox(width: 48), // espejo del botón
                                          Expanded(
                                            child: Text(
                                              _normalizeText(widget.destinationName),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 48),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    // Indicación centrada
                                    Expanded(
                                      child: Center(
                                        child: Text(
                                          displayedInstruction,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w700,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Distancia restante (solo visual)
                                    Text(
                                      _remainingDistanceMeters == null
                                          ? 'Distancia restante no disponible.'
                                          : 'Distancia restante: ${_formatDistance(_remainingDistanceMeters!)}.',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    // Hint visual (solo visual)
                                    Text(
                                      'Toca la pantalla para repetir la indicación.',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // ── Nodo semántico 1: Botón volver ───────────────
                            Positioned(
                              left: 0,
                              top: 10,
                              child: Semantics(
                                button: true,
                                label: 'Finalizar navegación',
                                hint: 'Detiene la navegación y regresa',
                                excludeSemantics: true,
                                child: IconButton(
                                  icon: const Icon(
                                    Icons.arrow_back,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                  onPressed: _cancelNavigation,
                                  tooltip: 'Finalizar navegación',
                                  padding: const EdgeInsets.all(8),
                                ),
                              ),
                            ),

                            // ── Nodo semántico 2: Título ─────────────────────
                            Positioned(
                              left: 48,
                              right: 48,
                              top: 10,
                              height: 48,
                              child: Semantics(
                                label: _buildTitleSemanticLabel(),
                                excludeSemantics: true,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── CAMBIO 1: Mapa no interactuable, zoom fijo al GPS ──
                    SizedBox(
                      height: mapHeight,
                      width: double.infinity,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(18),
                          topRight: Radius.circular(18),
                        ),
                        child: ExcludeSemantics(
                          child: IgnorePointer(
                            // El mapa no responde a ningún gesto del usuario.
                            child: FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: _currentUser,
                                initialZoom: _fixedZoom,
                                minZoom: minZoom,
                                maxZoom: maxZoom,
                                // Sin flags de interacción: el mapa es estático.
                                interactionOptions: const InteractionOptions(
                                  flags: InteractiveFlag.none,
                                ),
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

                // ── CAMBIO 4: Semantics y área táctil separadas ────────────
                Positioned(
                  left: 0,
                  right: 0,
                  top: topHeight,
                  height: 0,
                  child: Semantics(
                    label: displayedInstruction,
                    excludeSemantics: true,
                    child: const SizedBox.shrink(),
                  ),
                ),
                Positioned.fill(
                  top: topHeight,
                  child: Semantics(
                    focusable: true,
                    onTap: _repeatCurrentGuidanceFromGesture,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _repeatCurrentGuidanceFromGesture,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),

                // ── Overlays de carga y error (igual que antes) ─────────────
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
    );
  }
}

class _ArrivalCelebrationDialog extends StatefulWidget {
  final String destination;
  const _ArrivalCelebrationDialog({required this.destination});

  @override
  State<_ArrivalCelebrationDialog> createState() => _ArrivalCelebrationDialogState();
}

class _ArrivalCelebrationDialogState extends State<_ArrivalCelebrationDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await HapticService.trigger(HapticEvent.destinationReached);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B1620),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
              child: const Icon(Icons.celebration_rounded, size: 64, color: Color(0xFF66BB6A)),
            ),
            const SizedBox(height: 12),
            Text(
              'Has llegado',
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.destination,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'La navegación se cerrará en un momento.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}