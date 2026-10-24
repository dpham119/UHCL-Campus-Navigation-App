/// A walkable path between two nodes.
class GraphEdge {
  final String from;
  final String to;

  /// Length of the path in meters.
  final double distanceMeters;

  /// False for paths with stairs, steep slopes, etc. Used later by the
  /// accessible-route option.
  final bool isAccessible;

  /// True for paths that are closed, under construction, or hazardous.
  /// Closed edges are never used in a route.
  final bool isClosed;

  const GraphEdge({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.isAccessible = true,
    this.isClosed = false,
  });

  @override
  String toString() => 'GraphEdge($from -> $to, ${distanceMeters}m)';
}
