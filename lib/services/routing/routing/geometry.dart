import 'dart:math';

/// A point projected into a local Cartesian plane (metres).
class ProjectedPoint {
  final double x;
  final double y;

  const ProjectedPoint({required this.x, required this.y});
}

class ProjectionResult {
  final double lat;
  final double lon;
  final double distanceMeters;

  const ProjectionResult({
    required this.lat,
    required this.lon,
    required this.distanceMeters,
  });
}

// ── Distance ────────────────────────────────────────────────────────────────

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371000.0;
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return earthRadius * 2 * asin(sqrt(a));
}

double _toRad(double deg) => deg * pi / 180.0;

// ── Projection helpers ───────────────────────────────────────────────────────

const _metersPerDegreeLat = 111320.0;

double metersPerDegreeLng(double refLat) =>
    _metersPerDegreeLat * cos(_toRad(refLat));

ProjectedPoint projectPoint(double lat, double lon, double refLat) {
  return ProjectedPoint(
    x: lon * metersPerDegreeLng(refLat),
    y: lat * _metersPerDegreeLat,
  );
}

/// Projects [originLat]/[originLon] onto the segment A→B.
/// Returns null when A == B.
ProjectionResult? projectPointOnSegment({
  required double originLat,
  required double originLon,
  required double aLat,
  required double aLon,
  required double bLat,
  required double bLon,
}) {
  final refLat = (aLat + bLat + originLat) / 3;
  final mpdLng = metersPerDegreeLng(refLat);

  final ax = aLon * mpdLng, ay = aLat * _metersPerDegreeLat;
  final bx = bLon * mpdLng, by = bLat * _metersPerDegreeLat;
  final px = originLon * mpdLng, py = originLat * _metersPerDegreeLat;

  final abx = bx - ax, aby = by - ay;
  final ab2 = abx * abx + aby * aby;
  if (ab2 == 0) return null;

  final t = ((px - ax) * abx + (py - ay) * aby) / ab2;
  final tc = t.clamp(0.0, 1.0);

  final cx = ax + abx * tc;
  final cy = ay + aby * tc;
  final lat = cy / _metersPerDegreeLat;
  final lon = cx / mpdLng;

  return ProjectionResult(
    lat: lat,
    lon: lon,
    distanceMeters: haversineMeters(originLat, originLon, lat, lon),
  );
}

// ── Segment intersection ─────────────────────────────────────────────────────

/// Returns the parameter t ∈ [0,1] where segment AB intersects segment CD,
/// or null when they don't intersect.
double? segmentIntersectionT(
  ProjectedPoint a,
  ProjectedPoint b,
  ProjectedPoint c,
  ProjectedPoint d,
) {
  final denom = (a.x - b.x) * (c.y - d.y) - (a.y - b.y) * (c.x - d.x);
  if (denom.abs() < 1e-12) return null;

  final t =
      ((a.x - c.x) * (c.y - d.y) - (a.y - c.y) * (c.x - d.x)) / denom;
  final u =
      ((a.x - c.x) * (a.y - b.y) - (a.y - c.y) * (a.x - b.x)) / denom;

  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return t;
}

// ── Polygon helpers ──────────────────────────────────────────────────────────

/// Ray-casting point-in-polygon test.
/// [polygon] is a list of [lon, lat] pairs.
bool isInsidePolygon(double lat, double lon, List<List<double>> polygon) {
  bool inside = false;
  int j = polygon.length - 1;

  for (int i = 0; i < polygon.length; i++) {
    final xi = polygon[i][0], yi = polygon[i][1];
    final xj = polygon[j][0], yj = polygon[j][1];

    if (((yi > lat) != (yj > lat)) &&
        (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}