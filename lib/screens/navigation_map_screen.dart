import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/geojson_service.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';

class NavigationMapScreen extends StatefulWidget {
  final String destinationName;
  final double startLat;
  final double startLng;
  final double destLat;
  final double destLng;
  final String? highlightCategoryId;
  final RouteResult? initialRoute;
  final List<List<double>>? destinationPolygon;
  final String? mbTilesFilePath;
  final String mbTilesAssetPath;

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
    this.mbTilesFilePath,
    this.mbTilesAssetPath = 'assets/data/campus_eafit.mbtiles',
  });

  @override
  State<NavigationMapScreen> createState() => _NavigationMapScreenState();
}

class _NavigationMapScreenState extends State<NavigationMapScreen> {
  final MapController _mapController = MapController();

  GeoJsonService? _geoService;
  LocationService? _locationService;
  RoutingService? _routingService;
  MbTilesTileProvider? _mbTilesProvider;
  String? _mapBaseError;

  bool _isLoading = true;
  bool _hasError = false;
  bool _pendingSceneFit = false;

  late LatLng _destination;
  late LatLng _currentUser;
  late LatLng _lastRouteOrigin;

  List<LatLng> _routePoints = [];
  List<_RouteStep> _routeSteps = [];
  double? _routeDistanceMeters;
  DateTime _lastRouteUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnnouncedReroute = DateTime.fromMillisecondsSinceEpoch(0);

  static const double _maxDistanceFromRouteMeters = 22.0;
  static const double _minMoveToOptionalRerouteMeters = 35.0;
  static const Duration _minTimeBetweenReroutes = Duration(seconds: 7);
  static const Duration _minTimeBetweenAnnouncements = Duration(seconds: 20);

  bool get _usesLocalRouting => widget.initialRoute != null;

  Future<void> _announce(String message) {
    return SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  Color _categoryColor(String id) {
    switch (id) {
      case 'cafeteria':
        return const Color(0xFFE67E22);
      case 'bloque':
        return const Color(0xFF1565C0);
      case 'bano':
        return const Color(0xFF8E24AA);
      case 'porteria':
        return const Color(0xFF455A64);
      case 'parqueadero':
        return const Color(0xFF2E7D32);
      case 'jardin':
        return const Color(0xFF43A047);
      case 'deporte':
        return const Color(0xFFD32F2F);
      default:
        return const Color(0xFF607D8B);
    }
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

  String _instructionFromStep(Map<String, dynamic> step) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? const {};
    final type = (maneuver['type'] ?? '').toString();
    final modifier = (maneuver['modifier'] ?? '').toString();
    final name = (step['name'] ?? '').toString().trim();

    switch (type) {
      case 'depart':
        return name.isEmpty ? 'Sal y comienza a caminar.' : 'Sal por $name.';
      case 'arrive':
        return 'Llegas a ${widget.destinationName}.';
      case 'turn':
        final dir = _modifierLabel(modifier);
        return name.isEmpty ? 'Gira $dir.' : 'Gira $dir hacia $name.';
      case 'continue':
        return name.isEmpty ? 'Sigue recto.' : 'Sigue por $name.';
      case 'new name':
        return name.isEmpty ? 'Continúa por el camino.' : 'Continúa por $name.';
      case 'fork':
        final dir = _modifierLabel(modifier);
        return name.isEmpty
            ? 'Toma la bifurcación $dir.'
            : 'Toma la bifurcación $dir hacia $name.';
      case 'end of road':
        final dir = _modifierLabel(modifier);
        return name.isEmpty
            ? 'Al final del camino, gira $dir.'
            : 'Al final del camino, gira $dir hacia $name.';
      case 'roundabout':
        return name.isEmpty
            ? 'En la glorieta, continúa.'
            : 'En la glorieta, toma la salida hacia $name.';
      default:
        return name.isEmpty
            ? 'Continúa hacia el destino.'
            : 'Continúa por $name.';
    }
  }

  String _modifierLabel(String modifier) {
    switch (modifier) {
      case 'left':
        return 'a la izquierda';
      case 'right':
        return 'a la derecha';
      case 'slight left':
        return 'ligeramente a la izquierda';
      case 'slight right':
        return 'ligeramente a la derecha';
      case 'sharp left':
        return 'fuerte a la izquierda';
      case 'sharp right':
        return 'fuerte a la derecha';
      case 'straight':
        return 'recto';
      default:
        return 'hacia adelante';
    }
  }

  Future<void> _initOfflineMapBase() async {
    try {
      final mbtilesPath = await _resolveMbTilesPath();
      final provider = MbTilesTileProvider.fromPath(path: mbtilesPath);

      if (!mounted) {
        provider.dispose();
        return;
      }

      setState(() {
        _mbTilesProvider = provider;
        _mapBaseError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mapBaseError = 'No se pudo cargar mapa offline: $e';
      });
    }
  }

  Future<String> _resolveMbTilesPath() async {
    if (widget.mbTilesFilePath != null && widget.mbTilesFilePath!.isNotEmpty) {
      return widget.mbTilesFilePath!;
    }

    final appDir = await getApplicationSupportDirectory();
    final fileName = widget.mbTilesAssetPath.split('/').last;
    final localFile = File('${appDir.path}/$fileName');

    if (!await localFile.exists()) {
      final bytes = await rootBundle.load(widget.mbTilesAssetPath);
      await localFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }

    return localFile.path;
  }

  void _applyLocalRoute(RouteResult route) {
    final points = route.polyline
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
    final steps = _buildStepsFromPolyline(points);

    setState(() {
      _routePoints = points;
      _routeSteps = steps;
      _routeDistanceMeters = route.totalDistanceMeters;
      _hasError = points.length < 2;
      _isLoading = false;
      _pendingSceneFit = true;
    });
  }

  List<_RouteStep> _buildStepsFromPolyline(List<LatLng> points) {
    if (points.length < 2) return const [];

    final steps = <_RouteStep>[];
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
          ? 'Continúa ${distance.round()} m hasta llegar a ${widget.destinationName}.'
          : 'Continúa ${distance.round()} m en línea recta.';

      steps.add(_RouteStep(instruction: instruction, location: to));
    }
    return steps;
  }

  Future<void> _loadRoute({required LatLng origin}) async {
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/foot/${origin.longitude},${origin.latitude};${_destination.longitude},${_destination.latitude}?overview=full&geometries=geojson&steps=true',
      );
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'CampusGuiaEAFIT/1.0'},
      );
      if (res.statusCode != 200) {
        throw Exception('OSRM status ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = json['routes'] as List<dynamic>? ?? const [];
      if (routes.isEmpty) throw Exception('No hay ruta disponible');

      final route = routes.first as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>?;
      final coords = geometry?['coordinates'] as List<dynamic>? ?? const [];
      if (coords.length < 2) throw Exception('Ruta vacía');

      final distance = (route['distance'] as num?)?.toDouble();
      final legs = route['legs'] as List<dynamic>? ?? const [];
      final parsedSteps = <_RouteStep>[];
      for (final leg in legs) {
        final legMap = leg as Map<String, dynamic>;
        final steps = legMap['steps'] as List<dynamic>? ?? const [];
        for (final rawStep in steps) {
          final step = rawStep as Map<String, dynamic>;
          final maneuver =
              step['maneuver'] as Map<String, dynamic>? ?? const {};
          final location = maneuver['location'] as List<dynamic>?;
          if (location == null || location.length < 2) continue;
          parsedSteps.add(
            _RouteStep(
              instruction: _instructionFromStep(step),
              location: LatLng(
                (location[1] as num).toDouble(),
                (location[0] as num).toDouble(),
              ),
            ),
          );
        }
      }

      final points = coords.map<LatLng>((c) {
        final pair = c as List<dynamic>;
        final lng = (pair[0] as num).toDouble();
        final lat = (pair[1] as num).toDouble();
        return LatLng(lat, lng);
      }).toList();

      if (!mounted) return;
      setState(() {
        _routePoints = points;
        _routeSteps = parsedSteps;
        _routeDistanceMeters = distance;
        _hasError = false;
        _isLoading = false;
        _pendingSceneFit = true;
      });
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

  List<LatLng> _scenePoints(List<Polygon> polygons) {
    final points = <LatLng>[
      _currentUser,
      _destination,
      ..._routePoints,
    ];

    for (final polygon in polygons) {
      points.addAll(polygon.points);
    }

    return points;
  }

  void _fitScene(List<Polygon> polygons) {
    final points = _scenePoints(polygons);
    if (points.isEmpty) return;

    if (points.length == 1) {
      _mapController.move(points.first, 17);
      return;
    }

    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(28)),
    );
  }

  Future<void> _recalculateRoute({
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

    _lastRouteOrigin = newOrigin;
    _lastRouteUpdate = now;

    setState(() {
      _currentUser = newOrigin;
      _isLoading = true;
      _hasError = false;
    });

    await _loadRoute(origin: newOrigin);

    if (now.difference(_lastAnnouncedReroute) >= _minTimeBetweenAnnouncements) {
      _lastAnnouncedReroute = now;
      _announce('Ruta recalculada por cambio de ubicación.');
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
    setState(() => _currentUser = next);

    if (_usesLocalRouting) {
      _recalculateLocalRoute(newOrigin: next);
    } else {
      _recalculateRoute(newOrigin: next);
    }
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

  @override
  void initState() {
    super.initState();
    _destination = LatLng(widget.destLat, widget.destLng);
    _currentUser = LatLng(widget.startLat, widget.startLng);
    _lastRouteOrigin = _currentUser;
    _lastRouteUpdate = DateTime.now();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initOfflineMapBase();

      if (_usesLocalRouting && widget.initialRoute != null) {
        _announce('Mostrando ruta local a ${widget.destinationName}.');
        _applyLocalRoute(widget.initialRoute!);
        return;
      }

      _announce('Mostrando ruta a ${widget.destinationName}.');
      await _loadRoute(origin: _currentUser);
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

    final here = _locationService?.currentLocation;
    if (here != null) {
      _currentUser = LatLng(here.latitude, here.longitude);
      _lastRouteOrigin = _currentUser;
    }
  }

  @override
  void dispose() {
    _locationService?.removeListener(_onLocationChanged);
    _mbTilesProvider?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final polygons = _buildCampusPolygons(geo);
    final selectedLabel = widget.highlightCategoryId == null
        ? null
        : geo.categoryById(widget.highlightCategoryId!)?.label;
    final nextIndex = _nextStepIndex(_currentUser);
    final nextSteps = _routeSteps.skip(nextIndex).take(3).toList();

    if (_pendingSceneFit && !_isLoading) {
      _pendingSceneFit = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _fitScene(polygons);
      });
    }

    final routeNodeMarkers = <Marker>[];
    if (_routePoints.length >= 2) {
      for (var i = 1; i < _routePoints.length; i++) {
        final point = _routePoints[i];
        final isDestinationNode = i == _routePoints.length - 1;
        routeNodeMarkers.add(
          Marker(
            point: point,
            width: isDestinationNode ? 18 : 12,
            height: isDestinationNode ? 18 : 12,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFFD54F),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFF9A825),
                  width: isDestinationNode ? 2.4 : 1.4,
                ),
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final mapHeight = constraints.maxHeight / 3;

          return Stack(
            children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: double.infinity,
                  height: mapHeight,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                    ),
                    child: FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _currentUser,
                        initialZoom: 17,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                      ),
                      children: [
                        if (_mbTilesProvider != null)
                          TileLayer(
                            tileProvider: _mbTilesProvider,
                            urlTemplate: 'mbtiles://{z}/{x}/{y}',
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
                            ...routeNodeMarkers,
                            Marker(
                              point: _currentUser,
                              width: 18,
                              height: 18,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF82B1FF),
                                  borderRadius: BorderRadius.circular(9),
                                  border: Border.all(
                                    color: const Color(0xFF1565C0),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Semantics(
                            button: true,
                            label: 'Volver',
                            child: Material(
                              color: const Color(0xCC1A237E),
                              borderRadius: BorderRadius.circular(12),
                              child: IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(
                                  Icons.arrow_back,
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
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                widget.destinationName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xCC0D1B2A),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _MetricChip(
                                    icon: Icons.straighten_rounded,
                                    label: 'Distancia',
                                    value: _routeDistanceMeters == null
                                        ? '--'
                                        : _formatDistance(
                                            _routeDistanceMeters!,
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
                            if (nextSteps.isEmpty)
                              const Text(
                                'Sin indicaciones disponibles todavía.',
                                style: TextStyle(color: Colors.white60),
                              )
                            else
                              for (var i = 0; i < nextSteps.length; i++)
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom: i == nextSteps.length - 1 ? 0 : 8,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 22,
                                        height: 22,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1565C0),
                                          borderRadius: BorderRadius.circular(
                                            11,
                                          ),
                                        ),
                                        child: Text(
                                          '${i + 1}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          nextSteps[i].instruction,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            height: 1.3,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (selectedLabel != null)
                Positioned(
                  left: 12,
                  top: 72,
                  child: IgnorePointer(
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
                        'Filtro: $selectedLabel',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Color(0xFF82B1FF)),
                ),
              if (_hasError)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.wifi_off_rounded,
                          color: Colors.white54,
                          size: 36,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'No se pudo cargar la ruta.',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_mapBaseError != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xCC3E2723),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFFAB91)),
                    ),
                    child: Text(
                      _mapBaseError!,
                      style: const TextStyle(
                        color: Color(0xFFFFCCBC),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
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
