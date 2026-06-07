class GraphNode {
  final String id;
  final double lat;
  final double lon;
  final List<GraphEdge> neighbors;

  const GraphNode({
    required this.id,
    required this.lat,
    required this.lon,
    required this.neighbors,
  });

  GraphNode copyWith({List<GraphEdge>? neighbors}) => GraphNode(
        id: id,
        lat: lat,
        lon: lon,
        neighbors: neighbors ?? this.neighbors,
      );
}

class GraphEdge {
  final String toId;
  final double distanceMeters;

  const GraphEdge({required this.toId, required this.distanceMeters});
}

/// A virtual node that sits on an edge, used to inject origin/destination
/// points that don't coincide with a real graph node.
class EdgeProjection {
  final String entryNodeId;
  final double entryLat;
  final double entryLon;
  final String fromNodeId;
  final String toNodeId;
  final double distanceToFromMeters;
  final double distanceToToMeters;

  const EdgeProjection({
    required this.entryNodeId,
    required this.entryLat,
    required this.entryLon,
    required this.fromNodeId,
    required this.toNodeId,
    required this.distanceToFromMeters,
    required this.distanceToToMeters,
  });
}