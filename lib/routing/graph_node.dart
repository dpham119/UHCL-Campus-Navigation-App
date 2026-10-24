/// What a node represents.
enum NodeKind { outdoor, corridor, room, stairs, elevator, entrance }

/// A point on the campus walking network: an intersection, building
/// entrance, room, or other destination.
class GraphNode {
  final String id;
  final String name;
  final double latitude;
  final double longitude;

  /// True if users can pick this node as a destination (e.g. a building
  /// entrance). Plain intersections are usually false.
  final bool isDestination;

  /// 0 = outdoors, 1 and up = a floor inside a building.
  final int floor;

  final NodeKind kind;

  /// Building name for indoor nodes (same text as the floor GeoJSON's
  /// `Building` field). Empty for outdoor nodes.
  final String building;

  const GraphNode({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.name = '',
    this.isDestination = false,
    this.floor = 0,
    this.kind = NodeKind.outdoor,
    this.building = '',
  });

  @override
  String toString() => 'GraphNode($id, $name)';
}
