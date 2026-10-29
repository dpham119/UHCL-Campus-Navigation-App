import 'package:latlong2/latlong.dart';

enum AccessibilityFeatureType { accessibleEntrance, ramp, elevator }

class AccessibilityFeature {
  final String id;
  final AccessibilityFeatureType type;
  final LatLng position;

  final String? building;
  final int? floor;

  const AccessibilityFeature({
    required this.id,
    required this.type,
    required this.position,
    this.building,
    this.floor,
  });
}
