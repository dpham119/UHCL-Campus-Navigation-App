import 'dart:math';

const double _earthRadiusMeters = 6371000.0;

double _toRadians(double degrees) => degrees * pi / 180.0;

/// Great-circle distance in meters between two latitude/longitude points
/// (haversine formula).
double haversineMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final dLat = _toRadians(lat2 - lat1);
  final dLon = _toRadians(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) +
      cos(_toRadians(lat1)) * cos(_toRadians(lat2)) * pow(sin(dLon / 2), 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return _earthRadiusMeters * c;
}
