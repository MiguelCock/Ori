import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../services/geojson_service.dart';

/// Builds the [Polygon], [Marker], and route [Polyline] layers for the map.
/// Stateless — all inputs are explicit, making it easy to test in isolation.
class MapLayerBuilder {
  final String? highlightCategoryId;

  const MapLayerBuilder({this.highlightCategoryId});

  // ── Campus polygons ───────────────────────────────────────────────────────

  List<Polygon> buildCampusPolygons(GeoJsonService geo) {
    final result = <Polygon>[];
    for (final place in geo.allPlaces) {
      final poly = place.polygon;
      if (poly == null || poly.length < 3) continue;

      final points = poly.map((c) => LatLng(c[1], c[0])).toList();
      final highlighted = highlightCategoryId == null ||
          place.categories.contains(highlightCategoryId);

      result.add(Polygon(
        points: points,
        color: _fillColor(highlighted),
        borderColor: _borderColor(highlighted),
        borderStrokeWidth: highlighted ? 1.4 : 0.8,
      ));
    }
    return result;
  }

  // ── Polygon name labels ───────────────────────────────────────────────────

  List<Marker> buildPolygonLabels(
    GeoJsonService geo,
    String Function(String) normalizeText,
  ) {
    return [
      for (final place in geo.allPlaces)
        if (place.polygon case final poly when poly != null && poly.length >= 3)
          Marker(
            point: _centroid(poly),
            width: 120,
            height: 34,
            child: IgnorePointer(
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  normalizeText(place.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
    ];
  }

  // ── Route node markers ────────────────────────────────────────────────────

  List<Marker> buildRouteNodeMarkers(
    List<LatLng> routePoints,
    int? nearestIndex,
  ) {
    if (routePoints.length < 2) return const [];
    return [
      for (var i = 1; i < routePoints.length; i++)
        _routeNodeMarker(
          routePoints[i],
          isDestination: i == routePoints.length - 1,
          isCurrent: nearestIndex == i,
        ),
    ];
  }

  // ── User position marker ──────────────────────────────────────────────────

  static Marker buildUserMarker(LatLng position) => Marker(
        point: position,
        width: 18,
        height: 18,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF43A047),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFF1B5E20), width: 2),
          ),
        ),
      );

  // ── Private helpers ───────────────────────────────────────────────────────

  static LatLng _centroid(List<List<double>> polygon) {
    var latSum = 0.0, lngSum = 0.0;
    for (final p in polygon) {
      lngSum += p[0];
      latSum += p[1];
    }
    return LatLng(latSum / polygon.length, lngSum / polygon.length);
  }

  static Marker _routeNodeMarker(
    LatLng point, {
    required bool isDestination,
    required bool isCurrent,
  }) {
    final prominent = isDestination || isCurrent;
    return Marker(
      point: point,
      width: prominent ? 20 : 12,
      height: prominent ? 20 : 12,
      child: Container(
        decoration: BoxDecoration(
          color:
              isCurrent ? const Color(0xFF43A047) : const Color(0xFFFFD54F),
          shape: BoxShape.circle,
          border: Border.all(
            color: isCurrent
                ? const Color(0xFF1B5E20)
                : const Color(0xFFF9A825),
            width: prominent ? 2.6 : 1.4,
          ),
        ),
      ),
    );
  }

  static Color _fillColor(bool highlighted) => highlighted
      ? const Color(0xFF7E57C2).withValues(alpha: 0.22)
      : const Color(0xFF7E57C2).withValues(alpha: 0.10);

  static Color _borderColor(bool highlighted) => highlighted
      ? const Color(0xFF5E35B1).withValues(alpha: 0.80)
      : const Color(0xFF5E35B1).withValues(alpha: 0.32);
}