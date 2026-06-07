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