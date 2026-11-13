import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

// Relative imports so this works without knowing the app's package name.
import '../../lib/routing/campus_graph_loader.dart';
import '../../lib/routing/routing.dart';

GraphNode _node(
  String id,
  NodeKind kind, {
  int floor = 0,
  String building = '',
}) => GraphNode(
  id: id,
  latitude: 29.0,
  longitude: -95.0,
  floor: floor,
  kind: kind,
  building: building,
);

bool _hasKind(RouteResult route, NodeKind kind) =>
    route.path.any((node) => node.kind == kind);

void main() {
  group('RouteGenerator.routeFilter (small graph)', () {
    // O --5-- E1 --5-- C --5-- E2 --5-- O2   (through building T)
    // O ------40------ X ------40------ O2   (outside, longer)
    CampusGraph build() {
      final g = CampusGraph();
      g.addNode(_node('O', NodeKind.outdoor));
      g.addNode(_node('X', NodeKind.outdoor));
      g.addNode(_node('O2', NodeKind.outdoor));
      g.addNode(_node('E1', NodeKind.entrance, floor: 1, building: 'T'));
      g.addNode(_node('C', NodeKind.corridor, floor: 1, building: 'T'));
      g.addNode(_node('E2', NodeKind.entrance, floor: 1, building: 'T'));
      g.addEdge('O', 'E1', distanceMeters: 5);
      g.addEdge('E1', 'C', distanceMeters: 5);
      g.addEdge('C', 'E2', distanceMeters: 5);
      g.addEdge('E2', 'O2', distanceMeters: 5);
      g.addEdge('O', 'X', distanceMeters: 40);
      g.addEdge('X', 'O2', distanceMeters: 40);
      return g;
    }

    test('no accessibility and nothing to avoid means no filter', () {
      final generator = RouteGenerator(build());
      expect(generator.routeFilter(accessibleOnly: false), isNull);
    });

    test('without avoidInteriorOf the route may cut through a building', () {
      final route = RouteGenerator(build()).generate('O', 'E2');
      expect(route.path.map((n) => n.id), ['O', 'E1', 'C', 'E2']);
    });

    test('avoidInteriorOf keeps the route out of the building', () {
      final generator = RouteGenerator(build());
      final route = generator.generate(
        'O',
        'E2',
        edgeFilter: generator.routeFilter(
          accessibleOnly: false,
          avoidInteriorOf: {'T'},
        ),
      );
      expect(route.path.map((n) => n.id), ['O', 'X', 'O2', 'E2']);
    });

    test('an entrance itself can still be reached when avoiding', () {
      final generator = RouteGenerator(build());
      final route = generator.generate(
        'O',
        'E1',
        edgeFilter: generator.routeFilter(
          accessibleOnly: false,
          avoidInteriorOf: {'T'},
        ),
      );
      expect(route.path.map((n) => n.id), ['O', 'E1']);
    });

    test('accessibleOnly still blocks stairs when combined', () {
      final g = build();
      g.addNode(_node('S', NodeKind.stairs, floor: 1, building: 'U'));
      g.addEdge('O', 'S', distanceMeters: 1);
      g.addEdge('S', 'O2', distanceMeters: 1);
      final generator = RouteGenerator(g);

      expect(generator.generate('O', 'O2').path.map((n) => n.id), [
        'O',
        'S',
        'O2',
      ]);

      final route = generator.generate(
        'O',
        'O2',
        edgeFilter: generator.routeFilter(
          accessibleOnly: true,
          avoidInteriorOf: {'T'},
        ),
      );
      expect(route.path.map((n) => n.id), ['O', 'X', 'O2']);
    });
  });

  group('building entrances on the real campus data', () {
    late CampusGraph graph;
    late RouteGenerator generator;
    late List<String> buildingNames;
    late List<List<List<LatLng>>> outlines;

    setUpAll(() {
      graph = parseCampusGraph(
        File('assets/maps/campus_graph.json').readAsStringSync(),
      );
      addIndoorGraph(
        graph,
        File('assets/maps/campus_indoor_graph.json').readAsStringSync(),
      );
      generator = RouteGenerator(graph);

      // Same outlines the map screen uses: the outer ring of each polygon.
      final data = jsonDecode(
        File('assets/maps/campus_buildings.geojson').readAsStringSync(),
      ) as Map<String, dynamic>;
      buildingNames = [];
      outlines = [];
      for (final item in data['features'] as List<dynamic>) {
        final feature = item as Map<String, dynamic>;
        final properties = feature['properties'] as Map<String, dynamic>;
        final geometry = feature['geometry'] as Map<String, dynamic>;
        final coordinates = geometry['coordinates'] as List<dynamic>;
        final polygons = geometry['type'] == 'MultiPolygon'
            ? coordinates
            : [coordinates];
        buildingNames.add(properties['BuildingName'] as String);
        outlines.add([
          for (final polygon in polygons)
            [
              for (final point
                  in (polygon as List<dynamic>).first as List<dynamic>)
                LatLng(
                  ((point as List<dynamic>)[1] as num).toDouble(),
                  (point[0] as num).toDouble(),
                ),
            ],
        ]);
      }
    });

    List<GraphNode> entrancesOf(String buildingName) => entrancesOfBuilding(
      graph,
      outlines,
      buildingNames.indexOf(buildingName),
    );

    LatLng centerOf(String buildingName) {
      final points = [
        for (final ring in outlines[buildingNames.indexOf(buildingName)])
          ...ring,
      ];
      return LatLng(
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length,
        points.map((p) => p.longitude).reduce((a, b) => a + b) / points.length,
      );
    }

    GraphNode outdoorNear(double latitude, double longitude) => graph
        .nearestNode(
          latitude,
          longitude,
          where: (node) => node.kind == NodeKind.outdoor,
        )!
        .node;

    /// Same idea as the map screen: try every start/end node pair and keep
    /// the shortest route.
    RouteResult? bestRoute(
      List<GraphNode> starts,
      List<GraphNode> ends, {
      bool accessible = false,
      Set<String> avoidInteriorOf = const {},
    }) {
      final filter = generator.routeFilter(
        accessibleOnly: accessible,
        avoidInteriorOf: avoidInteriorOf,
      );
      RouteResult? best;
      for (final a in starts) {
        for (final b in ends) {
          if (a.id == b.id) continue;
          try {
            final candidate = generator.generate(
              a.id,
              b.id,
              edgeFilter: filter,
            );
            if (best == null ||
                candidate.distanceMeters < best.distanceMeters) {
              best = candidate;
            }
          } on RouteException {
            // No route for this pair; try the next one.
          }
        }
      }
      return best;
    }

    int interiorNodes(RouteResult route, String building) => route.path
        .where(
          (n) =>
              n.building == building &&
              n.floor > 0 &&
              n.kind != NodeKind.entrance,
        )
        .length;

    const bayouGraphName = '601-BAYOU BUILDING';
    const deltaGraphName = '604-DELTA BUILDING';

    test('Bayou has a north, west and east entrance', () {
      final bayou = entrancesOf('Bayou Building');
      expect(bayou.length, 3);
      expect(bayou.every((n) => n.building == bayouGraphName), isTrue);

      final center = centerOf('Bayou Building');
      expect(bayou.any((n) => n.latitude > center.latitude), isTrue); // north
      expect(bayou.any((n) => n.longitude < center.longitude), isTrue); // west
      expect(bayou.any((n) => n.longitude > center.longitude), isTrue); // east
    });

    test('every entrance belongs to exactly one building', () {
      final total = graph.nodes.where((n) => n.kind == NodeKind.entrance);
      final claimed = [for (final name in buildingNames) ...entrancesOf(name)];
      expect(claimed.length, total.length);
      expect({for (final n in claimed) n.id}.length, claimed.length);
    });

    test('every Bayou entrance connects to the outdoor walkways', () {
      for (final entrance in entrancesOf('Bayou Building')) {
        final outdoorLinks = graph
            .edgesFrom(entrance.id)
            .where((e) => graph.nodeById(e.to)!.kind == NodeKind.outdoor);
        expect(outdoorLinks, isNotEmpty, reason: entrance.id);
      }
    });

    test('Delta to Bayou building stops at an entrance, not inside', () {
      final delta = entrancesOf('Delta Building');
      final bayou = entrancesOf('Bayou Building');
      expect(delta, isNotEmpty);

      final route = bestRoute(
        delta,
        bayou,
        avoidInteriorOf: {bayouGraphName, deltaGraphName},
      )!;

      expect(route.destination.kind, NodeKind.entrance);
      expect(route.destination.building, bayouGraphName);
      expect(interiorNodes(route, bayouGraphName), 0);
      expect(
        route.path
            .where(
              (n) =>
                  n.kind == NodeKind.entrance && n.building == bayouGraphName,
            )
            .length,
        1,
        reason: 'only the final entrance of Bayou may be on the route',
      );
    });

    test('the entrance chosen follows the side the user comes from', () {
      final bayou = entrancesOf('Bayou Building');
      final center = centerOf('Bayou Building');

      GraphNode chosenFrom(double dLat, double dLon) {
        final start = outdoorNear(
          center.latitude + dLat,
          center.longitude + dLon,
        );
        final route = bestRoute(
          [start],
          bayou,
          avoidInteriorOf: {bayouGraphName},
        )!;
        expect(interiorNodes(route, bayouGraphName), 0);
        return route.destination;
      }

      final west = chosenFrom(-0.0001, -0.0010);
      final north = chosenFrom(0.0013, 0.0002);
      final east = chosenFrom(-0.0002, 0.0010);
      expect(west.longitude, lessThan(center.longitude));
      expect(north.latitude, greaterThan(center.latitude));
      expect(east.longitude, greaterThan(center.longitude));
    });

    test('Bayou building as the start leaves from an entrance, outdoors', () {
      final route = bestRoute(
        entrancesOf('Bayou Building'),
        entrancesOf('Delta Building'),
        avoidInteriorOf: {bayouGraphName, deltaGraphName},
      )!;
      expect(route.start.kind, NodeKind.entrance);
      expect(route.start.building, bayouGraphName);
      expect(interiorNodes(route, bayouGraphName), 0);
    });

    test('a room in Bayou can still reach a Bayou entrance indoors', () {
      final rooms = graph.nodes
          .where(
            (n) =>
                n.kind == NodeKind.room &&
                n.building == bayouGraphName &&
                n.floor == 3,
          )
          .toList();
      // The room's building stays open: no avoidInteriorOf.
      final route = bestRoute([rooms[100]], entrancesOf('Bayou Building'))!;
      expect(route.destination.kind, NodeKind.entrance);
      expect(interiorNodes(route, bayouGraphName), greaterThan(0));
    });

    test('outdoor to an upper-floor room: stairs off, elevator on', () {
      final rooms = graph.nodes
          .where(
            (n) =>
                n.kind == NodeKind.room &&
                n.building == bayouGraphName &&
                n.floor == 3,
          )
          .toList();
      final room = rooms[100];
      final center = centerOf('Bayou Building');
      final start = outdoorNear(
        center.latitude - 0.0001,
        center.longitude - 0.0010,
      );

      final normal = bestRoute([start], [room])!;
      expect(_hasKind(normal, NodeKind.stairs), isTrue);
      expect(_hasKind(normal, NodeKind.elevator), isFalse);
      expect(normal.path.any((n) => n.kind == NodeKind.entrance), isTrue);

      final accessible = bestRoute([start], [room], accessible: true)!;
      expect(_hasKind(accessible, NodeKind.stairs), isFalse);
      expect(_hasKind(accessible, NodeKind.elevator), isTrue);
      expect(accessible.path.any((n) => n.kind == NodeKind.entrance), isTrue);
    });

    test('room to outdoors leaves through an entrance', () {
      final room = graph.nodes.firstWhere(
        (n) =>
            n.kind == NodeKind.room &&
            n.building == bayouGraphName &&
            n.floor == 3,
      );
      final center = centerOf('Bayou Building');
      final end = outdoorNear(
        center.latitude - 0.0001,
        center.longitude - 0.0010,
      );
      final route = bestRoute([room], [end])!;
      expect(route.path.any((n) => n.kind == NodeKind.entrance), isTrue);
      expect(route.destination.kind, NodeKind.outdoor);
    });

    test('floor 1 to floor 3 room: stairs when off, elevator when on', () {
      final floor1 = graph.nodes
          .where(
            (n) =>
                n.kind == NodeKind.room &&
                n.building == bayouGraphName &&
                n.floor == 1,
          )
          .toList()[60];
      final floor3 = graph.nodes
          .where(
            (n) =>
                n.kind == NodeKind.room &&
                n.building == bayouGraphName &&
                n.floor == 3,
          )
          .toList()[100];

      final normal = bestRoute([floor1], [floor3])!;
      expect(_hasKind(normal, NodeKind.stairs), isTrue);
      expect(_hasKind(normal, NodeKind.elevator), isFalse);

      final accessible = bestRoute([floor1], [floor3], accessible: true)!;
      expect(_hasKind(accessible, NodeKind.stairs), isFalse);
      expect(_hasKind(accessible, NodeKind.elevator), isTrue);
    });
  });
}
