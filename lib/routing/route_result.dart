import 'graph_node.dart';

/// A calculated walking route.
class RouteResult {
  /// Nodes in order from the start to the destination.
  final List<GraphNode> path;
  final double distanceMeters;
  final Duration walkingTime;

  const RouteResult({
    required this.path,
    required this.distanceMeters,
    required this.walkingTime,
  });

  GraphNode get start => path.first;
  GraphNode get destination => path.last;
}

enum RouteError {
  emptyGraph,
  unknownStart,
  unknownDestination,
  noPathFound,
}

/// Thrown when a route cannot be generated. Show [message] to the user.
class RouteException implements Exception {
  final RouteError error;
  final String message;

  const RouteException(this.error, this.message);

  @override
  String toString() => 'RouteException(${error.name}): $message';
}
