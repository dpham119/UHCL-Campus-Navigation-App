import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

  List<CampusFeature> _buildings = [];
  List<CampusFeature> _parkingLots = [];
  List<CampusFeature> _firstFloor = [];
  List<CampusFeature> _secondFloor = [];
  List<CampusFeature> _thirdFloor = [];

  CampusFeature? _selectedFeature;

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

      final properties =
          (feature['properties'] as Map<String, dynamic>?) ?? {};

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
        name = _readProperty(
          properties,
          ['BuildingName'],
          'Unnamed Building',
        );

        code = _readProperty(properties, ['BuildingCode'], '');
      } else if (featureType == 'parking') {
        name = _readProperty(
          properties,
          ['Parking_Lot_Name'],
          'Parking Lot',
        );
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
        final intersectionLongitude = a.longitude +
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
      if (feature.polygons.any(
        (polygon) => _pointInPolygon(point, polygon),
      )) {
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
                  color:
                      outdoor ? Colors.teal.shade700 : Colors.purple.shade700,
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

  @override
  Widget build(BuildContext context) {
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
              _selectFeatureAt(point);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.uhcl_campus_navigation',
              maxNativeZoom: 19,
            ),
            PolygonLayer(polygons: _buildVisiblePolygons()),
            MarkerLayer(markers: _buildLabels()),
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
          top: 12,
          left: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          top: 12,
          right: 12,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
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
            if (isRoom && feature.name.isNotEmpty) Text('Name: ${feature.name}'),
            if (!isRoom && feature.code.isNotEmpty) Text('Code: ${feature.code}'),
            if (feature.building.isNotEmpty) Text('Building: ${feature.building}'),
            if (feature.floor.isNotEmpty) Text('Floor: ${feature.floor}'),
            if (feature.department.isNotEmpty && feature.department != '-')
              Text('Department: ${feature.department}'),
            if (feature.roomUse.isNotEmpty) Text('Use: ${feature.roomUse}'),
            if (feature.address.isNotEmpty) Text('Address: ${feature.address}'),
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
      return const Center(
        child: Text('Enter a building name or room number.'),
      );
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
      return const Center(
        child: Text('No matching campus locations found.'),
      );
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
