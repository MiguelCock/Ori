import 'package:flutter/foundation.dart';

import '../graph/graph_node.dart';
import '../graph/routing_graph.dart';
import '../models/route_models.dart';
import 'geometry.dart';

class RoutingService extends ChangeNotifier {
  static const _assetPath = 'assets/data/routing_graph.json';

  RoutingGraph? _graph;

  RoutingStatus _status = RoutingStatus.idle;
  String _lastError = '';
  RouteResult? _currentRoute;

  bool get isLoaded => _graph != null;
  RoutingStatus get status => _status;
  String get lastError => _lastError;
  RouteResult? get currentRoute => _currentRoute;

  // ── Loading ───────────────────────────────────────────────────────────────

  Future<void> load() async {
    if (isLoaded) return;
    try {
      _graph = await RoutingGraph.fromAsset(_assetPath);
      notifyListeners();
      debugPrint('✅ Grafo cargado: ${_graph!.nodes.length} nodos');
    } catch (e) {
      _setError('Error al cargar el grafo: $e');
    }
  }

  // ── Public routing entry point ────────────────────────────────────────────

  Future<RouteResult?> buildRoute({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    List<List<double>>? originPolygon,
    List<List<double>>? destinationPolygon,
  }) async {
    if (!isLoaded) {
      await load();
      if (!isLoaded) return null;
    }

    _status = RoutingStatus.loading;
    _lastError = '';
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    final graph = _graph!;

    // ── Entry candidates (origin side) ────────────────────────────────────

    final entryCandidates = _entryProjections(
      graph,
      originLat,
      originLng,
      originPolygon,
    );

    final destinationId = graph.nearestNodeId(destinationLat, destinationLng);

    if (entryCandidates.isEmpty || destinationId == null) {
      return _setError(
        'No fue posible ubicar una arista de entrada o nodos cercanos para el destino.',
      );
    }

    // ── Destination candidates ────────────────────────────────────────────

    final destinationProjections =
        destinationPolygon != null && destinationPolygon.length >= 3
            ? _boundaryProjections(graph, destinationPolygon)
            : const <EdgeProjection>[];

    // ── Search best route across all candidate combinations ───────────────

    RouteResult? bestRoute;
    double bestDistance = double.infinity;

    for (final entry in entryCandidates) {
      final workingGraph = graph.withVirtualNode(entry);

      final targets = destinationProjections.isNotEmpty
          ? destinationProjections
          : [null]; // null sentinel → use destinationId

      for (final dest in targets) {
        Map<String, GraphNode> searchGraph = workingGraph;
        String goalId = destinationId;

        if (dest != null) {
          searchGraph = graph.withVirtualNode(dest, workingGraph);
          goalId = dest.entryNodeId;
        }

        final path = graph.findPath(
          entry.entryNodeId,
          goalId,
          graph: searchGraph,
        );
        if (path == null || path.isEmpty) continue;

        var polyline = _buildPolyline(
          searchGraph,
          path,
          originLat,
          originLng,
        );

        if (dest == null &&
            destinationPolygon != null &&
            destinationPolygon.length >= 3) {
          polyline = _trimPolylineAtPolygon(polyline, destinationPolygon);
        }

        final distance = _polylineDistance(polyline);
        if (distance < bestDistance) {
          bestDistance = distance;
          bestRoute = RouteResult(
            nodePath: path,
            polyline: polyline,
            totalDistanceMeters: distance,
            estimatedWalkTime:
                Duration(seconds: (distance / 1.35).round()),
            exploredNodes: path.length,
            computationTimeMs: stopwatch.elapsedMilliseconds,
            originNodeId: entry.entryNodeId,
            destinationNodeId: goalId,
          );
        }
      }
    }

    stopwatch.stop();

    if (bestRoute == null) {
      return _setError(
        'No existe una ruta peatonal conectada entre origen y destino.',
      );
    }

    _currentRoute = bestRoute;
    _status = RoutingStatus.ready;
    notifyListeners();
    return _currentRoute;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns entry projections for the origin.  If the origin is inside
  /// [polygon], uses the polygon boundary; otherwise uses the nearest edge.
  List<EdgeProjection> _entryProjections(
    RoutingGraph graph,
    double lat,
    double lng,
    List<List<double>>? polygon,
  ) {
    if (polygon != null &&
        polygon.length >= 3 &&
        isInsidePolygon(lat, lng, polygon)) {
      return _boundaryProjections(graph, polygon);
    }

    final nearest = _nearestEdgeProjection(graph, lat, lng);
    return nearest == null ? [] : [nearest];
  }

  EdgeProjection? _nearestEdgeProjection(
    RoutingGraph graph,
    double lat,
    double lon,
  ) {
    if (graph.nodes.length < 2) return null;

    final processedEdges = <String>{};
    EdgeProjection? best;
    double bestDistance = double.infinity;

    for (final from in graph.nodes.values) {
      for (final edge in from.neighbors) {
        final to = graph.nodes[edge.toId];
        if (to == null) continue;

        final key = from.id.compareTo(to.id) < 0
            ? '${from.id}|${to.id}'
            : '${to.id}|${from.id}';
        if (!processedEdges.add(key)) continue;

        final p = projectPointOnSegment(
          originLat: lat,
          originLon: lon,
          aLat: from.lat,
          aLon: from.lon,
          bLat: to.lat,
          bLon: to.lon,
        );
        if (p == null || p.distanceMeters >= bestDistance) continue;

        bestDistance = p.distanceMeters;
        best = EdgeProjection(
          entryNodeId:
              '__entry_${from.id}_${to.id}_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}',
          entryLat: p.lat,
          entryLon: p.lon,
          fromNodeId: from.id,
          toNodeId: to.id,
          distanceToFromMeters:
              haversineMeters(p.lat, p.lon, from.lat, from.lon),
          distanceToToMeters:
              haversineMeters(p.lat, p.lon, to.lat, to.lon),
        );
      }
    }
    return best;
  }

  List<EdgeProjection> _boundaryProjections(
    RoutingGraph graph,
    List<List<double>> polygon,
  ) {
    if (graph.nodes.length < 2 || polygon.length < 3) return const [];

    final processedEdges = <String>{};
    final seenPoints = <String>{};
    final candidates = <EdgeProjection>[];

    for (final from in graph.nodes.values) {
      for (final edge in from.neighbors) {
        final to = graph.nodes[edge.toId];
        if (to == null) continue;

        final edgeKey = from.id.compareTo(to.id) < 0
            ? '${from.id}|${to.id}'
            : '${to.id}|${from.id}';
        if (!processedEdges.add(edgeKey)) continue;

        final refLat =
            (from.lat + to.lat) / 2; // close enough for the edge
        final a2 = projectPoint(from.lat, from.lon, refLat);
        final b2 = projectPoint(to.lat, to.lon, refLat);

        for (int j = 0; j < polygon.length; j++) {
          final p1Raw = polygon[j];
          final p2Raw = polygon[(j + 1) % polygon.length];
          if (p1Raw[0] == p2Raw[0] && p1Raw[1] == p2Raw[1]) continue;

          final p1 = projectPoint(p1Raw[1], p1Raw[0], refLat);
          final p2 = projectPoint(p2Raw[1], p2Raw[0], refLat);
          final t = segmentIntersectionT(a2, b2, p1, p2);
          if (t == null) continue;

          final lat = from.lat + (to.lat - from.lat) * t;
          final lon = from.lon + (to.lon - from.lon) * t;
          final pointKey =
              '${lat.toStringAsFixed(6)}|${lon.toStringAsFixed(6)}';
          if (!seenPoints.add(pointKey)) continue;

          candidates.add(EdgeProjection(
            entryNodeId:
                '__dest_${from.id}_${to.id}_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}',
            entryLat: lat,
            entryLon: lon,
            fromNodeId: from.id,
            toNodeId: to.id,
            distanceToFromMeters:
                haversineMeters(lat, lon, from.lat, from.lon),
            distanceToToMeters:
                haversineMeters(lat, lon, to.lat, to.lon),
          ));
        }
      }
    }
    return candidates;
  }

  // ── Polyline utilities ────────────────────────────────────────────────────

  List<RoutePoint> _buildPolyline(
    Map<String, GraphNode> graph,
    List<String> path,
    double originLat,
    double originLng,
  ) {
    return [
      RoutePoint(latitude: originLat, longitude: originLng),
      for (final id in path)
        if (graph[id] case final node?)
          RoutePoint(latitude: node.lat, longitude: node.lon),
    ];
  }

  List<RoutePoint> _trimPolylineAtPolygon(
    List<RoutePoint> polyline,
    List<List<double>> polygon,
  ) {
    final hit = _firstPolygonIntersection(polyline, polygon);
    if (hit == null) return polyline;

    final trimmed = polyline.sublist(0, hit.segmentIndex + 1);
    final last = trimmed.last;
    if ((last.latitude - hit.point.latitude).abs() > 1e-8 ||
        (last.longitude - hit.point.longitude).abs() > 1e-8) {
      trimmed.add(hit.point);
    }
    return trimmed;
  }

  _PolylineHit? _firstPolygonIntersection(
    List<RoutePoint> polyline,
    List<List<double>> polygon,
  ) {
    if (polyline.length < 2 || polygon.length < 3) return null;

    final refLat = _referenceLatitude(polyline, polygon);
    _PolylineHit? best;
    double bestDistance = double.infinity;
    double walked = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final segLen = haversineMeters(
        a.latitude, a.longitude, b.latitude, b.longitude,
      );
      if (segLen == 0) continue;

      final a2 = projectPoint(a.latitude, a.longitude, refLat);
      final b2 = projectPoint(b.latitude, b.longitude, refLat);

      for (int j = 0; j < polygon.length; j++) {
        final p1Raw = polygon[j];
        final p2Raw = polygon[(j + 1) % polygon.length];
        if (p1Raw[0] == p2Raw[0] && p1Raw[1] == p2Raw[1]) continue;

        final p1 = projectPoint(p1Raw[1], p1Raw[0], refLat);
        final p2 = projectPoint(p2Raw[1], p2Raw[0], refLat);
        final t = segmentIntersectionT(a2, b2, p1, p2);
        if (t == null) continue;

        final routeDist = walked + segLen * t;
        if (routeDist < bestDistance) {
          bestDistance = routeDist;
          best = _PolylineHit(
            segmentIndex: i,
            point: RoutePoint(
              latitude: a.latitude + (b.latitude - a.latitude) * t,
              longitude: a.longitude + (b.longitude - a.longitude) * t,
            ),
          );
        }
      }
      walked += segLen;
    }
    return best;
  }

  double _polylineDistance(List<RoutePoint> polyline) {
    double total = 0;
    for (int i = 0; i < polyline.length - 1; i++) {
      total += haversineMeters(
        polyline[i].latitude,
        polyline[i].longitude,
        polyline[i + 1].latitude,
        polyline[i + 1].longitude,
      );
    }
    return total;
  }

  double _referenceLatitude(
    List<RoutePoint> polyline,
    List<List<double>> polygon,
  ) {
    final lats = [
      ...polyline.map((p) => p.latitude),
      ...polygon.map((p) => p[1]),
    ];
    return lats.isEmpty ? 0 : lats.reduce((a, b) => a + b) / lats.length;
  }

  // ── Error helper ──────────────────────────────────────────────────────────

  Null _setError(String message) {
    _lastError = message;
    _status = RoutingStatus.error;
    _currentRoute = null;
    notifyListeners();
    debugPrint('❌ $message');
    return null;
  }
}

// ── Private helper types (file-local) ─────────────────────────────────────────

class _PolylineHit {
  final int segmentIndex;
  final RoutePoint point;

  const _PolylineHit({required this.segmentIndex, required this.point});
}