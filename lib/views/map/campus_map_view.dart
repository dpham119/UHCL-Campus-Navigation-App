import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../routing/campus_graph_loader.dart';
import '../../routing/routing.dart';

// A geographic feature loaded from one of the five GeoJSON files.
class CampusFeature {
  final String name;
  final String code;
  final String address;
  final String building;
  final String floor;
  final String department;
  final String occupant;
  final String roomUse;
  final String featureType;

  final List<List<LatLng>> polygons;
  final LatLng center;

  const CampusFeature({
    required this.name,
    required this.code,
    required this.address,
    required this.building,
    required this.floor,
    required this.department,
    required this.occupant,
    required this.roomUse,
    required this.featureType,
    required this.polygons,
    required this.center,
  });
}

/// The campus map (no Scaffold or AppBar), so it can sit inside another
/// screen such as HomeScreen. Call [CampusMapViewState.openSearch] through
/// a GlobalKey to open the building/room search.
class CampusMapView extends StatefulWidget {
  const CampusMapView({super.key});

  @override
  State<CampusMapView> createState() => CampusMapViewState();
}

class CampusMapViewState extends State<CampusMapView> {
  final MapController _mapController = MapController();

  // Reports typed by users (kept in memory only until there is a database).
  final List<Map<String, String>> _reports = [];

  List<Polygon> _walkwayPolygons = [];

  LatLng? _currentLocation;
  bool _isLocating = false;

  StreamSubscription<Position>? _navigationSubscription;
  bool _isNavigating = false;
  bool _followUser = true;

  // // User-selected starting point, independent of the GPS marker.
  // LatLng? _manualStartLocation;
  // bool _isSelectingManualLocation = false;

  List<CampusFeature> _buildings = [];
  List<CampusFeature> _parkingLots = [];
  List<CampusFeature> _firstFloor = [];
  List<CampusFeature> _secondFloor = [];
  List<CampusFeature> _thirdFloor = [];

  CampusFeature? _selectedFeature;

  // Route generator state.
  CampusGraph? _graph;
  IndoorRegions? _regions;
  CampusFeature? _routeStart;
  CampusFeature? _routeDestination;
  RouteResult? _route;
  List<_RouteRun> _routeRuns = [];
  bool _accessibleOnly = false;

  // If a place is farther than this from the nearest walkway, there is
  // no usable walkway data for it yet.
  static const double _maxSnapMeters = 250;

  // Room nodes sit exactly at the room's center, so they should match.
  static const double _maxRoomSnapMeters = 10;

  // Delta Building center, calculated from campus_buildings.geojson.
  LatLng _campusCenter = const LatLng(29.57775456, -95.10422982);

  String _selectedLayer = 'Outdoor Campus';
  bool _showLabels = true;
  bool _isLoading = true;
  String? _errorMessage;

  double _currentZoom = 16;

  static const double _roomLabelZoom = 18;

  final List<String> _mapLayers = [
    'Outdoor Campus',
    'First Floor',
    'Second Floor',
    'Third Floor',
  ];

  @override
  void initState() {
    super.initState();
    _loadAllLayers();
    _loadGraph();
    _loadWalkways();
  }

  @override
  void dispose() {
    _navigationSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadGraph() async {
    try {
      final graph = await loadCampusGraph();
      IndoorRegions? regions;
      try {
        regions = IndoorRegions.parse(
          await rootBundle.loadString('assets/maps/campus_indoor_graph.json'),
        );
      } catch (_) {
        // Without these, indoor routes just stay a little zig-zagged.
      }
      if (!mounted) return;
      setState(() {
        _graph = graph;
        _regions = regions;
      });
    } catch (_) {
      // Routing stays unavailable, but the map itself still works.
    }
  }

  /// Called by the home screen's Accessible Routing switch.
  void setAccessibleOnly(bool value) {
    setState(() {
      _accessibleOnly = value;
    });

    final start = _routeStart;
    final destination = _routeDestination;
    if (_route != null && start != null && destination != null) {
      _generateRoute(start, destination);
    }
  }

  void _setStart(CampusFeature feature) {
    setState(() {
      _routeStart = feature;
    });
    _showMessage('Start set. Now pick a destination and tap Directions here.');
  }

  void _clearRoute() {
    _stopLiveNavigation();
    setState(() {
      _route = null;
      _routeDestination = null;
      _routeRuns = [];
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _featureLabel(CampusFeature feature) {
    if (feature.featureType == 'room') {
      return 'Room ${feature.code.isNotEmpty ? feature.code : feature.name}';
    }
    return feature.name;
  }

  // 0 = outdoors, 1-3 = building floors. Matches the map layer names.
  int _floorForLayer(String layer) {
    switch (layer) {
      case 'First Floor':
        return 1;
      case 'Second Floor':
        return 2;
      case 'Third Floor':
        return 3;
      default:
        return 0;
    }
  }

  String _layerForFloor(int floor) {
    switch (floor) {
      case 1:
        return 'First Floor';
      case 2:
        return 'Second Floor';
      case 3:
        return 'Third Floor';
      default:
        return 'Outdoor Campus';
    }
  }

  String _floorLabel(int floor) => floor == 0 ? 'Outdoors' : 'Floor $floor';

  /// Floors the route passes through, in the order it first reaches them.
  /// Parts of the route on the same floor (even in different buildings)
  /// share one chip, because the map layer shows them together.
  List<int> _routeFloors() {
    final floors = <int>[];
    for (final run in _routeRuns) {
      if (!floors.contains(run.floor)) floors.add(run.floor);
    }
    return floors;
  }

  void _showFloor(int floor) {
    _changeLayer(_layerForFloor(floor));
    final points = [
      for (final run in _routeRuns)
        if (run.floor == floor) ...run.points,
    ];
    if (points.length >= 2) {
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(56),
          maxZoom: 19,
        ),
      );
    }
  }

  int _featureFloor(CampusFeature feature) {
    if (feature.featureType != 'room') return 0;
    return int.tryParse(feature.floor) ?? 1;
  }

  /// The graph node a feature starts or ends at: the room's own node for
  /// rooms, otherwise the nearest outdoor path point or building entrance.
  NearestNode? _nodeFor(CampusGraph graph, CampusFeature feature) {
    if (feature.featureType == 'room') {
      final floor = _featureFloor(feature);
      final found = graph.nearestNode(
        feature.center.latitude,
        feature.center.longitude,
        where: (node) =>
            node.kind == NodeKind.room &&
            node.floor == floor &&
            node.building == feature.building,
        byAnchor: true,
      );
      if (found != null && found.distanceMeters <= _maxRoomSnapMeters) {
        return found;
      }
      return null;
    }

    final found = graph.nearestNode(
      feature.center.latitude,
      feature.center.longitude,
      where: (node) =>
          node.kind == NodeKind.outdoor || node.kind == NodeKind.entrance,
    );
    if (found != null && found.distanceMeters <= _maxSnapMeters) {
      return found;
    }
    return null;
  }

  /// Splits a route into runs that stay on one floor, so each map layer
  /// can draw its own part. A run starts where the previous one ended so
  /// the lines meet.
  List<_RouteRun> _splitIntoRuns(
    List<GraphNode> path, {
    required bool startIsRoom,
    required bool endIsRoom,
  }) {
    // A building (not a room) as start or end is only a door on the outside,
    // so that end counts as outdoors and gets no floor button of its own.
    int floorAt(int index) {
      final node = path[index];
      if (node.kind == NodeKind.entrance &&
          ((index == 0 && !startIsRoom) ||
              (index == path.length - 1 && !endIsRoom))) {
        return 0;
      }
      return node.floor;
    }

    // Group the nodes by floor first, then straighten each group.
    final groups = <List<GraphNode>>[];
    final groupFloors = <int>[];
    for (var i = 0; i < path.length; i++) {
      final floor = floorAt(i);
      if (groups.isEmpty || groupFloors.last != floor) {
        groups.add(<GraphNode>[]);
        groupFloors.add(floor);
      }
      groups.last.add(path[i]);
    }
    final runs = <_RouteRun>[];
    for (var g = 0; g < groups.length; g++) {
      final nodes = groups[g];
      final points = _regions != null
          ? _regions!.smoothPath(nodes)
          : [for (final n in nodes) LatLng(n.latitude, n.longitude)];
      final run = _RouteRun(groupFloors[g], nodes.first.building, points);
      if (runs.isNotEmpty) {
        // Start where the previous part ended so the lines meet.
        run.points.insert(0, runs.last.points.last);
        runs.last.points.add(run.points[1]);
      }
      runs.add(run);
    }
    return runs;
  }

  /// Every door node of a room (they share the room's center). Other
  /// features have just the one node.
  List<GraphNode> _doorsOf(
    CampusGraph graph,
    CampusFeature feature,
    GraphNode primary,
  ) {
    if (feature.featureType == 'building') {
      final index = _buildings.indexWhere((b) => b.name == feature.name);
      final entrances = entrancesOfBuilding(graph, [
        for (final b in _buildings) b.polygons,
      ], index);
      return entrances.isEmpty ? [primary] : entrances;
    }
    if (feature.featureType != 'room') return [primary];
    final lat = primary.anchorLatitude ?? primary.latitude;
    final lon = primary.anchorLongitude ?? primary.longitude;
    return [
      for (final n in graph.nodes)
        if (n.kind == NodeKind.room &&
            n.floor == primary.floor &&
            n.building == primary.building &&
            ((n.anchorLatitude ?? n.latitude) - lat).abs() < 1e-7 &&
            ((n.anchorLongitude ?? n.longitude) - lon).abs() < 1e-7)
          n,
    ];
  }

  bool _routeEdgeAllowed(
    CampusGraph graph,
    RouteGenerator generator,
    GraphEdge edge, {
    Set<String> avoidInteriorOf = const {},
  }) {
    final fromNode = graph.nodeById(edge.from);
    final toNode = graph.nodeById(edge.to);

    if (fromNode == null || toNode == null) {
      return false;
    }

    // A building used as the start or end is only reached from outside:
    // its hallways, rooms, stairs and elevators are off limits, so the route
    // stops at the entrance instead of walking through to another door.
    bool isInterior(GraphNode node) =>
        node.floor > 0 &&
        node.kind != NodeKind.entrance &&
        avoidInteriorOf.contains(node.building);
    if (isInterior(fromNode) || isInterior(toNode)) {
      return false;
    }

    final touchesStairs =
        fromNode.kind == NodeKind.stairs || toNode.kind == NodeKind.stairs;

    final touchesElevator =
        fromNode.kind == NodeKind.elevator || toNode.kind == NodeKind.elevator;

    if (_accessibleOnly) {
      // ACCESSIBILITY ON:
      // Never allow stairs.
      if (touchesStairs) {
        return false;
      }

      // Keep the accessibility restrictions already implemented
      // by the route generator.
      return generator.accessibleEdgeFilter(edge);
    }

    // ACCESSIBILITY OFF:
    // Never allow elevator routes.
    if (touchesElevator) {
      return false;
    }

    return true;
  }

  void _generateRoute(CampusFeature start, CampusFeature destination) {
    _stopLiveNavigation();
    final graph = _graph;
    if (graph == null) {
      _showMessage('Route data is still loading. Try again in a moment.');
      return;
    }

    final from = _nodeFor(graph, start);
    final to = _nodeFor(graph, destination);

    if (from == null || to == null) {
      _clearRoute();
      _showMessage('No walkway data near that location yet.');
      return;
    }

    if (from.node.id == to.node.id) {
      _clearRoute();
      _showMessage(
        'These two places share the same walkway point, so there '
        'is nothing to route. Pick more specific places.',
      );
      return;
    }

    try {
      final generator = RouteGenerator(graph);
      final startDoors = _doorsOf(graph, start, from.node);
      final endDoors = _doorsOf(graph, destination, to.node);

      // Buildings that hold a room endpoint stay open; a building used as
      // a whole (start or destination) is kept to its entrances.
      final roomBuildings = <String>{
        if (start.featureType == 'room') from.node.building,
        if (destination.featureType == 'room') to.node.building,
      };
      final avoidInteriorOf = <String>{
        for (final entry in [
          if (start.featureType == 'building') ...startDoors,
          if (destination.featureType == 'building') ...endDoors,
        ])
          if (entry.kind == NodeKind.entrance &&
              !roomBuildings.contains(entry.building))
            entry.building,
      };

      // A start or end with more than one door (a room, or a building with
      // several entrances): try every pair, keep the shortest.
      RouteResult? best;
      RouteException? lastError;
      for (final a in startDoors) {
        for (final b in endDoors) {
          if (a.id == b.id) continue;
          try {
            final candidate = generator.generate(
              a.id,
              b.id,
              edgeFilter: (edge) => _routeEdgeAllowed(
                graph,
                generator,
                edge,
                avoidInteriorOf: avoidInteriorOf,
              ),
            );
            if (best == null ||
                candidate.distanceMeters < best.distanceMeters) {
              best = candidate;
            }
          } on RouteException catch (error) {
            lastError = error;
          }
        }
      }
      final result = best;
      if (result == null) {
        throw lastError ??
            const RouteException(RouteError.noPathFound, 'No route found.');
      }

      final runs = _splitIntoRuns(
        result.path,
        startIsRoom: start.featureType == 'room',
        endIsRoom: destination.featureType == 'room',
      );

      final allPoints = runs.expand((run) => run.points).toList();

      setState(() {
        _routeStart = start;
        _routeDestination = destination;
        _route = result;
        _routeRuns = runs;
        _selectedLayer = _layerForFloor(runs.first.floor);
        _selectedFeature = null;
      });

      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: allPoints,
          padding: const EdgeInsets.all(56),
        ),
      );
    } on RouteException catch (error) {
      _clearRoute();
      if (error.error == RouteError.noPathFound && _accessibleOnly) {
        _showMessage(
          'No accessible route is available between these locations.',
        );
      } else {
        _showMessage(error.message);
      }
    }
  }

  Future<void> _loadAllLayers() async {
    try {
      final buildings = await _loadGeoJson(
        'assets/maps/campus_buildings.geojson',
        'building',
      );

      final parking = await _loadGeoJson(
        'assets/maps/campus_parking.geojson',
        'parking',
      );

      final floor1 = await _loadGeoJson(
        'assets/maps/campus_first_floor.geojson',
        'room',
      );

      final floor2 = await _loadGeoJson(
        'assets/maps/campus_second_floor.geojson',
        'room',
      );

      final floor3 = await _loadGeoJson(
        'assets/maps/campus_third_floor.geojson',
        'room',
      );

      if (!mounted) return;

      setState(() {
        _buildings = buildings;
        _parkingLots = parking;
        _firstFloor = floor1;
        _secondFloor = floor2;
        _thirdFloor = floor3;

        // if (_buildings.isNotEmpty) {
        //   _campusCenter = _averageCenter(_buildings);
        // }
        // Keep the Center Map action focused on Delta Building.
        for (final building in _buildings) {
          if (building.code.toUpperCase() == 'DELTA' ||
              building.name.toLowerCase().contains('delta building')) {
            _campusCenter = building.center;
            break;
          }
        }

        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading campus data:\n$error';
      });
    }
  }

  Future<List<CampusFeature>> _loadGeoJson(
    String assetPath,
    String featureType,
  ) async {
    final jsonString = await rootBundle.loadString(assetPath);

    final Map<String, dynamic> geoJson =
        jsonDecode(jsonString) as Map<String, dynamic>;

    final List<dynamic> features = geoJson['features'] as List<dynamic>;

    final List<CampusFeature> result = [];

    for (final item in features) {
      final Map<String, dynamic> feature = item as Map<String, dynamic>;

      final geometry = feature['geometry'] as Map<String, dynamic>?;

      if (geometry == null) continue;

      final properties = (feature['properties'] as Map<String, dynamic>?) ?? {};

      final geometryType = geometry['type'] as String? ?? '';
      final coordinates = geometry['coordinates'];

      if (coordinates == null) continue;

      final List<List<LatLng>> polygons = [];

      if (geometryType == 'Polygon') {
        final points = _readOuterRing(coordinates as List<dynamic>);

        if (points.length >= 3) {
          polygons.add(points);
        }
      } else if (geometryType == 'MultiPolygon') {
        for (final polygon in coordinates as List<dynamic>) {
          final points = _readOuterRing(polygon as List<dynamic>);

          if (points.length >= 3) {
            polygons.add(points);
          }
        }
      }

      if (polygons.isEmpty) continue;

      final allPoints = polygons.expand((p) => p).toList();
      final center = _averagePoint(allPoints);

      String name;
      String code = '';

      if (featureType == 'building') {
        name = _readProperty(properties, ['BuildingName'], 'Unnamed Building');

        code = _readProperty(properties, ['BuildingCode'], '');
      } else if (featureType == 'parking') {
        name = _readProperty(properties, ['Parking_Lot_Name'], 'Parking Lot');
      } else {
        // Actual room-number field from the floor files.
        code = _readProperty(properties, ['Room_Number'], '');

        name = _readProperty(properties, ['Room_Name'], '');

        if (name.isEmpty) {
          name = code.isNotEmpty ? 'Room $code' : 'Unnamed Room';
        }
      }

      result.add(
        CampusFeature(
          name: name,
          code: code,
          address: _readProperty(properties, ['Address'], ''),
          building: _readProperty(properties, ['Building', 'BuildingName'], ''),
          floor: _readProperty(properties, ['Floor'], ''),
          department: _readProperty(properties, ['Department'], ''),
          occupant: _readProperty(properties, ['Occupant'], ''),
          roomUse: _readProperty(properties, ['Use_'], ''),
          featureType: featureType,
          polygons: polygons,
          center: center,
        ),
      );
    }

    return result;
  }

  String _readProperty(
    Map<String, dynamic> properties,
    List<String> keys,
    String fallback,
  ) {
    for (final key in keys) {
      final value = properties[key];

      if (value != null &&
          value.toString().trim().isNotEmpty &&
          value.toString().trim().toLowerCase() != 'null') {
        return value.toString().trim();
      }
    }

    return fallback;
  }

  List<LatLng> _readOuterRing(List<dynamic> polygonCoordinates) {
    if (polygonCoordinates.isEmpty) return [];

    final outerRing = polygonCoordinates.first;

    if (outerRing is! List<dynamic>) return [];

    final List<LatLng> points = [];

    for (final coordinate in outerRing) {
      if (coordinate is! List<dynamic> || coordinate.length < 2) {
        continue;
      }

      final longitude = (coordinate[0] as num).toDouble();
      final latitude = (coordinate[1] as num).toDouble();

      if (longitude < -180 ||
          longitude > 180 ||
          latitude < -90 ||
          latitude > 90) {
        continue;
      }

      points.add(LatLng(latitude, longitude));
    }

    return points;
  }

  LatLng _averagePoint(List<LatLng> points) {
    if (points.isEmpty) return _campusCenter;

    double lat = 0;
    double lon = 0;

    for (final point in points) {
      lat += point.latitude;
      lon += point.longitude;
    }

    return LatLng(lat / points.length, lon / points.length);
  }

  // LatLng _averageCenter(List<CampusFeature> features) {
  //   return _averagePoint(features.map((feature) => feature.center).toList());
  // }

  List<CampusFeature> get _visibleFeatures {
    switch (_selectedLayer) {
      case 'First Floor':
        return _firstFloor;
      case 'Second Floor':
        return _secondFloor;
      case 'Third Floor':
        return _thirdFloor;
      default:
        return [..._parkingLots, ..._buildings];
    }
  }

  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;

    bool inside = false;
    int j = polygon.length - 1;

    for (int i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[j];

      if ((a.latitude > point.latitude) != (b.latitude > point.latitude)) {
        final intersectionLongitude =
            a.longitude +
            (point.latitude - a.latitude) *
                (b.longitude - a.longitude) /
                (b.latitude - a.latitude);

        if (point.longitude < intersectionLongitude) {
          inside = !inside;
        }
      }

      j = i;
    }

    return inside;
  }

  void _selectFeatureAt(LatLng point) {
    CampusFeature? selected;

    for (final feature in _visibleFeatures.reversed) {
      if (feature.polygons.any((polygon) => _pointInPolygon(point, polygon))) {
        selected = feature;
        break;
      }
    }

    setState(() {
      _selectedFeature = selected;
    });
  }

  void _selectFeature(CampusFeature feature) {
    setState(() {
      _selectedFeature = feature;
    });

    _mapController.move(
      feature.center,
      feature.featureType == 'room' ? 19 : 18,
    );
  }

  void _changeLayer(String layer) {
    setState(() {
      _selectedLayer = layer;
      _selectedFeature = null;
    });
  }

  List<Polygon> _buildWalkwayPolygons() {
    if (_selectedLayer != 'Outdoor Campus') {
      return [];
    }

    return _walkwayPolygons;
  }

  List<Polygon> _buildVisiblePolygons() {
    final List<Polygon> polygons = [];

    for (final feature in _visibleFeatures) {
      final bool selected = identical(feature, _selectedFeature);

      Color fillColor;
      Color borderColor;

      if (selected) {
        fillColor = Colors.orange.withValues(alpha: 0.65);
        borderColor = Colors.deepOrange;
      } else if (feature.featureType == 'building') {
        fillColor = Colors.teal.withValues(alpha: 0.35);
        borderColor = Colors.teal.shade800;
      } else if (feature.featureType == 'parking') {
        fillColor = Colors.blue.withValues(alpha: 0.30);
        borderColor = Colors.blue.shade800;
      } else {
        fillColor = Colors.purple.withValues(alpha: 0.25);
        borderColor = Colors.purple.shade700;
      }

      for (final points in feature.polygons) {
        polygons.add(
          Polygon(
            points: points,
            color: fillColor,
            borderColor: borderColor,
            borderStrokeWidth: selected ? 3 : 1.5,
          ),
        );
      }
    }

    return polygons;
  }

  /// Rough size of a feature (its bounding box), so bigger rooms get their
  /// label placed first.
  final Map<CampusFeature, double> _areaCache = {};

  double _featureArea(CampusFeature feature) =>
      _areaCache.putIfAbsent(feature, () => _computeArea(feature));

  double _computeArea(CampusFeature feature) {
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    for (final ring in feature.polygons) {
      for (final p in ring) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
    }
    if (minLat > maxLat) return 0;
    return (maxLat - minLat) * (maxLon - minLon);
  }

  List<Marker> _buildLabels() {
    if (!_showLabels) return [];

    final bool outdoor = _selectedLayer == 'Outdoor Campus';

    // Room numbers only appear when zoomed in.
    if (!outdoor && _currentZoom < _roomLabelZoom) {
      return [];
    }
    // Reduce label clutter at lower zoom levels.
    if (outdoor && _currentZoom < 17) return [];

    final List<CampusFeature> labelFeatures = outdoor
        ? _buildings
        : _visibleFeatures
              .where(
                (feature) =>
                    feature.featureType == 'room' && feature.code.isNotEmpty,
              )
              .toList();

    // Labels grow with the zoom and are thinned out on screen: a label is
    // only drawn if it would not cover one that is already placed.
    final double zoom = _currentZoom;
    final double metersPerPixel =
        156543.03392 *
        math.cos(_campusCenter.latitude * math.pi / 180) /
        math.pow(2, zoom);
    final double fontSize = outdoor
        ? (9.0 + (zoom - 17) * 1.5).clamp(9.0, 13.0).toDouble()
        : (zoom >= 19.5
              ? 8.5
              : (6.0 + (zoom - 18) * 2.0).clamp(6.0, 11.5).toDouble());
    final double mPerDegLat = 110574.0;
    final double mPerDegLon =
        111320.0 * math.cos(_campusCenter.latitude * math.pi / 180);

    final ordered = <CampusFeature>[
      if (_selectedFeature != null && labelFeatures.contains(_selectedFeature))
        _selectedFeature!,
      ...(labelFeatures.where((f) => !identical(f, _selectedFeature)).toList()
        ..sort((a, b) => _featureArea(b).compareTo(_featureArea(a)))),
    ];
    // Fully zoomed in, labels may touch a little so every room shows.
    final double overlapAllowed = zoom >= 20
        ? 0.5
        : zoom >= 19.5
        ? 0.75
        : 1.0;

    final placed = <_LabelBox>[];
    final visibleLabels = <CampusFeature>[];
    final sizes = <CampusFeature, Size>{};
    for (final feature in ordered) {
      final String label = outdoor ? feature.name : feature.code;
      final double width = outdoor
          ? math.min(150.0, label.length * fontSize * 0.6 + 12)
          : label.length * fontSize * 0.62 + 10;
      final double height = fontSize * (outdoor ? 2.0 : 1.0) + 8;
      final double cx = feature.center.longitude * mPerDegLon / metersPerPixel;
      final double cy = feature.center.latitude * mPerDegLat / metersPerPixel;
      final box = _LabelBox(cx, cy, width, height);
      final clash = placed.any((p) => p.overlaps(box, overlapAllowed));
      if (!clash) {
        placed.add(box);
        visibleLabels.add(feature);
        sizes[feature] = Size(width, height);
      }
    }

    return visibleLabels.map((feature) {
      final String label = outdoor ? feature.name : feature.code;
      final size = sizes[feature]!;

      return Marker(
        point: feature.center,
        width: size.width,
        height: size.height,
        child: GestureDetector(
          onTap: () => _selectFeature(feature),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
              decoration: BoxDecoration(
                color: identical(feature, _selectedFeature)
                    ? Colors.orange.shade100
                    : Colors.white.withValues(alpha: 0.90),
                border: Border.all(
                  color: outdoor
                      ? Colors.teal.shade700
                      : Colors.purple.shade700,
                  width: 0.8,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: outdoor ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  /// Opens the building/room/faculty search. Called from the home screen's
  /// search bar.
  void openSearch() {
    if (_isLoading) return;

    final allFeatures = [
      ..._buildings,
      ..._parkingLots,
      ..._firstFloor,
      ..._secondFloor,
      ..._thirdFloor,
    ];

    showSearch<CampusFeature?>(
      context: context,
      delegate: CampusSearchDelegate(allFeatures),
    ).then((feature) {
      if (!mounted || feature == null) return;

      String layer = 'Outdoor Campus';

      if (_firstFloor.contains(feature)) {
        layer = 'First Floor';
      } else if (_secondFloor.contains(feature)) {
        layer = 'Second Floor';
      } else if (_thirdFloor.contains(feature)) {
        layer = 'Third Floor';
      }

      setState(() {
        _selectedLayer = layer;
        _selectedFeature = feature;
      });

      _mapController.move(
        feature.center,
        feature.featureType == 'room' ? 19 : 18,
      );
    });
  }

  Future<void> _getCurrentLocation() async {
    if (_isLocating) return;

    setState(() {
      _isLocating = true;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission denied.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;

      final location = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentLocation = location;
      });
      _mapController.move(location, 18);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Current location found!')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('GPS error: $error'),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLocating = false;
        });
      }
    }
  }

  /// Starts foreground GPS tracking only while a route is selected.
  Future<void> _startLiveNavigation() async {
    if (_route == null || _isNavigating) return;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage('Enable location services to start navigation.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showMessage('Location permission is required for live navigation.');
        return;
      }

      await _navigationSubscription?.cancel();
      if (!mounted || _route == null) return;

      setState(() {
        _isNavigating = true;
        _followUser = true;
        _selectedLayer = 'Outdoor Campus';
      });

      _navigationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 3,
            ),
          ).listen(
            (position) {
              if (!mounted || !_isNavigating) return;
              final location = LatLng(position.latitude, position.longitude);
              setState(() => _currentLocation = location);
              if (_followUser) {
                _mapController.move(location, _mapController.camera.zoom);
              }
            },
            onError: (Object error) {
              if (!mounted) return;
              _stopLiveNavigation();
              _showMessage('Live GPS error: $error');
            },
          );
    } catch (error) {
      if (!mounted) return;
      _stopLiveNavigation();
      _showMessage('Unable to start navigation: $error');
    }
  }

  void _stopLiveNavigation() {
    final subscription = _navigationSubscription;
    _navigationSubscription = null;
    subscription?.cancel();
    if (!mounted) return;
    if (_isNavigating || _followUser) {
      setState(() {
        _isNavigating = false;
        _followUser = false;
      });
    }
  }

  Future<void> _loadWalkways() async {
    try {
      final jsonString = await rootBundle.loadString(
        'assets/maps/campus_walkways.geojson',
      );

      final data = jsonDecode(jsonString) as Map<String, dynamic>;

      final features = data['features'] as List<dynamic>? ?? [];

      final polygons = <Polygon>[];

      for (final rawFeature in features) {
        if (rawFeature is! Map<String, dynamic>) {
          continue;
        }

        final geometry = rawFeature['geometry'] as Map<String, dynamic>?;

        if (geometry == null) {
          continue;
        }

        final type = geometry['type']?.toString();
        final coordinates = geometry['coordinates'];

        if (coordinates is! List) {
          continue;
        }

        if (type == 'Polygon') {
          final polygon = _createWalkwayPolygon(coordinates);

          if (polygon != null) {
            polygons.add(polygon);
          }
        } else if (type == 'MultiPolygon') {
          for (final rawPolygon in coordinates) {
            if (rawPolygon is! List) {
              continue;
            }

            final polygon = _createWalkwayPolygon(rawPolygon);

            if (polygon != null) {
              polygons.add(polygon);
            }
          }
        }
      }

      if (!mounted) return;

      setState(() {
        _walkwayPolygons = polygons;
      });

      debugPrint('Loaded ${polygons.length} outdoor walkway polygons');
    } catch (error) {
      debugPrint('Error loading outdoor walkways: $error');
    }
  }

  Polygon? _createWalkwayPolygon(List<dynamic> polygonCoordinates) {
    if (polygonCoordinates.isEmpty) {
      return null;
    }

    // Ring 0 = outer boundary of the sidewalk area.
    final outerRing = _readWalkwayRing(polygonCoordinates.first);

    if (outerRing.length < 3) {
      return null;
    }

    // Rings 1+ = holes inside the polygon.
    //
    // These holes are extremely important for the UHCL sidewalk
    // data. Without them, the entire area inside a large sidewalk
    // boundary gets filled.
    final holes = <List<LatLng>>[];

    for (var i = 1; i < polygonCoordinates.length; i++) {
      final hole = _readWalkwayRing(polygonCoordinates[i]);

      if (hole.length >= 3) {
        holes.add(hole);
      }
    }

    return Polygon(
      points: outerRing,

      // These remove the non-sidewalk areas from the fill.
      holePointsList: holes.isEmpty ? null : holes,

      // Your temporary red shade.
      color: const Color.fromARGB(255, 196, 194, 194).withValues(alpha: 0.28),

      borderColor: Colors.grey.shade600,
      borderStrokeWidth: 1.5,
    );
  }

  List<LatLng> _readWalkwayRing(dynamic rawRing) {
    if (rawRing is! List) {
      return [];
    }

    final points = <LatLng>[];

    for (final rawPoint in rawRing) {
      if (rawPoint is! List || rawPoint.length < 2) {
        continue;
      }

      final longitude = rawPoint[0];
      final latitude = rawPoint[1];

      if (longitude is! num || latitude is! num) {
        continue;
      }

      points.add(LatLng(latitude.toDouble(), longitude.toDouble()));
    }

    return points;
  }

  // // This point can later be passed to the routing engine.
  // LatLng? get selectedStartingLocation =>
  //     _manualStartLocation ?? _currentLocation;

  // void _setManualStartLocation(LatLng location) {
  //   setState(() {
  //     _manualStartLocation = location;
  //     _isSelectingManualLocation = false;
  //   });

  //   ScaffoldMessenger.of(context).showSnackBar(
  //     const SnackBar(
  //       content: Text('Manual starting location selected!'),
  //       duration: Duration(seconds: 3),
  //     ),
  //   );
  // }

  @override
  Widget build(BuildContext context) {
    final double safeTop = MediaQuery.paddingOf(context).top;
    final double controlsTop = safeTop + 78;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _campusCenter,
            initialZoom: 18,
            minZoom: 13,
            maxZoom: 20,
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && _isNavigating && _followUser) {
                setState(() => _followUser = false);
              }
              if ((_currentZoom >= _roomLabelZoom) !=
                      (camera.zoom >= _roomLabelZoom) ||
                  (_currentZoom * 2).floor() != (camera.zoom * 2).floor()) {
                setState(() {
                  _currentZoom = camera.zoom;
                });
              } else {
                _currentZoom = camera.zoom;
              }
            },
            onTap: (tapPosition, point) {
              // if (_isSelectingManualLocation) {
              //   _setManualStartLocation(point);
              // } else {
              //   _selectFeatureAt(point);
              // }
              _selectFeatureAt(point);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.uhcl_campus_navigation',
              maxNativeZoom: 19,
            ),
            PolygonLayer(polygons: _buildWalkwayPolygons()),

            PolygonLayer(polygons: _buildVisiblePolygons()),
            if (_routeRuns.isNotEmpty)
              PolylineLayer(
                polylines: [
                  for (final run in _routeRuns)
                    if (run.floor == _floorForLayer(_selectedLayer))
                      Polyline(
                        points: run.points,
                        strokeWidth: 5,
                        color: Colors.blue,
                        borderStrokeWidth: 2,
                        borderColor: Colors.white,
                      ),
                ],
              ),
            MarkerLayer(markers: _buildRouteMarkers()),
            MarkerLayer(markers: _buildLabels()),
            if (_currentLocation != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentLocation!,
                    width: 40,
                    height: 40,
                    child: const Icon(
                      Icons.my_location,
                      color: Colors.blue,
                      size: 32,
                    ),
                  ),
                ],
              ),
            // if (_manualStartLocation != null)
            //   MarkerLayer(
            //     markers: [
            //       Marker(
            //         point: _manualStartLocation!,
            //         width: 45,
            //         height: 45,
            //         child: const Icon(
            //           Icons.location_on,
            //           color: Colors.green,
            //           size: 40,
            //         ),
            //       ),
            //     ],
            //   ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  'OpenStreetMap contributors',
                  onTap: () {},
                ),
              ],
            ),
          ],
        ),

        // Current layer name (top left).
        Positioned(
          top: controlsTop,
          left: 16,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.layers, size: 18),
                  const SizedBox(width: 8),
                  Text(_selectedLayer),
                ],
              ),
            ),
          ),
        ),

        // Map controls (top right): layers, labels, center.
        Positioned(
          top: controlsTop,
          right: 16,
          child: Card(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Select map layer',
                  icon: const Icon(Icons.layers),
                  onSelected: _changeLayer,
                  itemBuilder: (context) {
                    return _mapLayers.map((layer) {
                      return PopupMenuItem<String>(
                        value: layer,
                        child: Text(layer),
                      );
                    }).toList();
                  },
                ),
                IconButton(
                  tooltip: 'Toggle labels',
                  icon: Icon(_showLabels ? Icons.label : Icons.label_off),
                  onPressed: () {
                    setState(() {
                      _showLabels = !_showLabels;
                    });
                  },
                ),
                IconButton(
                  tooltip: 'Center map',
                  icon: const Icon(Icons.center_focus_strong),
                  onPressed: () {
                    _mapController.move(_campusCenter, 18);
                  },
                ),
                IconButton(
                  tooltip: 'My current location',
                  icon: _isLocating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location),
                  onPressed: _isLocating ? null : _getCurrentLocation,
                ),
                IconButton(
                  tooltip: 'Report an issue',
                  icon: const Icon(Icons.report_problem_outlined),
                  onPressed: _openReportDialog,
                ),
                // IconButton(
                //   tooltip: 'Set manual starting location',
                //   icon: Icon(
                //     Icons.add_location_alt,
                //     color: _isSelectingManualLocation ? Colors.green : null,
                //   ),
                //   onPressed: () {
                //     setState(() {
                //       _isSelectingManualLocation = !_isSelectingManualLocation;
                //     });
                //     if (_isSelectingManualLocation) {
                //       ScaffoldMessenger.of(context).showSnackBar(
                //         const SnackBar(
                //           content: Text(
                //             'Tap anywhere on the map to select your starting location.',
                //           ),
                //           duration: Duration(seconds: 3),
                //         ),
                //       );
                //     }
                //   },
                // ),
              ],
            ),
          ),
        ),

        if (_isLoading)
          const Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Loading campus data...'),
                  ],
                ),
              ),
            ),
          ),

        if (_errorMessage != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_errorMessage!),
              ),
            ),
          ),

        // Show route summary at the bottom, not over the search/layer controls.
        // The selected-feature details card takes priority when open.
        if (_route != null && _selectedFeature == null)
          Positioned(
            //top: 64,
            left: 12,
            //right: 60,
            // child: Align(
            //   alignment: Alignment.centerLeft,
            //   child: _buildRouteCard(),
            // ),
            right: 12,
            bottom: 12,
            child: _buildRouteCard(),
          ),

        if (_selectedFeature != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _buildDetailsCard(),
          ),
      ],
    );
  }

  Future<void> _openReportDialog() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ReportDialog(location: _selectedLayer),
    );
    if (result == null || !mounted) return;
    setState(() => _reports.add(result));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Report submitted. Thank you!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Marker _routeMarker(LatLng point, IconData icon, Color color, double size) {
    return Marker(
      point: point,
      width: size + 4,
      height: size + 4,
      child: Icon(icon, color: color, size: size),
    );
  }

  /// Start and end markers sit where the route really starts and ends (the
  /// room, or the nearest path point / entrance for a building).
  List<Marker> _buildRouteMarkers() {
    final markers = <Marker>[];
    final layerFloor = _floorForLayer(_selectedLayer);

    if (_routeRuns.isNotEmpty) {
      final first = _routeRuns.first;
      final last = _routeRuns.last;
      if (first.floor == layerFloor) {
        markers.add(
          _routeMarker(first.points.first, Icons.trip_origin, Colors.green, 32),
        );
      }
      if (last.floor == layerFloor) {
        markers.add(
          _routeMarker(last.points.last, Icons.place, Colors.red, 36),
        );
      }
    } else if (_routeStart != null &&
        _featureFloor(_routeStart!) == layerFloor) {
      markers.add(
        _routeMarker(_routeStart!.center, Icons.trip_origin, Colors.green, 32),
      );
    }
    return markers;
  }

  Widget _buildRouteCard() {
    final route = _route!;
    final meters = route.distanceMeters.round();
    final rawMinutes = (route.walkingTime.inSeconds / 60).ceil();
    final minutes = rawMinutes < 1 ? 1 : rawMinutes;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.directions_walk, color: Colors.blue),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '$meters m \u2022 $minutes min'
                    '${_accessibleOnly ? ' \u2022 Accessible' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear route',
                  onPressed: _clearRoute,
                ),
              ],
            ),
            if (_routeFloors().length > 1)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final floor in _routeFloors())
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(_floorLabel(floor)),
                        onPressed: () => _showFloor(floor),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isNavigating
                    ? _stopLiveNavigation
                    : _startLiveNavigation,
                icon: Icon(
                  _isNavigating ? Icons.stop_circle : Icons.navigation,
                ),
                label: Text(
                  _isNavigating ? 'Stop Navigation' : 'Start Navigation',
                ),
              ),
            ),
            if (_isNavigating && !_followUser)
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _followUser = true;
                    _selectedLayer = 'Outdoor Campus';
                  });
                  if (_currentLocation != null) {
                    _mapController.move(_currentLocation!, 19);
                  }
                },
                icon: const Icon(Icons.my_location),
                label: const Text('Follow my location'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsCard() {
    final feature = _selectedFeature!;

    final bool isRoom = feature.featureType == 'room';

    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isRoom ? Icons.meeting_room : Icons.location_on,
                  color: Colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isRoom
                        ? 'Room ${feature.code.isNotEmpty ? feature.code : "Unknown"}'
                        : feature.name,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectedFeature = null;
                    });
                  },
                ),
              ],
            ),
            if (isRoom) ...[
              Text(
                'Building: ${feature.building.isNotEmpty ? feature.building : "Not available"}',
              ),
              Text(
                'Floor: ${feature.floor.isNotEmpty ? feature.floor : "Not available"}',
              ),
              Text(
                'Faculty / Occupant: ${feature.occupant.isNotEmpty && feature.occupant != "-" ? feature.occupant : "Not listed"}',
              ),
            ] else ...[
              if (feature.code.isNotEmpty) Text('Code: ${feature.code}'),
              if (feature.building.isNotEmpty)
                Text('Building: ${feature.building}'),
              if (feature.floor.isNotEmpty) Text('Floor: ${feature.floor}'),
              if (feature.department.isNotEmpty && feature.department != '-')
                Text('Department: ${feature.department}'),
              if (feature.roomUse.isNotEmpty) Text('Use: ${feature.roomUse}'),
              if (feature.address.isNotEmpty)
                Text('Address: ${feature.address}'),
              if (_routeStart != null)
                Text('Start: ${_featureLabel(_routeStart!)}'),
            ],
            const SizedBox(height: 8),
            // if (_routeStart != null)
            //   Text('Start: ${_featureLabel(_routeStart!)}'),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _setStart(feature),
                  icon: const Icon(Icons.trip_origin),
                  label: const Text('Set as start'),
                ),
                FilledButton.icon(
                  onPressed:
                      _routeStart == null || identical(_routeStart, feature)
                      ? null
                      : () => _generateRoute(_routeStart!, feature),
                  icon: const Icon(Icons.directions_walk),
                  label: const Text('Directions here'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Search interface for buildings, room numbers, faculty/occupants, and departments.
class CampusSearchDelegate extends SearchDelegate<CampusFeature?> {
  final List<CampusFeature> features;

  CampusSearchDelegate(this.features);

  @override
  //String get searchFieldLabel => 'Search buildings or room numbers';
  String get searchFieldLabel => 'Search buildings, rooms, or faculty';
  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildMatches();
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return _buildMatches();
  }

  Widget _buildMatches() {
    final searchText = query.trim().toLowerCase();

    if (searchText.isEmpty) {
      //return const Center(child: Text('Enter a building name or room number.'));
      return const Center(
        child: Text('Search a building, room number, or faculty name.'),
      );
    }

    final matches = features
        .where((feature) {
          return feature.name.toLowerCase().contains(searchText) ||
              feature.code.toLowerCase().contains(searchText) ||
              //feature.building.toLowerCase().contains(searchText);
              feature.building.toLowerCase().contains(searchText) ||
              feature.occupant.toLowerCase().contains(searchText) ||
              feature.department.toLowerCase().contains(searchText);
        })
        .take(100)
        .toList();

    if (matches.isEmpty) {
      return const Center(child: Text('No matching campus locations found.'));
    }

    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final feature = matches[index];

        // final String title = feature.featureType == 'room'
        //     ? 'Room ${feature.code.isNotEmpty ? feature.code : "Unknown"}'
        //     : feature.name;
        final bool facultyMatch =
            feature.featureType == 'room' &&
            feature.occupant.isNotEmpty &&
            feature.occupant.toLowerCase().contains(searchText);

        final String title = facultyMatch
            ? feature.occupant
            : feature.featureType == 'room'
            ? 'Room ${feature.code.isNotEmpty ? feature.code : "Unknown"}'
            : feature.name;

        final String subtitle = feature.featureType == 'room'
            // ? '${feature.building} • Floor ${feature.floor}'
            ? '${feature.building} • Floor ${feature.floor} • Room ${feature.code}'
                  '${feature.occupant.isNotEmpty && !facultyMatch ? ' • ${feature.occupant}' : ''}'
            : feature.featureType == 'parking'
            ? 'Parking Lot'
            : 'Campus Building';

        return ListTile(
          leading: Icon(
            feature.featureType == 'room'
                ? Icons.meeting_room
                : feature.featureType == 'parking'
                ? Icons.local_parking
                : Icons.apartment,
          ),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: () {
            close(context, feature);
          },
        );
      },
    );
  }
}

// One stretch of a route that stays on a single floor (0 = outdoors).
class _RouteRun {
  final int floor;
  final String building; // empty outdoors
  final List<LatLng> points;

  _RouteRun(this.floor, this.building, this.points);
}

/// A label's rectangle in screen pixels, used to keep labels from overlapping.
class _LabelBox {
  final double cx;
  final double cy;
  final double width;
  final double height;

  const _LabelBox(this.cx, this.cy, this.width, this.height);

  bool overlaps(_LabelBox other, double factor) {
    return (cx - other.cx).abs() < (width + other.width) / 2 * factor + 1 &&
        (cy - other.cy).abs() < (height + other.height) / 2 * factor + 1;
  }
}

/// Small form for reporting issues such as construction or an elevator that
/// is out of service. Pops with {type, text, location} on submit.
class _ReportDialog extends StatefulWidget {
  final String location;
  const _ReportDialog({required this.location});

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const List<String> _types = [
    'Construction',
    'Elevator out of service',
    'Closed path or door',
    'Other',
  ];

  final TextEditingController _controller = TextEditingController();
  String _type = _types.first;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Report an issue'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: _types
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Describe the issue',
                hintText: 'e.g. Elevator in Delta is out of service',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 4),
            Text(
              'Area: ${widget.location}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSubmit
              ? () => Navigator.of(context).pop({
                  'type': _type,
                  'text': _controller.text.trim(),
                  'location': widget.location,
                  'time': DateTime.now().toIso8601String(),
                })
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
