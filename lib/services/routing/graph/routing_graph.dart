import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';

import '../routing/geometry.dart';
import 'graph_node.dart';

/// Loads the routing graph from assets and exposes a weighted A* search.
///
/// Note: the `graphs` package (pub.dev/packages/graphs) only supports
/// *unweighted* shortest paths — its [shortestPath] has no `cost` parameter.
/// Because pedestrian routing requires real edge distances, A* is implemented
/// here directly using a priority queue.
class RoutingGraph {
  final Map<String, GraphNode> nodes;

  const RoutingGraph(this.nodes);

  static Future<RoutingGraph> fromAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final nodesJson = (json['nodes'] as Map<String, dynamic>?) ?? {};

    final nodes = <String, GraphNode>{};
    for (final entry in nodesJson.entries) {
      final data = entry.value as Map<String, dynamic>;
      final neighborsRaw = data['neighbors'] as List<dynamic>? ?? const [];

      nodes[entry.key] = GraphNode(
        id: entry.key,
        lat: (data['lat'] as num).toDouble(),
        lon: (data['lon'] as num).toDouble(),
        neighbors: [
          for (final n in neighborsRaw)
            GraphEdge(
              toId: (n as Map<String, dynamic>)['id'].toString(),
              distanceMeters: (n['distance'] as num?)?.toDouble() ?? 0,
            ),
        ],
      );
    }

    return RoutingGraph(nodes);
  }

  // ── Nearest-node helpers ──────────────────────────────────────────────────

  String? nearestNodeId(double lat, double lon) {
    if (nodes.isEmpty) return null;
    return nodes.values
        .reduce(
          (a, b) =>
              haversineMeters(lat, lon, a.lat, a.lon) <=
                      haversineMeters(lat, lon, b.lat, b.lon)
                  ? a
                  : b,
        )
        .id;
  }

  // ── Virtual-node graph manipulation ──────────────────────────────────────

  /// Returns a shallow copy of [source] (or [nodes] when null) with
  /// [projection] spliced in as a new virtual node.
  Map<String, GraphNode> withVirtualNode(
    EdgeProjection projection, [
    Map<String, GraphNode>? source,
  ]) {
    final graph = {
      for (final n in (source ?? nodes).values) n.id: n.copyWith(),
    };

    void addEdgeTo(String nodeId, String targetId, double dist) {
      final node = graph[nodeId]!;
      if (node.neighbors.any((e) => e.toId == targetId)) return;
      graph[nodeId] = node.copyWith(
        neighbors: [...node.neighbors, GraphEdge(toId: targetId, distanceMeters: dist)],
      );
    }

    addEdgeTo(
      projection.fromNodeId,
      projection.entryNodeId,
      projection.distanceToFromMeters,
    );
    addEdgeTo(
      projection.toNodeId,
      projection.entryNodeId,
      projection.distanceToToMeters,
    );

    graph[projection.entryNodeId] = GraphNode(
      id: projection.entryNodeId,
      lat: projection.entryLat,
      lon: projection.entryLon,
      neighbors: [
        GraphEdge(
          toId: projection.fromNodeId,
          distanceMeters: projection.distanceToFromMeters,
        ),
        GraphEdge(
          toId: projection.toNodeId,
          distanceMeters: projection.distanceToToMeters,
        ),
      ],
    );

    return graph;
  }

  // ── Weighted A* search ────────────────────────────────────────────────────

  /// Returns the node-id path from [startId] to [goalId], or null when
  /// no connected path exists.
  ///
  /// [graph] defaults to [nodes]; pass a modified copy when virtual nodes
  /// are involved.
  List<String>? findPath(
    String startId,
    String goalId, {
    Map<String, GraphNode>? graph,
  }) {
    final g = graph ?? nodes;
    if (!g.containsKey(startId) || !g.containsKey(goalId)) return null;

    // Min-heap keyed on fScore = gScore + heuristic.
    final open = PriorityQueue<_AStarNode>(
      (a, b) => a.fScore.compareTo(b.fScore),
    );
    open.add(_AStarNode(
      id: startId,
      fScore: _heuristic(g, startId, goalId),
    ));

    final cameFrom = <String, String>{};
    final gScore = <String, double>{startId: 0.0};
    final closed = <String>{};

    while (open.isNotEmpty) {
      final current = open.removeFirst();
      if (closed.contains(current.id)) continue;
      if (current.id == goalId) return _reconstructPath(cameFrom, goalId);

      closed.add(current.id);
      final currentNode = g[current.id]!;

      for (final edge in currentNode.neighbors) {
        if (!g.containsKey(edge.toId) || closed.contains(edge.toId)) continue;

        final edgeCost = edge.distanceMeters > 0
            ? edge.distanceMeters
            : _heuristic(g, current.id, edge.toId);

        final tentativeG = (gScore[current.id] ?? double.infinity) + edgeCost;
        if (tentativeG >= (gScore[edge.toId] ?? double.infinity)) continue;

        cameFrom[edge.toId] = current.id;
        gScore[edge.toId] = tentativeG;
        open.add(_AStarNode(
          id: edge.toId,
          fScore: tentativeG + _heuristic(g, edge.toId, goalId),
        ));
      }
    }
    return null; // no path found
  }

  double _heuristic(Map<String, GraphNode> g, String a, String b) =>
      haversineMeters(g[a]!.lat, g[a]!.lon, g[b]!.lat, g[b]!.lon);

  List<String> _reconstructPath(Map<String, String> cameFrom, String current) {
    final path = <String>[current];
    while (cameFrom.containsKey(current)) {
      current = cameFrom[current]!;
      path.add(current);
    }
    return path.reversed.toList();
  }
}

// ── Priority-queue node (file-local) ─────────────────────────────────────────

class _AStarNode implements Comparable<_AStarNode> {
  final String id;
  final double fScore;

  const _AStarNode({required this.id, required this.fScore});

  @override
  int compareTo(_AStarNode other) => fScore.compareTo(other.fScore);
}