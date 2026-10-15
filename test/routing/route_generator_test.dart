import 'package:flutter_test/flutter_test.dart';

// Relative imports so this works without knowing the app's package name.
import '../../lib/routing/routing.dart';

/// Small sample graph (not real campus data):
///
///   A --100-- B --100-- C --50-- D
///   |_________300_______|
///                B --400-- D
///   E (not connected to anything)
CampusGraph buildSampleGraph({bool blockBC = false}) {
  final graph = CampusGraph();
  for (final id in ['A', 'B', 'C', 'D', 'E']) {
    graph.addNode(GraphNode(id: id, name: 'Node $id', latitude: 29.0, longitude: -95.0));
  }
  graph.addEdge('A', 'B', distanceMeters: 100);
  graph.addEdge('B', 'C', distanceMeters: 100, isAccessible: !blockBC);
  graph.addEdge('A', 'C', distanceMeters: 300);
  graph.addEdge('C', 'D', distanceMeters: 50);
  graph.addEdge('B', 'D', distanceMeters: 400);
  return graph;
}

void main() {
  group('haversineMeters', () {
    test('one degree of latitude is about 111 km', () {
      expect(haversineMeters(29, -95, 30, -95), closeTo(111195, 100));
    });

    test('same point is zero', () {
      expect(haversineMeters(29.5, -95.1, 29.5, -95.1), 0);
    });
  });

  group('RouteGenerator', () {
    test('picks the shortest multi-step route over a longer direct one', () {
      final route = RouteGenerator(buildSampleGraph()).generate('A', 'D');
      expect(route.path.map((n) => n.id).toList(), ['A', 'B', 'C', 'D']);
      expect(route.distanceMeters, 250);
    });

    test('estimates walking time from distance', () {
      final route = RouteGenerator(buildSampleGraph()).generate('A', 'D');
      // 250 m at 1.4 m/s is about 178.6 seconds.
      expect(route.walkingTime.inSeconds, 178);
    });

    test('start equal to destination gives a zero-length route', () {
      final route = RouteGenerator(buildSampleGraph()).generate('A', 'A');
      expect(route.path.length, 1);
      expect(route.distanceMeters, 0);
      expect(route.walkingTime, Duration.zero);
    });

    test('edge filter can exclude paths (accessible route)', () {
      final generator = RouteGenerator(buildSampleGraph(blockBC: true));
      final route = generator.generate(
        'A',
        'D',
        edgeFilter: (edge) => edge.isAccessible,
      );
      // B-C is blocked, so it must go A -> C directly, then C -> D.
      expect(route.path.map((n) => n.id).toList(), ['A', 'C', 'D']);
      expect(route.distanceMeters, 350);
    });

    test('closed edges are never used', () {
      final graph = CampusGraph();
      graph.addNode(const GraphNode(id: 'A', latitude: 29, longitude: -95));
      graph.addNode(const GraphNode(id: 'B', latitude: 29, longitude: -95));
      graph.addEdge('A', 'B', distanceMeters: 10, isClosed: true);
      expect(
        () => RouteGenerator(graph).generate('A', 'B'),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.noPathFound)),
      );
    });

    test('unreachable destination throws noPathFound', () {
      expect(
        () => RouteGenerator(buildSampleGraph()).generate('A', 'E'),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.noPathFound)),
      );
    });

    test('unknown start throws unknownStart', () {
      expect(
        () => RouteGenerator(buildSampleGraph()).generate('X', 'A'),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.unknownStart)),
      );
    });

    test('unknown destination throws unknownDestination', () {
      expect(
        () => RouteGenerator(buildSampleGraph()).generate('A', 'X'),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.unknownDestination)),
      );
    });

    test('empty graph throws emptyGraph', () {
      expect(
        () => RouteGenerator(CampusGraph()).generate('A', 'B'),
        throwsA(isA<RouteException>()
            .having((e) => e.error, 'error', RouteError.emptyGraph)),
      );
    });
  });
}
