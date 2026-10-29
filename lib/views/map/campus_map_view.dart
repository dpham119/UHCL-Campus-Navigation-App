import 'dart:convert';

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

  LatLng? _currentLocation;
  bool _isLocating = false;

  // User-selected starting point, independent of the GPS marker.
  LatLng? _manualStartLocation;
  bool _isSelectingManualLocation = false;

  List<CampusFeature> _buildings = [];
  List<CampusFeature> _parkingLots = [];
  List<CampusFeature> _firstFloor = [];
  List<CampusFeature> _secondFloor = [];
  List<CampusFeature> _thirdFloor = [];
  List<CampusFeature> _walkways = [];

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

  LatLng _campusCenter = const LatLng(29.5776, -95.1000);

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

  void _generateRoute(CampusFeature start, CampusFeature destination) {
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
      final result = RouteGenerator(graph).generate(
        from.node.id,
        to.node.id,
        edgeFilter: _accessibleOnly ? (edge) => edge.isAccessible : null,
      );

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
          'No accessible route found. Turn off Accessible '
          'Routing to see the regular route.',
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

      final walkways = await _loadGeoJson(
        'assets/maps/campus_walkways.geojson',
        'walkway',
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
        _walkways = walkways;

        if (_buildings.isNotEmpty) {
          _campusCenter = _averageCenter(_buildings);
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
      } else if (featureType == 'walkway') {
        name = 'Campus Walkway';
      } else {
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

  LatLng _averageCenter(List<CampusFeature> features) {
    return _averagePoint(features.map((feature) => feature.center).toList());
  }

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

  List<Polygon> _buildVisiblePolygons() {
    final List<Polygon> polygons = [];
    // Draw the real UHCL ArcGIS sidewalk polygons
    // on the Outdoor Campus layer.
    if (_selectedLayer == 'Outdoor Campus') {
      for (final walkway in _walkways) {
        for (final points in walkway.polygons) {
          polygons.add(
            Polygon(
              points: points,

              // Almost transparent interior.
              color: const Color.fromARGB(
                255,
                90,
                90,
                90,
              ).withValues(alpha: 0.03),

              // Cyan outline similar to ArcGIS.
              borderColor: const Color.fromARGB(255, 124, 124, 124),

              borderStrokeWidth: 2.5,
            ),
          );
        }
      }
    }

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

  List<Marker> _buildLabels() {
    if (!_showLabels) return [];

    final bool outdoor = _selectedLayer == 'Outdoor Campus';

    // Room numbers only appear when zoomed in.
    if (!outdoor && _currentZoom < _roomLabelZoom) {
      return [];
    }

    final List<CampusFeature> labelFeatures = outdoor
        ? _buildings
        : _visibleFeatures
              .where(
                (feature) =>
                    feature.featureType == 'room' && feature.code.isNotEmpty,
              )
              .toList();

    return labelFeatures.map((feature) {
      final String label = outdoor ? feature.name : feature.code;

      return Marker(
        point: feature.center,
        width: outdoor ? 150 : 80,
        height: outdoor ? 42 : 26,
        child: GestureDetector(
          onTap: () => _selectFeature(feature),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
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
                  fontSize: outdoor ? 10 : 9,
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

  /// Opens the building/room search. Called from the home screen's
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

  // This point can later be passed to the routing engine.
  LatLng? get selectedStartingLocation =>
      _manualStartLocation ?? _currentLocation;

  void _setManualStartLocation(LatLng location) {
    setState(() {
      _manualStartLocation = location;
      _isSelectingManualLocation = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Manual starting location selected!'),
        duration: Duration(seconds: 3),
      ),
    );
  }

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
            initialZoom: 16,
            minZoom: 13,
            maxZoom: 20,
            onPositionChanged: (camera, hasGesture) {
              if ((_currentZoom >= _roomLabelZoom) !=
                  (camera.zoom >= _roomLabelZoom)) {
                setState(() {
                  _currentZoom = camera.zoom;
                });
              } else {
                _currentZoom = camera.zoom;
              }
            },
            onTap: (tapPosition, point) {
              if (_isSelectingManualLocation) {
                _setManualStartLocation(point);
              } else {
                _selectFeatureAt(point);
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.uhcl_campus_navigation',
              maxNativeZoom: 19,
            ),
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
            if (_manualStartLocation != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _manualStartLocation!,
                    width: 45,
                    height: 45,
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.green,
                      size: 40,
                    ),
                  ),
                ],
              ),
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
                    _mapController.move(_campusCenter, 16);
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
                  tooltip: 'Set manual starting location',
                  icon: Icon(
                    Icons.add_location_alt,
                    color: _isSelectingManualLocation ? Colors.green : null,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSelectingManualLocation = !_isSelectingManualLocation;
                    });
                    if (_isSelectingManualLocation) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Tap anywhere on the map to select your starting location.',
                          ),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    }
                  },
                ),
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

        if (_route != null)
          Positioned(
            top: 64,
            left: 12,
            right: 60,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildRouteCard(),
            ),
          ),

        if (_selectedFeature != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _buildDetailsCard(),
          ),

        if (!_isLoading && _errorMessage == null && _selectedFeature == null)
          Positioned(
            left: 12,
            bottom: 12,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  'Features: ${_visibleFeatures.length}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
      ],
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
            if (isRoom && feature.name.isNotEmpty)
              Text('Name: ${feature.name}'),
            if (!isRoom && feature.code.isNotEmpty)
              Text('Code: ${feature.code}'),
            if (feature.building.isNotEmpty)
              Text('Building: ${feature.building}'),
            if (feature.floor.isNotEmpty) Text('Floor: ${feature.floor}'),
            if (feature.department.isNotEmpty && feature.department != '-')
              Text('Department: ${feature.department}'),
            if (feature.roomUse.isNotEmpty) Text('Use: ${feature.roomUse}'),
            if (feature.address.isNotEmpty) Text('Address: ${feature.address}'),
            const SizedBox(height: 8),
            if (_routeStart != null)
              Text('Start: ${_featureLabel(_routeStart!)}'),
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

// Search interface for buildings, parking lots, and rooms.
class CampusSearchDelegate extends SearchDelegate<CampusFeature?> {
  final List<CampusFeature> features;

  CampusSearchDelegate(this.features);

  @override
  String get searchFieldLabel => 'Search buildings or room numbers';

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
      return const Center(child: Text('Enter a building name or room number.'));
    }

    final matches = features
        .where((feature) {
          return feature.name.toLowerCase().contains(searchText) ||
              feature.code.toLowerCase().contains(searchText) ||
              feature.building.toLowerCase().contains(searchText);
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

        final String title = feature.featureType == 'room'
            ? 'Room ${feature.code.isNotEmpty ? feature.code : "Unknown"}'
            : feature.name;

        final String subtitle = feature.featureType == 'room'
            ? '${feature.building} • Floor ${feature.floor}'
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
