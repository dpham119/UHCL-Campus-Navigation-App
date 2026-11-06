import 'campus_graph.dart';
import 'distance.dart';
import 'graph_node.dart';

/// The graph node closest to a point, and how far away it is.
class NearestNode {
  final GraphNode node;
  final double distanceMeters;

  const NearestNode(this.node, this.distanceMeters);
}

extension NearestNodeLookup on CampusGraph {
  /// Finds the node closest to [latitude]/[longitude] (for example a
  /// building's center or the user's GPS position). Only nodes accepted
  /// by [where] are considered, if it is given. With [byAnchor], a room node
  /// is measured from its room's center instead of from its door. Returns null if there is
  /// no matching node.
  NearestNode? nearestNode(
    double latitude,
    double longitude, {
    bool Function(GraphNode node)? where,
    bool byAnchor = false,
  }) {
    NearestNode? best;
    for (final node in nodes) {
      if (where != null && !where(node)) continue;
      final d = haversineMeters(
        latitude,
        longitude,
        byAnchor ? (node.anchorLatitude ?? node.latitude) : node.latitude,
        byAnchor ? (node.anchorLongitude ?? node.longitude) : node.longitude,
      );
      if (best == null || d < best.distanceMeters) {
        best = NearestNode(node, d);
      }
    }
    return best;
  }
}
