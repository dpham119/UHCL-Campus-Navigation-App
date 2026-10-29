import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'campus_graph.dart';
import 'distance.dart';
import 'indoor_regions.dart';
import 'graph_node.dart';
import 'nearest_node.dart';

/// Builds the outdoor part of the graph from `campus_graph.json`.
///
/// File format:
/// {"nodes": [["n1", lat, lon], ...], "edges": [["n1", "n2", 1], ...]}
/// The third value of an edge is 1 for accessible, 0 for not (stairs).
/// Edge lengths are calculated from the node coordinates.
CampusGraph parseCampusGraph(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final graph = CampusGraph();

  for (final item in data['nodes'] as List<dynamic>) {
    final node = item as List<dynamic>;
    graph.addNode(
      GraphNode(
        id: node[0] as String,
        latitude: (node[1] as num).toDouble(),
        longitude: (node[2] as num).toDouble(),
      ),
    );
  }

  for (final item in data['edges'] as List<dynamic>) {
    final edge = item as List<dynamic>;
    graph.addEdge(
      edge[0] as String,
      edge[1] as String,
      isAccessible: (edge[2] as num) != 0,
    );
  }

  return graph;
}

NodeKind _kindFromCode(int code) {
  switch (code) {
    case 2:
      return NodeKind.room;
    case 3:
      return NodeKind.stairs;
    case 4:
      return NodeKind.elevator;
    case 5:
      return NodeKind.entrance;
    default:
      return NodeKind.corridor;
  }
}

/// Adds the indoor part (`campus_indoor_graph.json`) to [graph] and joins
/// each building entrance to the nearest outdoor path point (if one is
/// within [entranceLinkMeters]).
///
/// File format:
/// {"buildings": ["601-BAYOU BUILDING", ...],
///  "nodes": [[lat, lon, floor, kind, buildingIndex], ...],
///  "edges": [[nodeA, nodeB, lengthInTenthsOfMeter, accessible], ...]}
/// Kind codes: 1 corridor, 2 room, 3 stairs, 4 elevator, 5 entrance.
/// Indoor node ids are "i<index>".
void addIndoorGraph(
  CampusGraph graph,
  String indoorJson, {
  double entranceLinkMeters = 50,
}) {
  final data = jsonDecode(indoorJson) as Map<String, dynamic>;
  final buildings = (data['buildings'] as List<dynamic>).cast<String>();
  final entrances = <GraphNode>[];

  final nodes = data['nodes'] as List<dynamic>;
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i] as List<dynamic>;
    final node = GraphNode(
      id: 'i$i',
      latitude: (n[0] as num).toDouble(),
      longitude: (n[1] as num).toDouble(),
      floor: (n[2] as num).toInt(),
      kind: _kindFromCode((n[3] as num).toInt()),
      building: buildings[(n[4] as num).toInt()],
    );
    graph.addNode(node);
    if (node.kind == NodeKind.entrance) entrances.add(node);
  }

  for (final item in data['edges'] as List<dynamic>) {
    final e = item as List<dynamic>;

    final fromId = 'i${e[0]}';
    final toId = 'i${e[1]}';

    final fromNode = graph.nodeById(fromId);
    final toNode = graph.nodeById(toId);

    var isAccessible = (e[3] as num) != 0;

    // Never allow stairs in accessibility mode.
    if (fromNode?.kind == NodeKind.stairs || toNode?.kind == NodeKind.stairs) {
      isAccessible = false;
    }

    graph.addEdge(
      fromId,
      toId,
      distanceMeters: (e[2] as num).toDouble() / 10.0,
      isAccessible: isAccessible,
    );
  }

  final regions = IndoorRegions.parse(indoorJson);
  final outdoor = graph.nodes.where((n) => n.kind == NodeKind.outdoor).toList();
  for (final entrance in entrances) {
    final candidates = <NearestNode>[];

    for (final node in outdoor) {
      final d = haversineMeters(
        entrance.latitude,
        entrance.longitude,
        node.latitude,
        node.longitude,
      );

      if (d <= entranceLinkMeters) {
        candidates.add(NearestNode(node, d));
      }
    }

    candidates.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));

    final from = LatLng(entrance.latitude, entrance.longitude);

    var connected = false;

    for (final near in candidates) {
      final to = LatLng(near.node.latitude, near.node.longitude);

      if (regions.segmentCrossesBuilding(from, to)) {
        continue;
      }

      graph.addEdge(
        entrance.id,
        near.node.id,
        distanceMeters: near.distanceMeters,
      );

      debugPrint(
        'Entrance ${entrance.id} connected '
        'to ${near.node.id} '
        '(${near.distanceMeters.toStringAsFixed(1)} m)',
      );

      connected = true;
      break;
    }

    if (!connected) {
      debugPrint(
        'WARNING: Entrance ${entrance.id} '
        'has no outdoor connection.',
      );
    }
  }
}

/// Loads the outdoor and indoor graphs from the app's assets.
Future<CampusGraph> loadCampusGraph({
  String outdoorAsset = 'assets/maps/campus_walkway_graph.json',
  String indoorAsset = 'assets/maps/campus_indoor_graph.json',
}) async {
  final graph = parseCampusGraph(await rootBundle.loadString(outdoorAsset));
  try {
    addIndoorGraph(graph, await rootBundle.loadString(indoorAsset));
  } catch (_) {
    // Indoor data is optional: outdoor routes still work without it.
  }
  return graph;
}
