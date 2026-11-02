import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Relative imports so this works without knowing the app's package name.
import '../../lib/routing/campus_graph_loader.dart';
import '../../lib/routing/routing.dart';

bool _hasKind(RouteResult route, NodeKind kind) =>
    route.path.any((node) => node.kind == kind);

/// True if every step that changes floor (indoors) goes elevator to
/// elevator.
bool _floorChangesUseElevators(RouteResult route) {
  for (var i = 0; i + 1 < route.path.length; i++) {
    final a = route.path[i];
    final b = route.path[i + 1];
    if (a.floor > 0 && b.floor > 0 && a.floor != b.floor) {
      if (a.kind != NodeKind.elevator || b.kind != NodeKind.elevator) {
        return false;
      }
    }
  }
  return true;
}

GraphNode _node(
  String id,
  NodeKind kind, {
  int floor = 1,
  double lon = -95.0,
}) =>
    GraphNode(
      id: id,
      latitude: 29.0,
      longitude: lon,
      floor: floor,
      kind: kind,
      building: 'T',
    );

void main() {
  group('accessibleEdgeFilter (small graph)', () {
    // Floor 1: C1 --- S1(stairs) --- C2 is the short way across, with flat
    // accessible edges. C1 --- X --- C2 is a longer corridor.
    // Floor 1 -> 2: S1 - S2 (stairs, not accessible, short),
    //               E1 - E2 (elevator, accessible, longer).
    CampusGraph build() {
      final g = CampusGraph();
      g.addNode(_node('C1', NodeKind.corridor));
      g.addNode(_node('S1', NodeKind.stairs));
      g.addNode(_node('C2', NodeKind.corridor));
      g.addNode(_node('X', NodeKind.corridor));
      g.addNode(_node('E1', NodeKind.elevator));
      g.addNode(_node('S2', NodeKind.stairs, floor: 2));
      g.addNode(_node('E2', NodeKind.elevator, floor: 2));
      g.addNode(_node('R2', NodeKind.room, floor: 2));

      g.addEdge('C1', 'S1', distanceMeters: 5);
      g.addEdge('S1', 'C2', distanceMeters: 5);
      g.addEdge('C1', 'X', distanceMeters: 20);
      g.addEdge('X', 'C2', distanceMeters: 20);

      g.addEdge('C2', 'E1', distanceMeters: 30);
      g.addEdge('S1', 'S2', distanceMeters: 15, isAccessible: false);
      g.addEdge('E1', 'E2', distanceMeters: 25);
      g.addEdge('S2', 'R2', distanceMeters: 5);
      g.addEdge('E2', 'R2', distanceMeters: 5);
      return g;
    }

    test('normal route may use stair nodes', () {
      final route = RouteGenerator(build()).generate('C1', 'C2');
      expect(route.path.map((n) => n.id), ['C1', 'S1', 'C2']);
    });

    test('accessible route never walks through a stair node', () {
      final generator = RouteGenerator(build());
      final route = generator.generate(
        'C1',
        'C2',
        edgeFilter: generator.accessibleEdgeFilter,
      );
      expect(route.path.map((n) => n.id), ['C1', 'X', 'C2']);
      expect(_hasKind(route, NodeKind.stairs), isFalse);
    });

    test('stairs are shorter normally, accessible uses the elevator', () {
      final generator = RouteGenerator(build());

      final normal = generator.generate('C1', 'R2');
      expect(_hasKind(normal, NodeKind.stairs), isTrue);

      final accessible = generator.generate(
        'C1',
        'R2',
        edgeFilter: generator.accessibleEdgeFilter,
      );
      expect(_hasKind(accessible, NodeKind.stairs), isFalse);
      expect(_hasKind(accessible, NodeKind.elevator), isTrue);
      expect(accessible.path.map((n) => n.id),
          ['C1', 'X', 'C2', 'E1', 'E2', 'R2']);
      expect(accessible.distanceMeters, greaterThan(normal.distanceMeters));
    });

    test('no elevator means no accessible route', () {
      final g = CampusGraph();
      g.addNode(_node('A', NodeKind.room));
      g.addNode(_node('S1', NodeKind.stairs));
      g.addNode(_node('S2', NodeKind.stairs, floor: 2));
      g.addNode(_node('B', NodeKind.room, floor: 2));
      g.addEdge('A', 'S1', distanceMeters: 5);
      g.addEdge('S1', 'S2', distanceMeters: 15, isAccessible: false);
      g.addEdge('S2', 'B', distanceMeters: 5);

      final generator = RouteGenerator(g);
      expect(generator.generate('A', 'B').path.length, 4);
      expect(
        () => generator.generate(
          'A',
          'B',
          edgeFilter: generator.accessibleEdgeFilter,
        ),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.noPathFound)),
      );
    });
  });

  group('accessible routing on the real campus data', () {
    late CampusGraph graph;
    late RouteGenerator generator;

    setUpAll(() {
      graph = parseCampusGraph(
        File('assets/maps/campus_graph.json').readAsStringSync(),
      );
      addIndoorGraph(
        graph,
        File('assets/maps/campus_indoor_graph.json').readAsStringSync(),
      );
      generator = RouteGenerator(graph);
    });

    const bayou = '601-BAYOU BUILDING';

    /// Every [step]-th room node of [building] on [floor], in id order.
    List<GraphNode> roomsOn(String building, int floor, {int step = 40}) {
      final rooms = graph.nodes
          .where((n) =>
              n.kind == NodeKind.room &&
              n.building == building &&
              n.floor == floor)
          .toList();
      return [for (var i = 0; i < rooms.length; i += step) rooms[i]];
    }

    RouteResult? accessible(GraphNode a, GraphNode b) {
      try {
        return generator.generate(
          a.id,
          b.id,
          edgeFilter: generator.accessibleEdgeFilter,
        );
      } on RouteException {
        return null;
      }
    }

    test('the graph has stair and elevator nodes on every Bayou floor', () {
      for (final floor in [1, 2, 3]) {
        for (final kind in [NodeKind.stairs, NodeKind.elevator]) {
          expect(
            graph.nodes.any((n) =>
                n.kind == kind && n.building == bayou && n.floor == floor),
            isTrue,
            reason: '$kind missing on floor $floor',
          );
        }
      }
    });

    test('elevator-to-elevator floor links exist and are accessible', () {
      var links = 0;
      for (final node in graph.nodes.where((n) => n.kind == NodeKind.elevator)) {
        for (final edge in graph.edgesFrom(node.id)) {
          final other = graph.nodeById(edge.to)!;
          if (other.floor != node.floor) {
            links++;
            expect(other.kind, NodeKind.elevator);
            expect(edge.isAccessible, isTrue);
          }
        }
      }
      expect(links, greaterThan(0));
    });

    test('same-floor routes: accessible never uses stairs', () {
      for (final floor in [1, 2, 3]) {
        final rooms = roomsOn(bayou, floor);
        var checked = 0;
        for (final a in rooms) {
          for (final b in rooms) {
            if (a.id == b.id) continue;
            final route = accessible(a, b);
            if (route == null) continue;
            checked++;
            expect(_hasKind(route, NodeKind.stairs), isFalse);
          }
        }
        expect(checked, greaterThan(0), reason: 'floor $floor');
      }
    });

    test('floor 1 -> 2 and 1 -> 3 accessible routes use only elevators', () {
      for (final targetFloor in [2, 3]) {
        var checked = 0;
        for (final a in roomsOn(bayou, 1)) {
          for (final b in roomsOn(bayou, targetFloor)) {
            final route = accessible(a, b);
            if (route == null) continue;
            checked++;
            expect(_hasKind(route, NodeKind.stairs), isFalse);
            expect(_hasKind(route, NodeKind.elevator), isTrue);
            expect(_floorChangesUseElevators(route), isTrue);
          }
        }
        expect(checked, greaterThan(0), reason: '1 -> $targetFloor');
      }
    });

    test('some trips use stairs normally but must use an elevator when '
        'accessible', () {
      var found = 0;
      for (final a in roomsOn(bayou, 1)) {
        for (final b in roomsOn(bayou, 3)) {
          final normal = generator.generate(a.id, b.id);
          final route = accessible(a, b);
          if (route == null) continue;
          expect(route.distanceMeters,
              greaterThanOrEqualTo(normal.distanceMeters - 1e-6));
          if (_hasKind(normal, NodeKind.stairs)) {
            found++;
            expect(_hasKind(route, NodeKind.stairs), isFalse);
            expect(_hasKind(route, NodeKind.elevator), isTrue);
          }
        }
      }
      expect(found, greaterThan(0));
    });

    test('outdoor location -> upper-floor room works when accessible', () {
      // An outdoor node that an entrance of the Bayou building links to.
      final entrance = graph.nodes.firstWhere(
          (n) => n.kind == NodeKind.entrance && n.building == bayou);
      final outdoor = graph
          .edgesFrom(entrance.id)
          .map((e) => graph.nodeById(e.to)!)
          .firstWhere((n) => n.kind == NodeKind.outdoor);

      var checked = 0;
      for (final room in roomsOn(bayou, 3)) {
        final route = accessible(outdoor, room);
        if (route == null) continue;
        checked++;
        expect(_hasKind(route, NodeKind.stairs), isFalse);
        expect(_hasKind(route, NodeKind.elevator), isTrue);
        expect(_floorChangesUseElevators(route), isTrue);
      }
      expect(checked, greaterThan(0));
    });

    test('outdoor pathways still route the same with accessibility on', () {
      final outdoorNodes = <GraphNode>[];
      for (final entrance
          in graph.nodes.where((n) => n.kind == NodeKind.entrance)) {
        for (final edge in graph.edgesFrom(entrance.id)) {
          final other = graph.nodeById(edge.to)!;
          if (other.kind == NodeKind.outdoor) {
            outdoorNodes.add(other);
            break;
          }
        }
      }
      expect(outdoorNodes.length, greaterThan(1));

      final from = outdoorNodes.first;
      for (final to in outdoorNodes.skip(1)) {
        if (to.id == from.id) continue;
        final normal = generator.generate(from.id, to.id);
        final route = generator.generate(
          from.id,
          to.id,
          edgeFilter: generator.accessibleEdgeFilter,
        );
        expect(route.distanceMeters, closeTo(normal.distanceMeters, 1e-6));
        expect(route.path.map((n) => n.id), normal.path.map((n) => n.id));
      }
    });
  });
}
