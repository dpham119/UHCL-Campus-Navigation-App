import 'distance.dart';
import 'graph_edge.dart';
import 'graph_node.dart';

/// The campus walking network: nodes (intersections, entrances) connected
/// by edges (walkable paths).
class CampusGraph {
  final Map<String, GraphNode> _nodes = {};
  final Map<String, List<GraphEdge>> _edges = {};

  bool get isEmpty => _nodes.isEmpty;
  int get nodeCount => _nodes.length;
  Iterable<GraphNode> get nodes => _nodes.values;

  bool containsNode(String id) => _nodes.containsKey(id);
  GraphNode? nodeById(String id) => _nodes[id];

  void addNode(GraphNode node) {
    _nodes[node.id] = node;
    _edges.putIfAbsent(node.id, () => <GraphEdge>[]);
  }

  /// Adds a path between two existing nodes. If [distanceMeters] is not
  /// given, it is computed from the nodes' coordinates. Paths are
  /// two-way unless [bidirectional] is false.
  void addEdge(
    String fromId,
    String toId, {
    double? distanceMeters,
    bool bidirectional = true,
    bool isAccessible = true,
    bool isClosed = false,
  }) {
    final from = _nodes[fromId];
    final to = _nodes[toId];
    if (from == null || to == null) {
      throw ArgumentError('Both nodes must be added before the edge: '
          '$fromId -> $toId');
    }
    final distance = distanceMeters ??
        haversineMeters(
          from.latitude,
          from.longitude,
          to.latitude,
          to.longitude,
        );
    _edges[fromId]!.add(GraphEdge(
      from: fromId,
      to: toId,
      distanceMeters: distance,
      isAccessible: isAccessible,
      isClosed: isClosed,
    ));
    if (bidirectional) {
      _edges[toId]!.add(GraphEdge(
        from: toId,
        to: fromId,
        distanceMeters: distance,
        isAccessible: isAccessible,
        isClosed: isClosed,
      ));
    }
  }

  /// Edges that leave [nodeId]. Empty if the node is unknown.
  List<GraphEdge> edgesFrom(String nodeId) =>
      _edges[nodeId] ?? const <GraphEdge>[];
}
