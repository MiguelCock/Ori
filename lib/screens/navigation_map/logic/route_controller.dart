import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../../../services/geojson_service.dart';
import '../../../services/location_service.dart';
import '../../../services/routing/routing.dart';
import '../../../services/voidce_guidance/voice_guidance.dart';

/// Return type for a completed route load.
class RouteLoadResult {
  final RouteResult route;
  final List<LatLng> points;

  const RouteLoadResult({required this.route, required this.points});
}

/// Encapsulates all route-related logic:
/// - loading / recalculating a local route
/// - the "wait for exit" flow when the user starts inside a building
/// - route simulation
///
/// This is NOT a [ChangeNotifier]; it exposes plain async methods that the
/// owning state calls and then calls [setState] with the returned data.
class RouteController {
  static const double _maxDistanceFromRouteMeters = 22.0;
  static const double _minMoveToRerouteMeters = 35.0;
  static const Duration _minTimeBetweenReroutes = Duration(seconds: 1);
  static const Duration _minTimeBetweenAnnouncements = Duration(seconds: 20);

  final RoutingService routing;
  final GeoJsonService? geoService;
  final List<List<double>>? destinationPolygon;
  final LatLng destination;

  DateTime _lastRouteUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnnouncedReroute = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastRouteOrigin;

  // ── Wait-for-exit state ───────────────────────────────────────────────────
  String? waitingExitPlaceName;
  List<List<double>>? waitingExitPolygon;
  int waitingExitOutsideSamples = 0;

  RouteController({
    required this.routing,
    this.geoService,
    required this.destination,
    this.destinationPolygon,
  });

  // ── Route loading ─────────────────────────────────────────────────────────

  /// Loads a route from [origin] to [destination].
  /// Returns null on failure.
  Future<RouteLoadResult?> loadRoute(LatLng origin) async {
    _lastRouteOrigin = origin;
    _lastRouteUpdate = DateTime.now();

    final route = await routing.buildRoute(
      originLat: origin.latitude,
      originLng: origin.longitude,
      destinationLat: destination.latitude,
      destinationLng: destination.longitude,
      originPolygon:
          geoService?.getPlaceContaining(origin.latitude, origin.longitude)?.polygon,
      destinationPolygon: destinationPolygon,
    );

    if (route == null) return null;
    return RouteLoadResult(
      route: route,
      points: route.polyline.map((p) => LatLng(p.latitude, p.longitude)).toList(),
    );
  }

  // ── Recalculation ─────────────────────────────────────────────────────────

  /// Returns a new [RouteLoadResult] if a recalculation was needed and
  /// succeeded, null otherwise (not due yet, or no improvement).
  Future<RouteLoadResult?> maybeRecalculate(
    LatLng newOrigin,
    List<LatLng> currentRoute, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final enoughTime = now.difference(_lastRouteUpdate) >= _minTimeBetweenReroutes;

    final movedSinceLastOrigin = _lastRouteOrigin == null
        ? double.infinity
        : _distanceMeters(_lastRouteOrigin!, newOrigin);

    final offRoute =
        _distanceToRoute(newOrigin, currentRoute) > _maxDistanceFromRouteMeters;

    if (!force && !enoughTime) return null;
    if (!force && !offRoute && movedSinceLastOrigin < _minMoveToRerouteMeters) {
      return null;
    }

    _lastRouteOrigin = newOrigin;
    _lastRouteUpdate = now;

    final route = await routing.buildRoute(
      originLat: newOrigin.latitude,
      originLng: newOrigin.longitude,
      destinationLat: destination.latitude,
      destinationLng: destination.longitude,
      originPolygon: geoService
          ?.getPlaceContaining(newOrigin.latitude, newOrigin.longitude)
          ?.polygon,
      destinationPolygon: destinationPolygon,
    );

    if (route == null) return null;
    return RouteLoadResult(
      route: route,
      points: route.polyline.map((p) => LatLng(p.latitude, p.longitude)).toList(),
    );
  }

  /// Whether a "rerouted" announcement should be made based on timing.
  bool shouldAnnounceReroute() {
    final now = DateTime.now();
    if (now.difference(_lastAnnouncedReroute) >= _minTimeBetweenAnnouncements) {
      _lastAnnouncedReroute = now;
      return true;
    }
    return false;
  }

  // ── Wait-for-exit ─────────────────────────────────────────────────────────

  /// Returns true if the user is inside a building polygon and navigation
  /// must wait. Populates [waitingExitPlaceName] / [waitingExitPolygon].
  bool checkWaitForExit(LatLng origin) {
    final geo = geoService;
    if (geo == null) return false;

    final place = geo.getPlaceContaining(origin.latitude, origin.longitude);
    if (place == null) return false;

    final polygon = place.polygon;
    if (polygon == null ||
        polygon.length < 3 ||
        !isInsidePolygon(origin.latitude, origin.longitude, polygon)) {
      _clearWaitingExit();
      return false;
    }

    waitingExitPlaceName = place.name;
    waitingExitPolygon = polygon;
    waitingExitOutsideSamples = 0;
    return true;
  }

  /// Should be called on each location update while waiting for exit.
  /// Returns true and clears state when the user has fully exited.
  bool tickWaitingExit(LatLng current) {
    final polygon = waitingExitPolygon;
    if (polygon == null || polygon.length < 3) return false;

    final stillInside =
        isInsidePolygon(current.latitude, current.longitude, polygon);

    if (stillInside) {
      waitingExitOutsideSamples = 0;
      return false;
    }

    waitingExitOutsideSamples++;
    if (waitingExitOutsideSamples < 3) return false;

    _clearWaitingExit();
    return true; // fully exited
  }

  void _clearWaitingExit() {
    waitingExitPlaceName = null;
    waitingExitPolygon = null;
    waitingExitOutsideSamples = 0;
  }

  // ── Route simulation ──────────────────────────────────────────────────────

  /// Drives [locationService] through [simulationPath] at a fixed speed.
  /// [onDone] is called when the loop finishes (naturally or aborted).
  Future<void> runSimulation({
    required List<LatLng> simulationPath,
    required LocationService locationService,
    required VoiceGuidanceService voice,
    required bool Function() isCancelled,
  }) async {
    if (simulationPath.length < 2) return;

    locationService.startSimulation();
    try {
      locationService.seedLocation(LocationData(
        latitude: simulationPath.first.latitude,
        longitude: simulationPath.first.longitude,
        accuracy: 5,
        speed: 0,
        heading: null,
        timestamp: DateTime.now(),
      ));

      for (var i = 1; i < simulationPath.length; i++) {
        if (isCancelled()) break;

        final point = simulationPath[i];
        locationService.setSimulatedLocation(LocationData(
          latitude: point.latitude,
          longitude: point.longitude,
          accuracy: 5,
          speed: i == simulationPath.length - 1 ? 0.6 : 1.2,
          heading: null,
          timestamp: DateTime.now(),
        ));

        await Future<void>.delayed(const Duration(milliseconds: 3600));
      }

      await voice.completeNavigationIfActive();
    } finally {
      locationService.stopSimulation();
    }
  }

  // ── Math helpers ──────────────────────────────────────────────────────────

  static double _distanceMeters(LatLng a, LatLng b) {
    const mpdLat = 111320.0;
    final avgLatRad = ((a.latitude + b.latitude) / 2) * math.pi / 180;
    final mpdLng = mpdLat * math.cos(avgLatRad);
    final dLat = (b.latitude - a.latitude) * mpdLat;
    final dLng = (b.longitude - a.longitude) * mpdLng;
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  static double _distanceToRoute(LatLng p, List<LatLng> route) {
    if (route.length < 2) return double.infinity;
    var best = double.infinity;
    for (var i = 0; i < route.length - 1; i++) {
      final d = _distanceToSegment(p, route[i], route[i + 1]);
      if (d < best) best = d;
    }
    return best;
  }

  static double _distanceToSegment(LatLng p, LatLng a, LatLng b) {
    const mpdLat = 111320.0;
    final avgLatRad =
        ((a.latitude + b.latitude + p.latitude) / 3) * math.pi / 180;
    final mpdLng = mpdLat * math.cos(avgLatRad);

    final ax = a.longitude * mpdLng, ay = a.latitude * mpdLat;
    final bx = b.longitude * mpdLng, by = b.latitude * mpdLat;
    final px = p.longitude * mpdLng, py = p.latitude * mpdLat;

    final abx = bx - ax, aby = by - ay;
    final ab2 = abx * abx + aby * aby;
    if (ab2 == 0) {
      return math.sqrt(math.pow(px - ax, 2) + math.pow(py - ay, 2));
    }

    final t = ((px - ax) * abx + (py - ay) * aby) / ab2;
    final tc = t.clamp(0.0, 1.0);
    final cx = ax + abx * tc, cy = ay + aby * tc;
    return math.sqrt(math.pow(px - cx, 2) + math.pow(py - cy, 2));
  }

  // ignore: library_private_types_in_public_api
  static bool isInsidePolygon(
      double lat, double lon, List<List<double>> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i][0], yi = polygon[i][1];
      final xj = polygon[j][0], yj = polygon[j][1];
      if (((yi > lat) != (yj > lat)) &&
          (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }
}