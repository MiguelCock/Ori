import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/geojson_service.dart';
import '../../services/location_service.dart';
import '../../services/route_guidance_builder.dart';
import '../../services/routing/routing.dart';
import '../../services/voidce_guidance/voice_guidance.dart';
import 'logic/map_layer_builder.dart';
import 'logic/route_controller.dart';
import 'widgets/arrival_celebration_dialog.dart';
import 'widgets/navigation_header.dart';

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
  // ── Constants ─────────────────────────────────────────────────────────────
  static const double _fixedZoom = 20.0;

  // ── Services (wired in didChangeDependencies) ─────────────────────────────
  GeoJsonService? _geoService;
  LocationService? _locationService;
  RoutingService? _routingService;
  VoiceGuidanceService? _voiceService;
  RouteController? _routeController;

  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();

  // ── State ─────────────────────────────────────────────────────────────────
  bool _isLoading = true;
  bool _hasError = false;
  bool _voiceStarted = false;
  bool _routeSimulationRunning = false;
  bool _autoSimulationScheduled = false;

  late LatLng _destination;
  late LatLng _currentUser;

  RouteResult? _activeRoute;
  List<LatLng> _routePoints = [];
  List<GuidanceStep> _routeSteps = [];
  double? _routeDistanceMeters;
  double? _remainingDistanceMeters;

  bool get _usesLocalRouting => widget.initialRoute != null;

  // ── Accessibility ─────────────────────────────────────────────────────────

  Future<void> _announce(String message) => SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );

  bool get _accessibilityActive =>
      SemanticsBinding.instance.semanticsEnabled ||
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
          .accessibleNavigation;

  Future<void> _announceAndSpeak(String message) async {
    if (_accessibilityActive) {
      await _announce(message);
      return;
    }
    await _voiceService?.speakMessage(message);
  }

  // ── Text normalization ────────────────────────────────────────────────────

  static String _normalize(String text) => text
      .replaceAll('Ã¡', 'á')
      .replaceAll('Ã©', 'é')
      .replaceAll('Ã­', 'í')
      .replaceAll('Ã³', 'ó')
      .replaceAll('Ãº', 'ú')
      .replaceAll('Ã±', 'ñ')
      .replaceAll('Â', '');

  // ── Map centering ─────────────────────────────────────────────────────────

  void _centerMapOnUser() {
    try {
      _mapController.move(_currentUser, _fixedZoom);
    } catch (_) {}
  }

  // ── Voice guidance sync ───────────────────────────────────────────────────

  void _syncVoiceGuidanceState() {
    final voice = _voiceService;
    if (voice == null || !mounted) return;

    setState(() {
      _activeRoute = voice.activeRoute;
      _routePoints = voice.activePolyline
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();
      _routeSteps = List<GuidanceStep>.from(voice.guidanceSteps);
      final dist = voice.activeRoute?.totalDistanceMeters;
      if (dist != null) _routeDistanceMeters = dist;
      if (voice.isNavigating) {
        _hasError = false;
        _isLoading = false;
      }
    });

    _centerMapOnUser();
  }

  // ── Route application ─────────────────────────────────────────────────────

  void _applyRoute(RouteResult route, List<LatLng> points) {
    _activeRoute = route;
    setState(() {
      _routePoints = points;
      _routeSteps = List<GuidanceStep>.from(
        _voiceService?.guidanceSteps ?? const [],
      );
      _routeDistanceMeters = route.totalDistanceMeters;
      _hasError = points.length < 2;
      _isLoading = false;
    });
  }

  // ── Voice guidance start ──────────────────────────────────────────────────

  Future<void> _startVoiceIfNeeded() async {
    if (_voiceStarted || _activeRoute == null) return;

    final voice = _voiceService;
    final route = _activeRoute;
    final location = _locationService;
    final routing = _routingService;
    if (voice == null || route == null || location == null || routing == null) {
      return;
    }

    _voiceStarted = true;
    voice.setSuppressTtsWhenAccessibility(
        SemanticsBinding.instance.semanticsEnabled);

    if (!voice.isNavigating) {
      await voice.startNavigation(
        route: route,
        locationService: location,
        routingService: routing,
        destinationName: widget.destinationName,
        destinationLat: widget.destLat,
        destinationLng: widget.destLng,
        announceForTalkBack: _announce,
        landmarkResolver: (lat, lng, _) =>
            _geoService?.getNearestBlockReference(lat, lng),
        onArrival: _showArrivalOverlay,
        skipInitialCalibration: widget.autoStartSimulation,
      );
    } else {
      _syncVoiceGuidanceState();
    }

    if (widget.autoStartSimulation && !_autoSimulationScheduled) {
      _autoSimulationScheduled = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) { if (mounted) _runSimulation(); });
    }
  }

  // ── Arrival overlay ───────────────────────────────────────────────────────

  Future<void> _showArrivalOverlay() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ArrivalCelebrationDialog(
          destination: _normalize(widget.destinationName)),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  // ── Gesture: repeat instruction ───────────────────────────────────────────

  Future<void> _repeatInstruction() async {
    final voice = _voiceService;
    if (voice == null || !voice.isNavigating) return;

    final location = _locationService?.currentLocation;
    final lat = location?.latitude ?? _currentUser.latitude;
    final lng = location?.longitude ?? _currentUser.longitude;

    final placeName = _geoService?.getPlaceContaining(lat, lng)?.name;
    final nearbyRef = _geoService?.getNearestBlockReference(lat, lng);

    final locationText = placeName != null
        ? 'Ubicación actual: ${_normalize(placeName)}.'
        : nearbyRef != null
            ? 'Ubicación actual: cerca de ${_normalize(nearbyRef)}.'
            : 'Ubicación actual registrada.';

    final instruction = voice.currentInstruction.isNotEmpty
        ? voice.currentInstruction
        : _routeSteps.isNotEmpty
            ? _routeSteps.first.instruction
            : 'Sin indicaciones disponibles por ahora.';

    final remaining =
        _remainingDistanceMeters ?? voice.getRemainingDistance(lat, lng);
    final remainingText =
        remaining > 0 ? ' Distancia restante ${_formatDistance(remaining)}.' : '';

    await HapticFeedback.selectionClick();
    await voice.speak('$locationText $instruction$remainingText');
  }

  // ── Cancel navigation ─────────────────────────────────────────────────────

  Future<void> _cancelNavigation() async {
    HapticFeedback.heavyImpact();
    final voice = _voiceService;
    if (voice != null) {
      try { await voice.stopSpeaking(); } catch (_) {}
      await voice.stopNavigation(speak: false);
    }
    if (mounted) Navigator.of(context).pop();
  }

  // ── Simulation ────────────────────────────────────────────────────────────

  Future<void> _runSimulation() async {
    if (_routeSimulationRunning) return;
    final voice = _voiceService;
    final location = _locationService;
    final routeCtrl = _routeController;
    if (voice == null || location == null || routeCtrl == null) return;
    if (!voice.isNavigating) {
      await _announce('Primero inicia una navegación para simularla.');
      return;
    }

    final path = _routePoints.isNotEmpty
        ? List<LatLng>.from(_routePoints)
        : _routeSteps
            .map((s) => LatLng(s.endPoint.latitude, s.endPoint.longitude))
            .toList();

    if (path.length < 2) {
      await _announce('No hay una ruta suficiente para simular.');
      return;
    }

    setState(() => _routeSimulationRunning = true);
    await _announceAndSpeak('Simulación de navegación iniciada.');

    try {
      await routeCtrl.runSimulation(
        simulationPath: path,
        locationService: location,
        voice: voice,
        isCancelled: () => !_routeSimulationRunning,
      );
    } finally {
      if (mounted) setState(() => _routeSimulationRunning = false);
      else _routeSimulationRunning = false;
    }
  }

  // ── Location change handler ───────────────────────────────────────────────

  void _onLocationChanged() {
    final here = _locationService?.currentLocation;
    if (here == null || !mounted) return;

    final next = LatLng(here.latitude, here.longitude);
    final voice = _voiceService;
    final destPolygon = widget.destinationPolygon;

    // Arrived inside destination polygon?
    if (voice?.isNavigating == true &&
        !(voice!.isPaused) &&
        destPolygon != null &&
        destPolygon.length >= 3 &&
        RouteController.isInsidePolygon(
            next.latitude, next.longitude, destPolygon)) {
      voice.completeNavigationIfActive();
      return;
    }

    final remaining = voice?.getRemainingDistance(here.latitude, here.longitude);
    setState(() {
      _currentUser = next;
      _remainingDistanceMeters =
          (remaining != null && remaining > 0) ? remaining : _routeDistanceMeters;
    });
    _centerMapOnUser();

    // If voice guidance is active it handles rerouting internally.
    if (voice?.isNavigating == true) return;

    // Wait-for-exit flow.
    final routeCtrl = _routeController;
    if (routeCtrl == null) return;

    if (routeCtrl.waitingExitPolygon != null) {
      final exited = routeCtrl.tickWaitingExit(next);
      setState(() {}); // refresh waiting-exit display
      if (exited) {
        final name = routeCtrl.waitingExitPlaceName;
        _announceAndSpeak(
          'Perfecto. Ya saliste de ${_normalize(name ?? 'el bloque')}. Iniciando ruta.',
        );
        _loadRoute(origin: next);
      }
      return;
    }

    _recalculate(newOrigin: next);
  }

  // ── Route load / recalc ───────────────────────────────────────────────────

  Future<void> _loadRoute({required LatLng origin}) async {
    final routeCtrl = _routeController;
    if (routeCtrl == null) return;

    setState(() { _isLoading = true; _hasError = false; });

    final result = await routeCtrl.loadRoute(origin);
    if (!mounted) return;

    if (result == null) {
      setState(() { _hasError = true; _routePoints = []; _isLoading = false; });
      return;
    }

    _applyRoute(result.route, result.points);
    await _startVoiceIfNeeded();
  }

  Future<void> _recalculate({required LatLng newOrigin}) async {
    final routeCtrl = _routeController;
    if (routeCtrl == null) return;

    setState(() { _currentUser = newOrigin; });

    final result =
        await routeCtrl.maybeRecalculate(newOrigin, _routePoints);
    if (!mounted || result == null) return;

    _applyRoute(result.route, result.points);
    if (routeCtrl.shouldAnnounceReroute()) {
      _announce('Ruta local recalculada por cambio de ubicación.');
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _destination = LatLng(widget.destLat, widget.destLng);
    _currentUser = LatLng(widget.startLat, widget.startLng);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Auto-simulation shortcut.
      if (_usesLocalRouting && widget.autoStartSimulation) {
        await _announce(
            'Mostrando ruta local a ${widget.destinationName}.');
        _applyRoute(
          widget.initialRoute!,
          widget.initialRoute!.polyline
              .map((p) => LatLng(p.latitude, p.longitude))
              .toList(),
        );
        await _startVoiceIfNeeded();
        return;
      }

      // Check wait-for-exit before doing anything.
      final routeCtrl = _routeController;
      if (routeCtrl != null &&
          routeCtrl.checkWaitForExit(_currentUser)) {
        setState(() { _isLoading = false; _hasError = false; });
        await _announceAndSpeak(
          'Estás dentro de ${_normalize(routeCtrl.waitingExitPlaceName ?? 'un área')}. Sal para iniciar la navegación.',
        );
        return;
      }

      if (_usesLocalRouting && widget.initialRoute != null) {
        await _announce('Mostrando ruta local a ${widget.destinationName}.');
        _applyRoute(
          widget.initialRoute!,
          widget.initialRoute!.polyline
              .map((p) => LatLng(p.latitude, p.longitude))
              .toList(),
        );
        await _startVoiceIfNeeded();
        return;
      }

      await _announce('Mostrando ruta a ${widget.destinationName}.');
      await _loadRoute(origin: _currentUser);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final nextGeo = Provider.of<GeoJsonService>(context, listen: false);
    if (!identical(_geoService, nextGeo)) _geoService = nextGeo;

    final nextLoc = Provider.of<LocationService>(context, listen: false);
    if (!identical(_locationService, nextLoc)) {
      _locationService?.removeListener(_onLocationChanged);
      _locationService = nextLoc;
      _locationService?.addListener(_onLocationChanged);
    }

    final nextRouting = Provider.of<RoutingService>(context, listen: false);
    if (!identical(_routingService, nextRouting)) {
      _routingService = nextRouting;
      // Rebuild RouteController whenever routing service changes.
      if (nextRouting != null) {
        _routeController = RouteController(
          routing: nextRouting,
          geoService: _geoService,
          destination: _destination,
          destinationPolygon: widget.destinationPolygon,
        );
      }
    }

    final nextVoice =
        Provider.of<VoiceGuidanceService>(context, listen: false);
    if (!identical(_voiceService, nextVoice)) {
      _voiceService?.removeListener(_syncVoiceGuidanceState);
      _voiceService = nextVoice;
      _voiceService?.addListener(_syncVoiceGuidanceState);
    }

    final here = _locationService?.currentLocation;
    if (here != null) {
      _currentUser = LatLng(here.latitude, here.longitude);
    }
  }

  @override
  void dispose() {
    _locationService?.removeListener(_onLocationChanged);
    _voiceService?.removeListener(_syncVoiceGuidanceState);
    super.dispose();
  }

  // ── Semantic helpers ──────────────────────────────────────────────────────

  String _buildTitleSemanticLabel() {
    final loc = _locationService?.currentLocation;
    final lat = loc?.latitude ?? _currentUser.latitude;
    final lng = loc?.longitude ?? _currentUser.longitude;

    final placeName = _geoService?.getPlaceContaining(lat, lng)?.name;
    final nearbyRef = _geoService?.getNearestBlockReference(lat, lng);

    final locationPart = placeName != null
        ? 'Ubicación, ${_normalize(placeName)}'
        : nearbyRef != null
            ? 'Ubicación, cerca de ${_normalize(nearbyRef)}'
            : 'Ubicación actual';

    return '$locationPart. Destino: ${_normalize(widget.destinationName)}';
  }

  // ── Nearest route point (for marker highlighting) ─────────────────────────

  int? _nearestRoutePointIndex() {
    if (_routePoints.isEmpty) return null;
    var bestIndex = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < _routePoints.length; i++) {
      final p = _routePoints[i];
      final d = math.sqrt(
        math.pow((_currentUser.latitude - p.latitude) * 111320, 2) +
        math.pow((_currentUser.longitude - p.longitude) * 111320, 2),
      );
      if (d < bestDist) { bestDist = d; bestIndex = i; }
    }
    return bestIndex;
  }

  static String _formatDistance(double meters) =>
      meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final layerBuilder =
        MapLayerBuilder(highlightCategoryId: widget.highlightCategoryId);

    final polygons = layerBuilder.buildCampusPolygons(geo);
    final polygonLabels = layerBuilder.buildPolygonLabels(geo, _normalize);
    final routeNodeMarkers = layerBuilder.buildRouteNodeMarkers(
        _routePoints, _nearestRoutePointIndex());
    final userMarker = MapLayerBuilder.buildUserMarker(_currentUser);

    final voice = _voiceService;
    final routeCtrl = _routeController;

    // Resolve displayed instruction.
    final String displayedInstruction;
    if (routeCtrl?.waitingExitPolygon != null) {
      final name = routeCtrl!.waitingExitPlaceName;
      displayedInstruction = name == null
          ? 'Estás dentro de un área. Sal para iniciar la navegación.'
          : 'Estás dentro de ${_normalize(name)}. Sal para iniciar la navegación.';
    } else {
      final raw = voice != null && voice.currentInstruction.isNotEmpty
          ? voice.currentInstruction
          : _routeSteps.isNotEmpty
              ? _routeSteps.first.instruction
              : 'Sin indicaciones disponibles todavía.';
      displayedInstruction = _normalize(raw);
    }

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
                // ── Header + map ──────────────────────────────────────────
                Column(
                  children: [
                    SizedBox(
                      height: topHeight,
                      child: NavigationHeader(
                        destinationName: _normalize(widget.destinationName),
                        instruction: displayedInstruction,
                        remainingDistanceMeters: _remainingDistanceMeters,
                        semanticTitleLabel: _buildTitleSemanticLabel(),
                        onCancel: _cancelNavigation,
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
                        child: ExcludeSemantics(
                          child: IgnorePointer(
                            child: FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: _currentUser,
                                initialZoom: _fixedZoom,
                                minZoom: 3.0,
                                maxZoom: _fixedZoom,
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
                                  PolylineLayer(polylines: [
                                    Polyline(
                                      points: _routePoints,
                                      strokeWidth: 5,
                                      color: const Color(0xFF1976D2),
                                    ),
                                  ]),
                                MarkerLayer(markers: [
                                  ...polygonLabels,
                                  ...routeNodeMarkers,
                                  userMarker,
                                ]),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                // ── Semantic instruction node (above map) ─────────────────
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

                // ── Tap-to-repeat area (map zone) ─────────────────────────
                Positioned.fill(
                  top: topHeight,
                  child: Semantics(
                    focusable: true,
                    onTap: _repeatInstruction,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _repeatInstruction,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),

                // ── Loading indicator ─────────────────────────────────────
                if (_isLoading)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF82B1FF)),
                      ),
                    ),
                  ),

                // ── Error message ─────────────────────────────────────────
                if (_hasError)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No se pudo cargar la ruta.',
                            style: TextStyle(
                                color: Colors.white, fontSize: 16),
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