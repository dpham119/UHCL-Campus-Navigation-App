/// A point on the campus walking network: an intersection, building
/// entrance, or other destination.
class GraphNode {
  final String id;
  final String name;
  final double latitude;
  final double longitude;

  /// True if users can pick this node as a destination (e.g. a building
  /// entrance). Plain intersections are usually false.
  final bool isDestination;

  const GraphNode({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.name = '',
    this.isDestination = false,
  });

  @override
  String toString() => 'GraphNode($id, $name)';
}
