import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'graph_node.dart';

class _Polygon {
  final List<List<LatLng>> rings; // first = outer ring, rest = holes
  final double minLat, maxLat, minLon, maxLon;

  _Polygon(this.rings)
      : minLat = rings.first.map((p) => p.latitude).reduce(math.min),
        maxLat = rings.first.map((p) => p.latitude).reduce(math.max),
        minLon = rings.first.map((p) => p.longitude).reduce(math.min),
        maxLon = rings.first.map((p) => p.longitude).reduce(math.max);

  bool contains(double lat, double lon) {
    if (lat < minLat || lat > maxLat || lon < minLon || lon > maxLon) {
      return false;
    }
    var inside = false;
    for (final ring in rings) {
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
      }
    }
    return inside;
  }
}

/// The walkable floor area of each building floor (hallways, lobbies,
/// stairwells). Used to straighten indoor routes: the raw route follows a
/// 1.5 m grid and zig-zags, so the line is pulled tight wherever a straight
/// segment stays inside the walkable area (never through a wall).
class IndoorRegions {
  final Map<String, List<_Polygon>> _byFloor = {};
  final List<_Polygon> _footprints = [];

  static String _key(String building, int floor) => '$building|$floor';

  /// Reads the "regions" list of `campus_indoor_graph.json`.
  factory IndoorRegions.parse(String indoorJson) {
    final data = jsonDecode(indoorJson) as Map<String, dynamic>;
    final buildings = (data['buildings'] as List<dynamic>).cast<String>();
    final result = IndoorRegions._();
    for (final item in (data['regions'] as List<dynamic>? ?? const [])) {
      final entry = item as List<dynamic>;
      final key = _key(buildings[(entry[0] as num).toInt()], (entry[1] as num).toInt());
      final rings = <List<LatLng>>[
        for (final ring in entry[2] as List<dynamic>)
          [
            for (final p in ring as List<dynamic>)
              LatLng(((p as List<dynamic>)[0] as num).toDouble(),
                  (p[1] as num).toDouble()),
          ],
      ];
      if (rings.isEmpty || rings.first.length < 3) continue;
      result._byFloor.putIfAbsent(key, () => []).add(_Polygon(rings));
    }
    for (final item in (data['footprints'] as List<dynamic>? ?? const [])) {
      final entry = item as List<dynamic>;
      final rings = <List<LatLng>>[
        for (final ring in entry[1] as List<dynamic>)
          [
            for (final p in ring as List<dynamic>)
              LatLng(((p as List<dynamic>)[0] as num).toDouble(),
                  (p[1] as num).toDouble()),
          ],
      ];
      if (rings.isEmpty || rings.first.length < 3) continue;
      result._footprints.add(_Polygon(rings));
    }
    return result;
  }

  IndoorRegions._();

  /// True if the straight line from [from] to [to] passes through the inside
  /// of a building. Outlines are shrunk by 1 m, and the first
  /// [skipMeters] of the line are ignored so a line may start at a door.
  bool segmentCrossesBuilding(LatLng from, LatLng to, {double skipMeters = 3}) {
    final meters = const Distance().as(LengthUnit.Meter, from, to);
    final steps = math.max(1, (meters / 0.5).ceil());
    for (var i = 0; i <= steps; i++) {
      if (i * meters / steps < skipMeters) continue;
      final t = i / steps;
      final lat = from.latitude + (to.latitude - from.latitude) * t;
      final lon = from.longitude + (to.longitude - from.longitude) * t;
      if (_contains(_footprints, lat, lon)) return true;
    }
    return false;
  }

  bool _contains(List<_Polygon> polys, double lat, double lon) {
    for (final p in polys) {
      if (p.contains(lat, lon)) return true;
    }
    return false;
  }

  /// True if the straight line a-b stays inside the walkable area.
  bool segmentInside(String building, int floor, LatLng a, LatLng b) {
    final polys = _byFloor[_key(building, floor)];
    if (polys == null) return false;
    const stepMeters = 0.3;
    final meters = const Distance().as(LengthUnit.Meter, a, b);
    final steps = math.max(1, (meters / stepMeters).ceil());
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final lat = a.latitude + (b.latitude - a.latitude) * t;
      final lon = a.longitude + (b.longitude - a.longitude) * t;
      if (!_contains(polys, lat, lon)) return false;
    }
    return true;
  }

  /// Turns a node path into map points. Stretches of hallway nodes on one
  /// floor are pulled straight; everything else (rooms, stairs, elevators,
  /// entrances, outdoor points) is kept as is.
  List<LatLng> smoothPath(List<GraphNode> path) {
    final points = <LatLng>[];
    var i = 0;
    while (i < path.length) {
      final node = path[i];
      if (node.kind != NodeKind.corridor || node.floor == 0) {
        points.add(LatLng(node.latitude, node.longitude));
        i++;
        continue;
      }
      var end = i;
      while (end + 1 < path.length &&
          path[end + 1].kind == NodeKind.corridor &&
          path[end + 1].floor == node.floor &&
          path[end + 1].building == node.building) {
        end++;
      }
      var start = i;
      points.add(LatLng(path[start].latitude, path[start].longitude));
      while (start < end) {
        var next = start + 1;
        final from = LatLng(path[start].latitude, path[start].longitude);
        for (var j = math.min(end, start + 80); j > start + 1; j--) {
          final to = LatLng(path[j].latitude, path[j].longitude);
          if (segmentInside(node.building, node.floor, from, to)) {
            next = j;
            break;
          }
        }
        points.add(LatLng(path[next].latitude, path[next].longitude));
        start = next;
      }
      i = end + 1;
    }
    return points;
  }
}
