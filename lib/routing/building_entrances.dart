import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'campus_graph.dart';
import 'graph_node.dart';

/// The exterior entrance nodes (`NodeKind.entrance`) of one building.
///
/// [outlines] holds the outline of every building on campus (one list of
/// polygon rings per building, as in `campus_buildings.geojson`), and
/// [index] says which of them to collect entrances for. An entrance belongs
/// to the building whose outline it is closest to (0 m if it sits inside
/// the outline), as long as that is within [maxMeters]. Going by geometry
/// instead of building names means buildings whose names differ between the
/// map layers and the indoor graph still work, and neighbouring buildings
/// do not claim each other's doors.
List<GraphNode> entrancesOfBuilding(
  CampusGraph graph,
  List<List<List<LatLng>>> outlines,
  int index, {
  double maxMeters = 25,
}) {
  final result = <GraphNode>[];
  if (index < 0 || index >= outlines.length) return result;

  for (final node in graph.nodes) {
    if (node.kind != NodeKind.entrance) continue;

    var closest = -1;
    var closestMeters = double.infinity;
    for (var i = 0; i < outlines.length; i++) {
      final meters = _metersToOutline(
        node.latitude,
        node.longitude,
        outlines[i],
      );
      if (meters < closestMeters) {
        closestMeters = meters;
        closest = i;
      }
    }
    if (closest == index && closestMeters <= maxMeters) result.add(node);
  }
  return result;
}

/// Distance in meters from a point to a building outline (0 if inside).
double _metersToOutline(double lat, double lon, List<List<LatLng>> rings) {
  // Flat local projection: plenty accurate at building scale.
  const metersPerDegLat = 110540.0;
  final metersPerDegLon = 111320.0 * math.cos(lat * math.pi / 180);

  var best = double.infinity;
  for (final ring in rings) {
    if (ring.length < 3) continue;

    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i];
      final b = ring[j];

      if ((a.latitude > lat) != (b.latitude > lat) &&
          lon <
              (b.longitude - a.longitude) *
                      (lat - a.latitude) /
                      (b.latitude - a.latitude) +
                  a.longitude) {
        inside = !inside;
      }

      final ax = (a.longitude - lon) * metersPerDegLon;
      final ay = (a.latitude - lat) * metersPerDegLat;
      final bx = (b.longitude - lon) * metersPerDegLon;
      final by = (b.latitude - lat) * metersPerDegLat;
      final dx = bx - ax;
      final dy = by - ay;
      final lengthSquared = dx * dx + dy * dy;
      final t = lengthSquared == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / lengthSquared).clamp(0.0, 1.0).toDouble();
      final px = ax + t * dx;
      final py = ay + t * dy;
      best = math.min(best, math.sqrt(px * px + py * py));
    }
    if (inside) return 0;
  }
  return best;
}
