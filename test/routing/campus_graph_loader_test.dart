import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../lib/routing/campus_graph_loader.dart';
import '../../lib/routing/routing.dart';

void main() {
  group('parseCampusGraph', () {
    // a --- b --- c   (b-c is stairs)   and a longer way a --- d --- c
    const json = '''
{"version":1,"nodes":[
  ["a",29.5770,-95.1000],
  ["b",29.5770,-95.0990],
  ["c",29.5770,-95.0980],
  ["d",29.5780,-95.0990]
],"edges":[
  ["a","b",1],
  ["b","c",0],
  ["a","d",1],
  ["d","c",1]
]}''';

    test('loads nodes and edges', () {
      final graph = parseCampusGraph(json);
      expect(graph.nodeCount, 4);
      expect(graph.edgesFrom('a').length, 2);
      expect(graph.edgesFrom('c').length, 2); // edges are two-way
    });

    test('computes edge length from coordinates', () {
      final graph = parseCampusGraph(json);
      final ab = graph.edgesFrom('a').firstWhere((e) => e.to == 'b');
      expect(ab.distanceMeters, inInclusiveRange(90, 100)); // ~0.001 deg lon
    });

    test('stairs edges are not accessible', () {
      final graph = parseCampusGraph(json);
      final bc = graph.edgesFrom('b').firstWhere((e) => e.to == 'c');
      expect(bc.isAccessible, isFalse);
    });

    test('accessible route avoids the stairs', () {
      final graph = parseCampusGraph(json);
      final generator = RouteGenerator(graph);

      final normal = generator.generate('a', 'c');
      expect(normal.path.map((n) => n.id), ['a', 'b', 'c']);

      final accessible = generator.generate(
        'a',
        'c',
        edgeFilter: (edge) => edge.isAccessible,
      );
      expect(accessible.path.map((n) => n.id), ['a', 'd', 'c']);
    });

    test('nearestNode finds the closest node and its distance', () {
      final graph = parseCampusGraph(json);
      final nearest = graph.nearestNode(29.5771, -95.0991)!;
      expect(nearest.node.id, 'b');
      expect(nearest.distanceMeters, lessThan(20));
    });

    test('nearestNode is null for an empty graph', () {
      expect(CampusGraph().nearestNode(29.5, -95.1), isNull);
    });
  });

  group('addIndoorGraph', () {
    // Outdoors: n1 --- n2. Building "B": entrance i0 next to n2, a floor 1
    // corridor i1, stairs i2 and elevator i3 on floor 1, stairs i4 and
    // elevator i5 on floor 2, and a room i6 on floor 2.
    const outdoor = '''
{"nodes":[["n1",29.5770,-95.1000],["n2",29.5770,-95.0990]],
 "edges":[["n1","n2",1]]}''';
    const indoor = '''
{"buildings":["B"],
 "nodes":[
  [29.57701,-95.09900,1,5,0],
  [29.57710,-95.09900,1,1,0],
  [29.57710,-95.09890,1,3,0],
  [29.57710,-95.09880,1,4,0],
  [29.57710,-95.09890,2,3,0],
  [29.57710,-95.09880,2,4,0],
  [29.57720,-95.09885,2,2,0]
 ],
 "edges":[
  [0,1,100,1],[1,2,90,1],[2,3,90,1],
  [2,4,150,0],[3,5,250,1],
  [4,5,90,1],[4,6,110,1],[5,6,110,1]
 ]}''';

    CampusGraph build() {
      final graph = parseCampusGraph(outdoor);
      addIndoorGraph(graph, indoor);
      return graph;
    }

    test('reads floor, kind and building', () {
      final node = build().nodeById('i2')!;
      expect(node.kind, NodeKind.stairs);
      expect(node.floor, 1);
      expect(node.building, 'B');
      expect(build().nodeById('n1')!.floor, 0);
      expect(build().nodeById('n1')!.kind, NodeKind.outdoor);
    });

    test('joins the entrance to the nearest outdoor node', () {
      final graph = build();
      expect(graph.edgesFrom('i0').any((e) => e.to == 'n2'), isTrue);
      expect(graph.edgesFrom('i0').any((e) => e.to == 'n1'), isFalse);
    });

    test('stairs links are not accessible, elevator links are', () {
      final graph = build();
      final stairs = graph.edgesFrom('i2').firstWhere((e) => e.to == 'i4');
      final elevator = graph.edgesFrom('i3').firstWhere((e) => e.to == 'i5');
      expect(stairs.isAccessible, isFalse);
      expect(elevator.isAccessible, isTrue);
      expect(stairs.distanceMeters, closeTo(15.0, 0.001));
    });

    test('routes from outdoors to a room upstairs', () {
      final generator = RouteGenerator(build());

      final normal = generator.generate('n1', 'i6');
      expect(normal.path.map((n) => n.id),
          ['n1', 'n2', 'i0', 'i1', 'i2', 'i4', 'i6']);

      final accessible = generator.generate(
        'n1',
        'i6',
        edgeFilter: (edge) => edge.isAccessible,
      );
      expect(accessible.path.map((n) => n.id),
          ['n1', 'n2', 'i0', 'i1', 'i2', 'i3', 'i5', 'i6']);
    });

    test('nearestNode can be limited to one kind of node', () {
      final graph = build();
      final room = graph.nearestNode(
        29.5772,
        -95.09885,
        where: (node) => node.kind == NodeKind.room,
      )!;
      expect(room.node.id, 'i6');
      expect(room.distanceMeters, lessThan(5));

      final none = graph.nearestNode(
        29.5772,
        -95.09885,
        where: (node) => node.floor == 9,
      );
      expect(none, isNull);
    });
  });

  group('real campus graph assets', () {
    CampusGraph loadBoth() {
      final graph = parseCampusGraph(
        File('assets/maps/campus_graph.json').readAsStringSync(),
      );
      addIndoorGraph(
        graph,
        File('assets/maps/campus_indoor_graph.json').readAsStringSync(),
      );
      return graph;
    }

    test('indoor graph loads with rooms, stairs and elevators', () {
      final graph = loadBoth();
      expect(graph.nodeCount, greaterThan(10000));
      final kinds = graph.nodes.map((n) => n.kind).toSet();
      expect(kinds.containsAll(NodeKind.values), isTrue);
    });

    test('routes between rooms on different floors of the Bayou Building', () {
      final graph = loadBoth();
      final rooms = graph.nodes
          .where((n) =>
              n.kind == NodeKind.room && n.building.contains('BAYOU'))
          .toList();
      final first = rooms.firstWhere((n) => n.floor == 1);
      final upstairs = rooms.lastWhere((n) => n.floor == 3);

      final result = RouteGenerator(graph).generate(first.id, upstairs.id);
      expect(result.distanceMeters, greaterThan(0));
      expect(result.path.map((n) => n.floor).toSet(), containsAll([1, 3]));
    });
  });

  group('real campus graph asset', () {
    test('loads and can route between its first and last nodes', () {
      final text = File('assets/maps/campus_graph.json').readAsStringSync();
      final graph = parseCampusGraph(text);
      expect(graph.nodeCount, greaterThan(50));

      final nodes = graph.nodes.toList();
      final result = RouteGenerator(graph).generate(
        nodes.first.id,
        nodes.last.id,
      );
      expect(result.distanceMeters, greaterThan(0));
      expect(result.path.length, greaterThan(1));
    });
  });
}
