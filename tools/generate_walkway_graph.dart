import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Real UHCL ArcGIS sidewalk polygons.
const String inputPath = 'assets/maps/campus_walkways.geojson';

/// Graph consumed by CampusGraphLoader.
const String outputPath = 'assets/maps/campus_walkway_graph.json';

/// Resolution used while deriving sidewalk centerlines.
///
/// Smaller = more accurate but more nodes.
/// 1.5 m is a reasonable starting point for campus sidewalks.
const double cellMeters = 1.5;

Future<void> main() async {
  final inputFile = File(inputPath);

  if (!inputFile.existsSync()) {
    print('ERROR: Could not find $inputPath');
    exitCode = 1;
    return;
  }

  print('Reading UHCL sidewalk polygons...');

  final root =
      jsonDecode(await inputFile.readAsString()) as Map<String, dynamic>;

  final features = root['features'] as List<dynamic>? ?? [];

  final polygons = <WalkablePolygon>[];

  for (final rawFeature in features) {
    if (rawFeature is! Map<String, dynamic>) {
      continue;
    }

    final rawGeometry = rawFeature['geometry'];

    if (rawGeometry is! Map<String, dynamic>) {
      continue;
    }

    final type = rawGeometry['type']?.toString();

    final coordinates = rawGeometry['coordinates'];

    if (coordinates is! List) {
      continue;
    }

    if (type == 'Polygon') {
      final polygon = _parsePolygon(coordinates);

      if (polygon != null) {
        polygons.add(polygon);
      }
    } else if (type == 'MultiPolygon') {
      for (final rawPolygon in coordinates) {
        if (rawPolygon is! List) continue;

        final polygon = _parsePolygon(rawPolygon);

        if (polygon != null) {
          polygons.add(polygon);
        }
      }
    }
  }

  if (polygons.isEmpty) {
    print('ERROR: No sidewalk polygons found.');
    exitCode = 1;
    return;
  }

  print('Loaded ${polygons.length} sidewalk polygons.');

  // Calculate an approximate center latitude so longitude
  // spacing can be converted from meters to degrees.
  var latitudeTotal = 0.0;

  for (final polygon in polygons) {
    latitudeTotal += (polygon.minLat + polygon.maxLat) / 2;
  }

  final centerLatitude = latitudeTotal / polygons.length;

  const metersPerLatitudeDegree = 111320.0;

  final metersPerLongitudeDegree =
      111320.0 * math.cos(centerLatitude * math.pi / 180.0);

  final latitudeStep = cellMeters / metersPerLatitudeDegree;

  final longitudeStep = cellMeters / metersPerLongitudeDegree;

  print(
    'Rasterizing sidewalks at '
    '$cellMeters meter resolution...',
  );

  // Sparse set:
  // only cells actually inside sidewalks are stored.
  final walkableCells = <int>{};

  for (var polygonIndex = 0; polygonIndex < polygons.length; polygonIndex++) {
    final polygon = polygons[polygonIndex];

    final minRow = (polygon.minLat / latitudeStep).floor();

    final maxRow = (polygon.maxLat / latitudeStep).ceil();

    final minColumn = (polygon.minLon / longitudeStep).floor();

    final maxColumn = (polygon.maxLon / longitudeStep).ceil();

    for (var row = minRow; row <= maxRow; row++) {
      final latitude = (row + 0.5) * latitudeStep;

      for (var column = minColumn; column <= maxColumn; column++) {
        final longitude = (column + 0.5) * longitudeStep;

        if (polygon.contains(GeoPoint(latitude, longitude))) {
          walkableCells.add(_cellKey(row, column));
        }
      }
    }

    if ((polygonIndex + 1) % 25 == 0 || polygonIndex == polygons.length - 1) {
      print(
        'Rasterized '
        '${polygonIndex + 1}/'
        '${polygons.length} polygons...',
      );
    }
  }

  print(
    'Walkable raster cells: '
    '${walkableCells.length}',
  );

  if (walkableCells.isEmpty) {
    print('ERROR: Sidewalk raster is empty.');
    exitCode = 1;
    return;
  }

  print('Generating sidewalk centerlines...');

  final skeleton = _thinToSkeleton(walkableCells);

  print('Centerline cells: ${skeleton.length}');

  if (skeleton.isEmpty) {
    print('ERROR: Centerline generation failed.');
    exitCode = 1;
    return;
  }

  // --------------------------------------------
  // Convert skeleton cells into CampusGraph nodes
  // --------------------------------------------

  final nodeIds = <int, String>{};
  final outputNodes = <List<dynamic>>[];

  var nodeNumber = 0;

  final orderedCells = skeleton.toList();

  orderedCells.sort();

  for (final key in orderedCells) {
    final row = _rowFromKey(key);

    final column = _columnFromKey(key);

    final latitude = (row + 0.5) * latitudeStep;

    final longitude = (column + 0.5) * longitudeStep;

    final id = 'w$nodeNumber';

    nodeIds[key] = id;

    outputNodes.add([
      id,
      double.parse(latitude.toStringAsFixed(8)),
      double.parse(longitude.toStringAsFixed(8)),
    ]);

    nodeNumber++;
  }

  // --------------------------------------------
  // Connect neighboring centerline cells
  // --------------------------------------------

  final outputEdges = <List<dynamic>>[];

  // Only half of the eight directions are checked
  // because CampusGraph.addEdge() makes each edge
  // bidirectional.
  const directions = <List<int>>[
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];

  for (final key in skeleton) {
    final fromId = nodeIds[key];

    if (fromId == null) continue;

    final row = _rowFromKey(key);

    final column = _columnFromKey(key);

    for (final direction in directions) {
      final neighborKey = _cellKey(row + direction[0], column + direction[1]);

      if (!skeleton.contains(neighborKey)) {
        continue;
      }

      final toId = nodeIds[neighborKey];

      if (toId == null) continue;

      outputEdges.add([
        fromId,
        toId,

        // General sidewalks are currently treated
        // as accessible. We will later refine this
        // with ramps / accessible entrances.
        1,
      ]);
    }
  }

  final output = {'nodes': outputNodes, 'edges': outputEdges};

  await File(outputPath).writeAsString(jsonEncode(output));

  print('');
  print('================================');
  print('UHCL WALKWAY GRAPH CREATED');
  print('================================');
  print('Nodes: ${outputNodes.length}');
  print('Edges: ${outputEdges.length}');
  print('Saved: $outputPath');
}

/// Zhang-Suen thinning.
///
/// Converts the filled sidewalk raster into a
/// one-cell-wide skeleton / approximate centerline.
Set<int> _thinToSkeleton(Set<int> input) {
  final pixels = Set<int>.from(input);

  var changed = true;
  var iteration = 0;

  while (changed) {
    changed = false;
    iteration++;

    // ------------------------
    // Sub-iteration 1
    // ------------------------

    final removeFirst = <int>[];

    final firstSnapshot = pixels.toList();

    for (final key in firstSnapshot) {
      final row = _rowFromKey(key);

      final column = _columnFromKey(key);

      final n = _neighbors(pixels, row, column);

      final neighborCount = n.fold<int>(0, (sum, value) => sum + value);

      if (neighborCount < 2 || neighborCount > 6) {
        continue;
      }

      if (_transitions(n) != 1) {
        continue;
      }

      // P2 * P4 * P6 == 0
      if (n[0] * n[2] * n[4] != 0) {
        continue;
      }

      // P4 * P6 * P8 == 0
      if (n[2] * n[4] * n[6] != 0) {
        continue;
      }

      removeFirst.add(key);
    }

    if (removeFirst.isNotEmpty) {
      changed = true;
      pixels.removeAll(removeFirst);
    }

    // ------------------------
    // Sub-iteration 2
    // ------------------------

    final removeSecond = <int>[];

    final secondSnapshot = pixels.toList();

    for (final key in secondSnapshot) {
      final row = _rowFromKey(key);

      final column = _columnFromKey(key);

      final n = _neighbors(pixels, row, column);

      final neighborCount = n.fold<int>(0, (sum, value) => sum + value);

      if (neighborCount < 2 || neighborCount > 6) {
        continue;
      }

      if (_transitions(n) != 1) {
        continue;
      }

      // P2 * P4 * P8 == 0
      if (n[0] * n[2] * n[6] != 0) {
        continue;
      }

      // P2 * P6 * P8 == 0
      if (n[0] * n[4] * n[6] != 0) {
        continue;
      }

      removeSecond.add(key);
    }

    if (removeSecond.isNotEmpty) {
      changed = true;

      pixels.removeAll(removeSecond);
    }

    if (iteration % 10 == 0) {
      print(
        'Centerline iteration '
        '$iteration: '
        '${pixels.length} cells',
      );
    }
  }

  print(
    'Centerline completed after '
    '$iteration iterations.',
  );

  return pixels;
}

/// Returns P2..P9 in clockwise order.
///
/// P9 P2 P3
/// P8  P P4
/// P7 P6 P5
List<int> _neighbors(Set<int> pixels, int row, int column) {
  return [
    // P2 north
    pixels.contains(_cellKey(row + 1, column)) ? 1 : 0,

    // P3 north-east
    pixels.contains(_cellKey(row + 1, column + 1)) ? 1 : 0,

    // P4 east
    pixels.contains(_cellKey(row, column + 1)) ? 1 : 0,

    // P5 south-east
    pixels.contains(_cellKey(row - 1, column + 1)) ? 1 : 0,

    // P6 south
    pixels.contains(_cellKey(row - 1, column)) ? 1 : 0,

    // P7 south-west
    pixels.contains(_cellKey(row - 1, column - 1)) ? 1 : 0,

    // P8 west
    pixels.contains(_cellKey(row, column - 1)) ? 1 : 0,

    // P9 north-west
    pixels.contains(_cellKey(row + 1, column - 1)) ? 1 : 0,
  ];
}

int _transitions(List<int> neighbors) {
  var count = 0;

  for (var i = 0; i < neighbors.length; i++) {
    final current = neighbors[i];

    final next = neighbors[(i + 1) % neighbors.length];

    if (current == 0 && next == 1) {
      count++;
    }
  }

  return count;
}

int _cellKey(int row, int column) {
  return (row << 32) ^ (column & 0xFFFFFFFF);
}

int _rowFromKey(int key) {
  return key >> 32;
}

int _columnFromKey(int key) {
  var value = key & 0xFFFFFFFF;

  if (value >= 0x80000000) {
    value -= 0x100000000;
  }

  return value;
}

WalkablePolygon? _parsePolygon(List<dynamic> rawPolygon) {
  final rings = <List<GeoPoint>>[];

  for (final rawRing in rawPolygon) {
    if (rawRing is! List) {
      continue;
    }

    final ring = <GeoPoint>[];

    for (final rawCoordinate in rawRing) {
      if (rawCoordinate is! List || rawCoordinate.length < 2) {
        continue;
      }

      final longitude = rawCoordinate[0];

      final latitude = rawCoordinate[1];

      if (longitude is! num || latitude is! num) {
        continue;
      }

      ring.add(GeoPoint(latitude.toDouble(), longitude.toDouble()));
    }

    if (ring.length >= 3) {
      rings.add(ring);
    }
  }

  if (rings.isEmpty) {
    return null;
  }

  return WalkablePolygon(rings);
}

bool _pointInRing(GeoPoint point, List<GeoPoint> ring) {
  var inside = false;

  var j = ring.length - 1;

  for (var i = 0; i < ring.length; i++) {
    final a = ring[i];
    final b = ring[j];

    final crosses =
        ((a.latitude > point.latitude) != (b.latitude > point.latitude)) &&
        point.longitude <
            (b.longitude - a.longitude) *
                    (point.latitude - a.latitude) /
                    (b.latitude - a.latitude) +
                a.longitude;

    if (crosses) {
      inside = !inside;
    }

    j = i;
  }

  return inside;
}

class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint(this.latitude, this.longitude);
}

class WalkablePolygon {
  final List<List<GeoPoint>> rings;

  late final double minLat;
  late final double maxLat;
  late final double minLon;
  late final double maxLon;

  WalkablePolygon(this.rings) {
    final outer = rings.first;

    minLat = outer.map((point) => point.latitude).reduce(math.min);

    maxLat = outer.map((point) => point.latitude).reduce(math.max);

    minLon = outer.map((point) => point.longitude).reduce(math.min);

    maxLon = outer.map((point) => point.longitude).reduce(math.max);
  }

  bool contains(GeoPoint point) {
    if (point.latitude < minLat ||
        point.latitude > maxLat ||
        point.longitude < minLon ||
        point.longitude > maxLon) {
      return false;
    }

    // Must be inside outer polygon.
    if (!_pointInRing(point, rings.first)) {
      return false;
    }

    // Must not be inside a polygon hole.
    for (var i = 1; i < rings.length; i++) {
      if (_pointInRing(point, rings[i])) {
        return false;
      }
    }

    return true;
  }
}
