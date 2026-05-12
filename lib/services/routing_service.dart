import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class RoutePoint {
  final double latitude;
  final double longitude;

  const RoutePoint({required this.latitude, required this.longitude});
}

class RouteResult {
  final List<String> nodePath;
  final List<RoutePoint> polyline;
  final double totalDistanceMeters;
  final Duration estimatedWalkTime;
  final int exploredNodes;
  final int computationTimeMs;
  final String originNodeId;
  final String destinationNodeId;

  const RouteResult({
    required this.nodePath,
    required this.polyline,
    required this.totalDistanceMeters,
    required this.estimatedWalkTime,
    required this.exploredNodes,
    required this.computationTimeMs,
    required this.originNodeId,
    required this.destinationNodeId,
  });
}

enum RoutingStatus { idle, loading, ready, error }

class RoutingService extends ChangeNotifier {
  static final RoutingService _instance = RoutingService._internal();
  factory RoutingService() => _instance;
  RoutingService._internal();

  final Map<String, _GraphNode> _nodes = {};
  bool _isLoaded = false;

  RoutingStatus _status = RoutingStatus.idle;
  String _lastError = '';
  RouteResult? _currentRoute;

  bool get isLoaded => _isLoaded;
  RoutingStatus get status => _status;
  String get lastError => _lastError;
  RouteResult? get currentRoute => _currentRoute;

  void clearCurrentRoute() {
    _currentRoute = null;
    _lastError = '';
    _status = _isLoaded ? RoutingStatus.ready : RoutingStatus.idle;
    notifyListeners();
  }

  String? nearestNodeId(double lat, double lon) => _nearestNodeId(lat, lon);

  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final raw = await rootBundle.loadString('assets/data/routing_graph.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final nodes = (json['nodes'] as Map<String, dynamic>?) ?? {};

      for (final entry in nodes.entries) {
        final id = entry.key;
        final data = entry.value as Map<String, dynamic>;
        final lat = (data['lat'] as num).toDouble();
        final lon = (data['lon'] as num).toDouble();
        final neighborsRaw = (data['neighbors'] as List<dynamic>? ?? const []);
        final neighbors = <_GraphEdge>[];

        for (final n in neighborsRaw) {
          final m = n as Map<String, dynamic>;
          neighbors.add(
            _GraphEdge(
              toId: m['id'].toString(),
              distanceMeters: (m['distance'] as num?)?.toDouble() ?? 0,
            ),
          );
        }

        _nodes[id] = _GraphNode(
          id: id,
          lat: lat,
          lon: lon,
          neighbors: neighbors,
        );
      }

      _isLoaded = true;
      notifyListeners();
      debugPrint('✅ Grafo cargado: ${_nodes.length} nodos');
    } catch (e) {
      _lastError = 'Error al cargar el grafo: $e';
      _status = RoutingStatus.error;
      notifyListeners();
      debugPrint('❌ $_lastError');
    }
  }

  Future<RouteResult?> buildRoute({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    List<List<double>>? originPolygon,
    List<List<double>>? destinationPolygon,
  }) async {
    if (!_isLoaded) {
      await load();
      if (!_isLoaded) return null;
    }

    _status = RoutingStatus.loading;
    _lastError = '';
    notifyListeners();

    final stopwatch = Stopwatch()..start();

    final originBoundaryProjections =
        originPolygon != null &&
            originPolygon.length >= 3 &&
            _isInsidePolygon(originLat, originLng, originPolygon)
        ? _destinationBoundaryProjections(originPolygon)
        : const <_EdgeProjection>[];

    final nearestEntryProjection = _nearestEdgeProjection(originLat, originLng);
    final entryCandidates = originBoundaryProjections.isNotEmpty
        ? originBoundaryProjections
        : nearestEntryProjection == null
        ? const <_EdgeProjection>[]
        : <_EdgeProjection>[nearestEntryProjection];
    final destinationId = _nearestNodeId(destinationLat, destinationLng);

    if (entryCandidates.isEmpty || destinationId == null) {
      _status = RoutingStatus.error;
      _lastError =
          'No fue posible ubicar una arista de entrada o nodos cercanos para el destino.';
      _currentRoute = null;
      notifyListeners();
      return null;
    }

    final destinationProjections =
        destinationPolygon != null && destinationPolygon.length >= 3
        ? _destinationBoundaryProjections(destinationPolygon)
        : const <_EdgeProjection>[];

    RouteResult? bestRoute;
    double bestDistance = double.infinity;

    for (final entry in entryCandidates) {
      final workingNodes = _cloneGraphWithEntryNode(entry);

      if (destinationProjections.isNotEmpty) {
        for (final projection in destinationProjections) {
          final candidateGraph = _cloneGraphWithVirtualNode(
            workingNodes,
            projection,
          );
          final candidateSearch = _aStar(
            candidateGraph,
            entry.entryNodeId,
            projection.entryNodeId,
          );
          if (candidateSearch == null || candidateSearch.path.isEmpty) {
            continue;
          }

          final candidatePolyline = _buildPolylineFromPath(
            candidateGraph,
            candidateSearch.path,
            originLat,
            originLng,
          );
          final candidateDistance = _computePolylineDistance(candidatePolyline);

          if (candidateDistance < bestDistance) {
            bestDistance = candidateDistance;
            bestRoute = RouteResult(
              nodePath: candidateSearch.path,
              polyline: candidatePolyline,
              totalDistanceMeters: candidateDistance,
              estimatedWalkTime: Duration(
                seconds: (candidateDistance / 1.35).round(),
              ),
              exploredNodes: candidateSearch.exploredNodes,
              computationTimeMs: stopwatch.elapsedMilliseconds,
              originNodeId: entry.entryNodeId,
              destinationNodeId: projection.entryNodeId,
            );
          }
        }
      }

      if (destinationProjections.isEmpty) {
        final search = _aStar(workingNodes, entry.entryNodeId, destinationId);
        if (search == null || search.path.isEmpty) {
          continue;
        }

        final polyline = _buildPolylineFromPath(
          workingNodes,
          search.path,
          originLat,
          originLng,
        );

        final trimmedPolyline =
            destinationPolygon != null && destinationPolygon.length >= 3
            ? _trimPolylineAtPolygon(polyline, destinationPolygon)
            : polyline;

        final totalDistance = _computePolylineDistance(trimmedPolyline);
        if (totalDistance < bestDistance) {
          bestDistance = totalDistance;
          bestRoute = RouteResult(
            nodePath: search.path,
            polyline: trimmedPolyline,
            totalDistanceMeters: totalDistance,
            estimatedWalkTime: Duration(
              seconds: (totalDistance / 1.35).round(),
            ),
            exploredNodes: search.exploredNodes,
            computationTimeMs: stopwatch.elapsedMilliseconds,
            originNodeId: entry.entryNodeId,
            destinationNodeId: destinationId,
          );
        }
      }
    }

    if (bestRoute == null) {
      _status = RoutingStatus.error;
      _lastError =
          'No existe una ruta peatonal conectada entre origen y destino.';
      _currentRoute = null;
      notifyListeners();
      return null;
    }

    stopwatch.stop();

    _currentRoute = bestRoute;
    _status = RoutingStatus.ready;
    notifyListeners();
    return _currentRoute;
  }

  String? _nearestNodeId(double lat, double lon) {
    if (_nodes.isEmpty) return null;
    String? bestId;
    double bestDistance = double.infinity;

    for (final node in _nodes.values) {
      final d = _haversineMeters(lat, lon, node.lat, node.lon);
      if (d < bestDistance) {
        bestDistance = d;
        bestId = node.id;
      }
    }
    return bestId;
  }

  _EdgeProjection? _nearestEdgeProjection(double lat, double lon) {
    if (_nodes.length < 2) return null;

    final processedEdges = <String>{};
    _EdgeProjection? best;
    double bestDistance = double.infinity;

    for (final from in _nodes.values) {
      for (final edge in from.neighbors) {
        final to = _nodes[edge.toId];
        if (to == null) continue;

        final key = from.id.compareTo(to.id) < 0
            ? '${from.id}|${to.id}'
            : '${to.id}|${from.id}';
        if (!processedEdges.add(key)) continue;

        final projection = _projectPointOnSegment(
          originLat: lat,
          originLon: lon,
          aLat: from.lat,
          aLon: from.lon,
          bLat: to.lat,
          bLon: to.lon,
        );
        if (projection == null) continue;

        if (projection.distanceMeters < bestDistance) {
          bestDistance = projection.distanceMeters;
          best = _EdgeProjection(
            entryNodeId:
                '__entry_${from.id}_${to.id}_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}',
            entryLat: projection.lat,
            entryLon: projection.lon,
            fromNodeId: from.id,
            toNodeId: to.id,
            distanceToFromMeters: _haversineMeters(
              projection.lat,
              projection.lon,
              from.lat,
              from.lon,
            ),
            distanceToToMeters: _haversineMeters(
              projection.lat,
              projection.lon,
              to.lat,
              to.lon,
            ),
          );
        }
      }
    }

    return best;
  }

  List<_EdgeProjection> _destinationBoundaryProjections(
    List<List<double>> polygon,
  ) {
    if (_nodes.length < 2 || polygon.length < 3) return const [];

    final processedEdges = <String>{};
    final seenPoints = <String>{};
    final candidates = <_EdgeProjection>[];

    for (final from in _nodes.values) {
      for (final edge in from.neighbors) {
        final to = _nodes[edge.toId];
        if (to == null) continue;

        final edgeKey = from.id.compareTo(to.id) < 0
            ? '${from.id}|${to.id}'
            : '${to.id}|${from.id}';
        if (!processedEdges.add(edgeKey)) continue;

        for (int j = 0; j < polygon.length; j++) {
          final p1Raw = polygon[j];
          final p2Raw = polygon[(j + 1) % polygon.length];
          if (p1Raw[0] == p2Raw[0] && p1Raw[1] == p2Raw[1]) {
            continue;
          }

          final refLat = (from.lat + to.lat + p1Raw[1] + p2Raw[1]) / 4.0;
          final a2 = _projectPoint(from.lat, from.lon, refLat);
          final b2 = _projectPoint(to.lat, to.lon, refLat);
          final p1 = _projectPoint(p1Raw[1], p1Raw[0], refLat);
          final p2 = _projectPoint(p2Raw[1], p2Raw[0], refLat);
          final t = _segmentIntersectionT(a2, b2, p1, p2);
          if (t == null) continue;

          final lat = from.lat + (to.lat - from.lat) * t;
          final lon = from.lon + (to.lon - from.lon) * t;
          final pointKey =
              '${lat.toStringAsFixed(6)}|${lon.toStringAsFixed(6)}';
          if (!seenPoints.add(pointKey)) continue;

          candidates.add(
            _EdgeProjection(
              entryNodeId:
                  '__dest_${from.id}_${to.id}_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}',
              entryLat: lat,
              entryLon: lon,
              fromNodeId: from.id,
              toNodeId: to.id,
              distanceToFromMeters: _haversineMeters(
                lat,
                lon,
                from.lat,
                from.lon,
              ),
              distanceToToMeters: _haversineMeters(lat, lon, to.lat, to.lon),
            ),
          );
        }
      }
    }

    return candidates;
  }

  bool _isInsidePolygon(double lat, double lon, List<List<double>> polygon) {
    bool inside = false;
    int j = polygon.length - 1;

    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i][0];
      final yi = polygon[i][1];
      final xj = polygon[j][0];
      final yj = polygon[j][1];

      final intersects =
          ((yi > lat) != (yj > lat)) &&
          (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi);
      if (intersects) {
        inside = !inside;
      }
      j = i;
    }

    return inside;
  }

  Map<String, _GraphNode> _cloneGraphWithEntryNode(_EdgeProjection entry) {
    return _cloneGraphWithVirtualNode(_nodes, entry);
  }

  Map<String, _GraphNode> _cloneGraphWithVirtualNode(
    Map<String, _GraphNode> source,
    _EdgeProjection projection,
  ) {
    final graph = <String, _GraphNode>{};

    for (final node in source.values) {
      graph[node.id] = _GraphNode(
        id: node.id,
        lat: node.lat,
        lon: node.lon,
        neighbors: List<_GraphEdge>.from(node.neighbors),
      );
    }

    graph[projection.fromNodeId] = graph[projection.fromNodeId]!.copyWith(
      neighbors: [
        ...graph[projection.fromNodeId]!.neighbors,
        _GraphEdge(
          toId: projection.entryNodeId,
          distanceMeters: projection.distanceToFromMeters,
        ),
      ],
    );
    graph[projection.toNodeId] = graph[projection.toNodeId]!.copyWith(
      neighbors: [
        ...graph[projection.toNodeId]!.neighbors,
        _GraphEdge(
          toId: projection.entryNodeId,
          distanceMeters: projection.distanceToToMeters,
        ),
      ],
    );
    graph[projection.entryNodeId] = _GraphNode(
      id: projection.entryNodeId,
      lat: projection.entryLat,
      lon: projection.entryLon,
      neighbors: [
        _GraphEdge(
          toId: projection.fromNodeId,
          distanceMeters: projection.distanceToFromMeters,
        ),
        _GraphEdge(
          toId: projection.toNodeId,
          distanceMeters: projection.distanceToToMeters,
        ),
      ],
    );

    return graph;
  }

  List<RoutePoint> _buildPolylineFromPath(
    Map<String, _GraphNode> graph,
    List<String> path,
    double originLat,
    double originLng,
  ) {
    final polyline = <RoutePoint>[
      RoutePoint(latitude: originLat, longitude: originLng),
    ];

    for (final nodeId in path) {
      final node = graph[nodeId];
      if (node != null) {
        polyline.add(RoutePoint(latitude: node.lat, longitude: node.lon));
      }
    }

    return polyline;
  }

  _SearchResult? _aStar(
    Map<String, _GraphNode> graph,
    String startId,
    String goalId,
  ) {
    if (!graph.containsKey(startId) || !graph.containsKey(goalId)) {
      return null;
    }

    final open = <_OpenNode>[
      _OpenNode(id: startId, fScore: _heuristic(graph, startId, goalId)),
    ];
    final cameFrom = <String, String>{};
    final gScore = <String, double>{startId: 0.0};
    final closed = <String>{};

    int explored = 0;

    while (open.isNotEmpty) {
      final current = _popLowestF(open);
      if (closed.contains(current.id)) continue;
      explored++;

      if (current.id == goalId) {
        final path = _reconstructPath(cameFrom, current.id);
        if (!_isPathConnected(graph, path)) return null;
        return _SearchResult(path: path, exploredNodes: explored);
      }

      closed.add(current.id);
      final currentNode = graph[current.id]!;

      for (final edge in currentNode.neighbors) {
        if (!graph.containsKey(edge.toId) || closed.contains(edge.toId)) {
          continue;
        }

        final edgeDistance = edge.distanceMeters > 0
            ? edge.distanceMeters
            : _heuristic(graph, current.id, edge.toId);

        final tentativeG =
            (gScore[current.id] ?? double.infinity) + edgeDistance;
        final neighborG = gScore[edge.toId] ?? double.infinity;

        if (tentativeG < neighborG) {
          cameFrom[edge.toId] = current.id;
          gScore[edge.toId] = tentativeG;
          final f = tentativeG + _heuristic(graph, edge.toId, goalId);
          open.add(_OpenNode(id: edge.toId, fScore: f));
        }
      }
    }

    return null;
  }

  _OpenNode _popLowestF(List<_OpenNode> open) {
    int bestIndex = 0;
    for (int i = 1; i < open.length; i++) {
      if (open[i].fScore < open[bestIndex].fScore) {
        bestIndex = i;
      }
    }
    final value = open[bestIndex];
    open.removeAt(bestIndex);
    return value;
  }

  List<String> _reconstructPath(Map<String, String> cameFrom, String current) {
    final path = <String>[current];
    while (cameFrom.containsKey(current)) {
      current = cameFrom[current]!;
      path.add(current);
    }
    return path.reversed.toList();
  }

  bool _isPathConnected(Map<String, _GraphNode> graph, List<String> path) {
    if (path.length <= 1) return true;
    for (int i = 0; i < path.length - 1; i++) {
      final from = graph[path[i]];
      if (from == null) return false;
      final hasEdge = from.neighbors.any((e) => e.toId == path[i + 1]);
      if (!hasEdge) return false;
    }
    return true;
  }

  List<RoutePoint> _trimPolylineAtPolygon(
    List<RoutePoint> polyline,
    List<List<double>> polygon,
  ) {
    final hit = _findFirstPolygonIntersection(polyline, polygon);
    if (hit == null) return polyline;

    final trimmed = <RoutePoint>[];
    for (int i = 0; i <= hit.segmentIndex; i++) {
      trimmed.add(polyline[i]);
    }

    final last = trimmed.isNotEmpty ? trimmed.last : null;
    if (last == null || !_samePoint(last, hit.point)) {
      trimmed.add(hit.point);
    }

    return trimmed;
  }

  _PolylineHit? _findFirstPolygonIntersection(
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
      final segmentLength = _haversineMeters(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      if (segmentLength == 0) {
        continue;
      }

      final a2 = _projectPoint(a.latitude, a.longitude, refLat);
      final b2 = _projectPoint(b.latitude, b.longitude, refLat);

      for (int j = 0; j < polygon.length; j++) {
        final p1Raw = polygon[j];
        final p2Raw = polygon[(j + 1) % polygon.length];
        if (p1Raw[0] == p2Raw[0] && p1Raw[1] == p2Raw[1]) {
          continue;
        }

        final p1 = _projectPoint(p1Raw[1], p1Raw[0], refLat);
        final p2 = _projectPoint(p2Raw[1], p2Raw[0], refLat);
        final t = _segmentIntersectionT(a2, b2, p1, p2);
        if (t == null) continue;

        final routeDistance = walked + (segmentLength * t);
        if (routeDistance < bestDistance) {
          bestDistance = routeDistance;
          best = _PolylineHit(
            segmentIndex: i,
            point: RoutePoint(
              latitude: a.latitude + (b.latitude - a.latitude) * t,
              longitude: a.longitude + (b.longitude - a.longitude) * t,
            ),
            distanceAlongRoute: routeDistance,
          );
        }
      }

      walked += segmentLength;
    }

    return best;
  }

  double _computePolylineDistance(List<RoutePoint> polyline) {
    if (polyline.length <= 1) return 0;
    double total = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      total += _haversineMeters(
        polyline[i].latitude,
        polyline[i].longitude,
        polyline[i + 1].latitude,
        polyline[i + 1].longitude,
      );
    }

    return total;
  }

  String _virtualDestinationNodeId(RoutePoint point) {
    return '__dest_${point.latitude.toStringAsFixed(5)}_${point.longitude.toStringAsFixed(5)}';
  }

  double _referenceLatitude(
    List<RoutePoint> polyline,
    List<List<double>> polygon,
  ) {
    var total = 0.0;
    var count = 0;

    for (final point in polyline) {
      total += point.latitude;
      count++;
    }

    for (final point in polygon) {
      total += point[1];
      count++;
    }

    return count == 0 ? 0 : total / count;
  }

  _ProjectedPoint _projectPoint(double lat, double lon, double refLat) {
    const metersPerDegreeLat = 111320.0;
    final metersPerDegreeLng = metersPerDegreeLat * cos(_toRad(refLat));
    return _ProjectedPoint(
      x: lon * metersPerDegreeLng,
      y: lat * metersPerDegreeLat,
    );
  }

  double? _segmentIntersectionT(
    _ProjectedPoint a,
    _ProjectedPoint b,
    _ProjectedPoint c,
    _ProjectedPoint d,
  ) {
    final denom = (a.x - b.x) * (c.y - d.y) - (a.y - b.y) * (c.x - d.x);
    if (denom.abs() < 1e-12) return null;

    final t = ((a.x - c.x) * (c.y - d.y) - (a.y - c.y) * (c.x - d.x)) / denom;
    final u = ((a.x - c.x) * (a.y - b.y) - (a.y - c.y) * (a.x - b.x)) / denom;

    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return t;
  }

  bool _samePoint(RoutePoint a, RoutePoint b) {
    return (a.latitude - b.latitude).abs() < 1e-8 &&
        (a.longitude - b.longitude).abs() < 1e-8;
  }

  double _heuristic(Map<String, _GraphNode> graph, String fromId, String toId) {
    final from = graph[fromId]!;
    final to = graph[toId]!;
    return _haversineMeters(from.lat, from.lon, to.lat, to.lon);
  }

  _ProjectionPoint? _projectPointOnSegment({
    required double originLat,
    required double originLon,
    required double aLat,
    required double aLon,
    required double bLat,
    required double bLon,
  }) {
    const metersPerDegreeLat = 111320.0;
    final refLat = (aLat + bLat + originLat) / 3;
    final metersPerDegreeLng = metersPerDegreeLat * cos(_toRad(refLat));

    final ax = aLon * metersPerDegreeLng;
    final ay = aLat * metersPerDegreeLat;
    final bx = bLon * metersPerDegreeLng;
    final by = bLat * metersPerDegreeLat;
    final px = originLon * metersPerDegreeLng;
    final py = originLat * metersPerDegreeLat;

    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final ab2 = abx * abx + aby * aby;
    if (ab2 == 0) return null;

    final t = ((apx * abx) + (apy * aby)) / ab2;
    final clamped = t.clamp(0.0, 1.0);
    final cx = ax + abx * clamped;
    final cy = ay + aby * clamped;
    final lat = cy / metersPerDegreeLat;
    final lon = cx / metersPerDegreeLng;

    return _ProjectionPoint(
      lat: lat,
      lon: lon,
      distanceMeters: _haversineMeters(originLat, originLon, lat, lon),
    );
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
}

class _GraphNode {
  final String id;
  final double lat;
  final double lon;
  final List<_GraphEdge> neighbors;

  const _GraphNode({
    required this.id,
    required this.lat,
    required this.lon,
    required this.neighbors,
  });

  _GraphNode copyWith({List<_GraphEdge>? neighbors}) {
    return _GraphNode(
      id: id,
      lat: lat,
      lon: lon,
      neighbors: neighbors ?? this.neighbors,
    );
  }
}

class _GraphEdge {
  final String toId;
  final double distanceMeters;

  const _GraphEdge({required this.toId, required this.distanceMeters});
}

class _OpenNode {
  final String id;
  final double fScore;

  const _OpenNode({required this.id, required this.fScore});
}

class _SearchResult {
  final List<String> path;
  final int exploredNodes;

  const _SearchResult({required this.path, required this.exploredNodes});
}

class _EdgeProjection {
  final String entryNodeId;
  final double entryLat;
  final double entryLon;
  final String fromNodeId;
  final String toNodeId;
  final double distanceToFromMeters;
  final double distanceToToMeters;

  const _EdgeProjection({
    required this.entryNodeId,
    required this.entryLat,
    required this.entryLon,
    required this.fromNodeId,
    required this.toNodeId,
    required this.distanceToFromMeters,
    required this.distanceToToMeters,
  });
}

class _ProjectionPoint {
  final double lat;
  final double lon;
  final double distanceMeters;

  const _ProjectionPoint({
    required this.lat,
    required this.lon,
    required this.distanceMeters,
  });
}

class _ProjectedPoint {
  final double x;
  final double y;

  const _ProjectedPoint({required this.x, required this.y});
}

class _PolylineHit {
  final int segmentIndex;
  final RoutePoint point;
  final double distanceAlongRoute;

  const _PolylineHit({
    required this.segmentIndex,
    required this.point,
    required this.distanceAlongRoute,
  });
}
