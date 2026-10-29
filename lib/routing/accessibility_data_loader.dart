import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'accessibility_feature.dart';

class AccessibilityDataLoader {
  Future<List<AccessibilityFeature>> load(String assetPath) async {
    final jsonString = await rootBundle.loadString(assetPath);

    final data = jsonDecode(jsonString) as Map<String, dynamic>;

    final features = data['features'] as List<dynamic>? ?? [];

    final results = <AccessibilityFeature>[];

    for (final feature in features) {
      if (feature is! Map<String, dynamic>) {
        continue;
      }

      final properties = feature['properties'] as Map<String, dynamic>?;

      final geometry = feature['geometry'] as Map<String, dynamic>?;

      if (properties == null || geometry == null) {
        continue;
      }

      if (geometry['type'] != 'Point') {
        continue;
      }

      final coordinates = geometry['coordinates'] as List<dynamic>?;

      if (coordinates == null || coordinates.length < 2) {
        continue;
      }

      final longitude = (coordinates[0] as num).toDouble();

      final latitude = (coordinates[1] as num).toDouble();

      final typeString = properties['type']?.toString();

      final type = _parseType(typeString);

      if (type == null) {
        continue;
      }

      results.add(
        AccessibilityFeature(
          id: properties['id']?.toString() ?? 'accessibility_${results.length}',
          type: type,
          position: LatLng(latitude, longitude),
          building: properties['building']?.toString(),
          floor: _parseFloor(properties['floor']),
        ),
      );
    }

    return results;
  }

  AccessibilityFeatureType? _parseType(String? type) {
    switch (type) {
      case 'accessible_entrance':
        return AccessibilityFeatureType.accessibleEntrance;

      case 'ramp':
        return AccessibilityFeatureType.ramp;

      case 'elevator':
        return AccessibilityFeatureType.elevator;

      default:
        return null;
    }
  }

  int? _parseFloor(dynamic value) {
    if (value == null) {
      return null;
    }

    if (value is int) {
      return value;
    }

    return int.tryParse(value.toString());
  }
}
