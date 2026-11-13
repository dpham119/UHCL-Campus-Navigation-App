import 'campus_graph.dart';
import 'graph_edge.dart';
import 'graph_node.dart';
import 'min_priority_queue.dart';
import 'route_result.dart';

/// Calculates shortest walking routes over a [CampusGraph] using
/// Dijkstra's algorithm.
class RouteGenerator {
  final CampusGraph graph;

  /// Average walking speed used for the time estimate (about 5 km/h).
  final double walkingSpeedMetersPerSecond;

  RouteGenerator(this.graph, {this.walkingSpeedMetersPerSecond = 1.4});

  /// Edge filter for accessible routes. Pass it as `edgeFilter` to
  /// [generate].
  ///
  /// An edge is allowed only if it is marked accessible AND neither end
  /// is a stairs node. The second check matters because stair nodes also
  /// have flat accessible edges to the corridor, so `edge.isAccessible`
  /// alone would still let a route walk through a stairwell. Elevator
  /// nodes and their floor-to-floor edges stay available, and outdoor
  /// edges are unaffected.
  bool Function(GraphEdge edge) get accessibleEdgeFilter => (edge) {
    if (!edge.isAccessible) return false;
    return graph.nodeById(edge.from)?.kind != NodeKind.stairs &&
        graph.nodeById(edge.to)?.kind != NodeKind.stairs;
  };

  /// The edge filter for a route request.
  ///
  /// With [accessibleOnly] it is [accessibleEdgeFilter]; otherwise there is
  /// no restriction beyond [avoidInteriorOf]. Every building named in
  /// [avoidInteriorOf] is kept to its entrances: edges to its corridors,
  /// rooms, stairs or elevators are not used. That is how a route whose
  /// start or end is a whole building (not a room) stops at the door
  /// instead of walking through the hallways to a different door.
  /// Returns null when nothing needs filtering.
  bool Function(GraphEdge edge)? routeFilter({
    required bool accessibleOnly,
    Set<String> avoidInteriorOf = const {},
  }) {
    if (!accessibleOnly && avoidInteriorOf.isEmpty) return null;

    final base = accessibleOnly ? accessibleEdgeFilter : null;
    bool isInterior(String id) {
      final node = graph.nodeById(id);
      return node != null &&
          node.floor > 0 &&
          node.kind != NodeKind.entrance &&
          avoidInteriorOf.contains(node.building);
    }

    return (edge) {
      if (base != null && !base(edge)) return false;
      if (avoidInteriorOf.isEmpty) return true;
      return !isInterior(edge.from) && !isInterior(edge.to);
    };
  }

  /// Finds the shortest route from [startId] to [destinationId].
  ///
  /// Closed edges are never used. [edgeFilter] can exclude more edges,
  /// for example [accessibleEdgeFilter] for an accessible route.
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
