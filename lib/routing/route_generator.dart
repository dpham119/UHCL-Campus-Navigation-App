import 'campus_graph.dart';
import 'graph_edge.dart';
import 'min_priority_queue.dart';
import 'route_result.dart';

/// Calculates shortest walking routes over a [CampusGraph] using
/// Dijkstra's algorithm.
class RouteGenerator {
  final CampusGraph graph;

  /// Average walking speed used for the time estimate (about 5 km/h).
  final double walkingSpeedMetersPerSecond;

  RouteGenerator(this.graph, {this.walkingSpeedMetersPerSecond = 1.4});

  /// Finds the shortest route from [startId] to [destinationId].
  ///
  /// Closed edges are never used. [edgeFilter] can exclude more edges,
  /// for example `(edge) => edge.isAccessible` for an accessible route.
  ///
  /// Throws [RouteException] if no route can be generated.
  RouteResult generate(
    String startId,
    String destinationId, {
    bool Function(GraphEdge edge)? edgeFilter,
  }) {
    if (graph.isEmpty) {
      throw const RouteException(
        RouteError.emptyGraph,
        'Campus map data is not available.',
      );
    }
    if (!graph.containsNode(startId)) {
      throw const RouteException(
        RouteError.unknownStart,
        'The starting location could not be found.',
      );
    }
    if (!graph.containsNode(destinationId)) {
      throw const RouteException(
        RouteError.unknownDestination,
        'The destination could not be found.',
      );
    }

    final distances = <String, double>{startId: 0.0};
    final previous = <String, String>{};
    final finished = <String>{};
    final queue = MinPriorityQueue()..add(startId, 0.0);

    while (!queue.isEmpty) {
      final current = queue.removeFirst();
      if (!finished.add(current.nodeId)) continue; // stale queue entry
      if (current.nodeId == destinationId) break;

      for (final edge in graph.edgesFrom(current.nodeId)) {
        if (edge.isClosed) continue;
        if (edgeFilter != null && !edgeFilter(edge)) continue;
        if (finished.contains(edge.to)) continue;

        final candidate = current.priority + edge.distanceMeters;
        final known = distances[edge.to];
        if (known == null || candidate < known) {
          distances[edge.to] = candidate;
          previous[edge.to] = current.nodeId;
          queue.add(edge.to, candidate);
        }
      }
    }

    final totalMeters = distances[destinationId];
    if (totalMeters == null) {
      throw const RouteException(
        RouteError.noPathFound,
        'No walking route is available between these locations.',
      );
    }

    // Walk backwards from the destination to rebuild the path.
    final ids = <String>[destinationId];
    while (ids.first != startId) {
      ids.insert(0, previous[ids.first]!);
    }
    final path = ids.map((id) => graph.nodeById(id)!).toList();

    final seconds = totalMeters / walkingSpeedMetersPerSecond;
    return RouteResult(
      path: path,
      distanceMeters: totalMeters,
      walkingTime: Duration(milliseconds: (seconds * 1000).round()),
    );
  }
}
