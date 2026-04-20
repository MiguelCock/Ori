import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/geojson_service.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/voice_guidance_service.dart';

class NavigationMapScreen extends StatefulWidget {
  final String destinationName;
  final double startLat;
  final double startLng;
  final double destLat;
  final double destLng;
  final String? highlightCategoryId;
  final RouteResult? initialRoute;
  final List<List<double>>? destinationPolygon;

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

  late LatLng _destination;
  late LatLng _currentUser;
  late LatLng _lastRouteOrigin;

  RouteResult? _activeRoute;
  double _currentZoom = 17;

  List<LatLng> _routePoints = [];
  List<_RouteStep> _routeSteps = [];
  double? _routeDistanceMeters;

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

  int _nextStepIndex(LatLng current) {
    if (_routeSteps.isEmpty) return 0;

    for (var i = 0; i < _routeSteps.length; i++) {
      final d = _distanceMeters(
        current.latitude,
        current.longitude,
        _routeSteps[i].location.latitude,
        _routeSteps[i].location.longitude,
      );
      if (d > 10) return i;
    }

    return _routeSteps.length - 1;
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  String _formatAccuracy(double? accuracyMeters) {
    if (accuracyMeters == null || !accuracyMeters.isFinite) return '--';
    return '±${accuracyMeters.round()} m';
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
    final polygon = place?.polygon;
    final mustWait =
        place != null &&
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

    final firstTime = _waitingExitPolygon == null;
    if (mounted) {
      setState(() {
        _waitingExitPlaceName = place!.name;
        _waitingExitPolygon = polygon;
        _waitingExitOutsideSamples = 0;
        _isLoading = false;
        _hasError = false;
      });
    }

    if (firstTime) {
      await _announceAndSpeak(
        'Estás dentro de ${_normalizeText(place!.name)}. Sal para iniciar la navegación.',
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
      _routeSteps = _buildStepsFromPolyline(points);
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
    await voice.startNavigation(
      route: route,
      locationService: location,
      routingService: routing,
      destinationName: widget.destinationName,
      destinationLat: widget.destLat,
      destinationLng: widget.destLng,
      announceForTalkBack: _announce,
      landmarkResolver: (lat, lng) =>
          _geoService?.getNearestBlockReference(lat, lng),
    );
  }

  List<_RouteStep> _buildStepsFromPolyline(List<LatLng> points) {
    if (points.length < 2) return const [];

    final steps = <_RouteStep>[];
    final currentPlace = _geoService?.getPlaceContaining(
      _currentUser.latitude,
      _currentUser.longitude,
    );
    if (currentPlace?.polygon != null &&
        points.length >= 2 &&
        _distanceMeters(
              points[0].latitude,
              points[0].longitude,
              points[1].latitude,
              points[1].longitude,
            ) >=
            2) {
      final exitDistance = _distanceMeters(
        points[0].latitude,
        points[0].longitude,
        points[1].latitude,
        points[1].longitude,
      );
      steps.add(
        _RouteStep(
          instruction:
              'Salga de ${_normalizeText(currentPlace!.name)} hacia la salida más cercana (${exitDistance.round()} m).',
          location: points[1],
        ),
      );
    }

    for (var i = 1; i < points.length; i++) {
      final from = points[i - 1];
      final to = points[i];
      final distance = _distanceMeters(
        from.latitude,
        from.longitude,
        to.latitude,
        to.longitude,
      );

      final instruction = i == points.length - 1
          ? 'Continúa ${distance.round()} m hasta llegar a ${_normalizeText(widget.destinationName)}.'
          : 'Continúa ${distance.round()} m en línea recta.';

      steps.add(_RouteStep(instruction: instruction, location: to));
    }
    return steps;
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

  void _onLocationChanged() {
    final here = _locationService?.currentLocation;
    if (here == null) return;
    final next = LatLng(here.latitude, here.longitude);

    if (!mounted) return;
    setState(() {
      _currentUser = next;
    });

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
      _voiceService = nextVoice;
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
    super.dispose();
  }

  Future<void> _cancelNavigation() async {
    HapticFeedback.heavyImpact();
    final voice = _voiceService;
    if (voice != null) {
      await voice.stopNavigation();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
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
                Column(
                  children: [
                    SizedBox(
                      height: topHeight,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Semantics(
                                    button: true,
                                    label: 'Cancelar ruta',
                                    child: Material(
                                      color: const Color(0xCC1A237E),
                                      borderRadius: BorderRadius.circular(12),
                                      child: IconButton(
                                        onPressed: _cancelNavigation,
                                        icon: const Icon(
                                          Icons.close_rounded,
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
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xD90D1B2A),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _MetricChip(
                                              icon: Icons.straighten_rounded,
                                              label: 'Distancia',
                                              value:
                                                  _routeDistanceMeters == null
                                                  ? '--'
                                                  : _formatDistance(
                                                      _routeDistanceMeters!,
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
                                      const SizedBox(height: 14),
                                      const Text(
                                        'Próximas indicaciones',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        child: nextSteps.isEmpty
                                            ? Align(
                                                alignment: Alignment.topLeft,
                                                child: Text(
                                                  _waitingExitPolygon != null
                                                      ? waitingExitText
                                                      : 'Sin indicaciones disponibles todavía.',
                                                  style: const TextStyle(
                                                    color: Colors.white60,
                                                  ),
                                                ),
                                              )
                                            : ListView.separated(
                                                itemCount: nextSteps.length,
                                                separatorBuilder: (_, __) =>
                                                    const SizedBox(height: 8),
                                                itemBuilder: (context, i) {
                                                  return Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Container(
                                                        width: 22,
                                                        height: 22,
                                                        alignment:
                                                            Alignment.center,
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
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
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
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white70,
                                                                height: 1.3,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: mapHeight,
                      width: double.infinity,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(18),
                          topRight: Radius.circular(18),
                        ),
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
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
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

class _RouteStep {
  final String instruction;
  final LatLng location;

  const _RouteStep({required this.instruction, required this.location});
}
