import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../lib/routing/routing.dart';

GraphNode _n(String id, double lat, double lon, NodeKind kind) => GraphNode(
      id: id,
      latitude: lat,
      longitude: lon,
      floor: 1,
      kind: kind,
      building: 'B',
    );

void main() {
  // An L-shaped hallway: east along lat 0..0.0001, then north.
  final json = jsonEncode({
    'buildings': ['B'],
    'regions': [
      [
        0,
        1,
        [
          [
            [0.0, 0.0],
            [0.0, 0.0010],
            [0.0010, 0.0010],
            [0.0010, 0.0009],
            [0.0001, 0.0009],
            [0.0001, 0.0],
            [0.0, 0.0],
          ],
        ],
      ],
    ],
  });
  final regions = IndoorRegions.parse(json);

  test('segmentInside accepts hallway lines and rejects wall crossings', () {
    expect(regions.segmentInside('B', 1, const LatLng(0.00005, 0.00005),
        const LatLng(0.00005, 0.00095)), isTrue);
    expect(regions.segmentInside('B', 1, const LatLng(0.00005, 0.00005),
        const LatLng(0.00095, 0.00095)), isFalse);
  });

  test('smoothPath keeps the corner of an L-shaped hallway', () {
    final path = [
      _n('a', 0.00005, 0.00005, NodeKind.corridor),
      _n('b', 0.00005, 0.00095, NodeKind.corridor),
      _n('c', 0.00095, 0.00095, NodeKind.corridor),
    ];
    final points = regions.smoothPath(path);
    expect(points.length, 3);
    expect(points[1].longitude, closeTo(0.00095, 1e-9));
  });
}
