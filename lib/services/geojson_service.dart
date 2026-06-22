import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/campus_place.dart';

/// Service class for loading, managing, and querying campus geographic data.
/// 
/// This singleton service handles all campus location data including:
/// - Loading and parsing GeoJSON data from assets
/// - Managing categories and their metadata
/// - Filtering places by category or proximity
/// - Point-in-polygon queries for campus boundaries
/// - Finding nearest landmarks for navigation guidance
/// 
/// Uses ChangeNotifier to update UI when data or filters change.
class GeoJsonService extends ChangeNotifier {

  // ─── Singleton pattern ──────────────────────────────────────────────────────────
  static final GeoJsonService _instance = GeoJsonService._internal();
  factory GeoJsonService() => _instance;
  GeoJsonService._internal();

  // ─── Data Storage ──────────────────────────────────────────────────────────
  bool _isDataLoaded = false;
  List<CampusPlace> _campusPlaceAll = [];
  List<CampusPlace> _campusPlaceFiltered = [];
  Map<String, CategoryMeta> _categoriesMetaData = {};
  final List<List<List<double>>> _campusPerimeters = [];

  // ─── Getters ──────────────────────────────────────────────────────────────
  
  /// Returns the currently filtered list of places for UI display
  List<CampusPlace> get filteredPlaces => _campusPlaceFiltered;
  
  /// Returns the complete unfiltered list of all places
  List<CampusPlace> get allPlaces => _campusPlaceAll;
  
  /// Returns categories sorted by their display order
  List<CategoryMeta> get categories {
    final list = _categoriesMetaData.values.toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  /// Returns whether the data has been loaded successfully
  bool get isDataLoaded => _isDataLoaded;

  // ─── Data Loading ──────────────────────────────────────────────────────────

  /// Loads all campus data from assets files.
  /// 
  /// This method:
  /// 1. Loads category definitions from 'campus_eafit_categories.json'
  /// 2. Loads GeoJSON data from 'campus_eafit.geojson'
  /// 3. Extracts campus boundary polygons
  /// 4. Parses each feature into CampusPlace objects
  /// 5. Deduplicates entries by name + description + location
  /// 
  /// Only loads data once; subsequent calls are ignored if already loaded.
  Future<void> load() async {
    if (_isDataLoaded) return;
    try {
      // ── Load categories ──────────────────────────────────────────
      final categoriesRaw = await rootBundle.loadString(
        'assets/data/campus_eafit_categories.json',
      );
      final categoriesJson = jsonDecode(categoriesRaw) as Map<String, dynamic>;
      final categoriesMap =
          categoriesJson['categories'] as Map<String, dynamic>? ?? {};
      _categoriesMetaData = categoriesMap.map(
        (key, value) => MapEntry(
          key,
          CategoryMeta.fromJson(key, value as Map<String, dynamic>),
        ),
      );

      // ── Load GeoJSON ─────────────────────────────────────────────
      final raw = await rootBundle.loadString(
        'assets/data/campus_eafit.geojson',
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final features = json['features'] as List<dynamic>;

      final List<CampusPlace> loaded = [];
      final Set<String> seen = {};

      // ── Extract campus boundaries ──────────────────────────────
      _campusPerimeters.clear();
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>? ?? {};
        final featureCategories = _parseCategories(props);
        if (_isCampusBoundaryFeature(props, featureCategories)) {
          final geometry = f['geometry'] as Map<String, dynamic>?;
          final coords = _extractOuterRing(geometry);
          if (coords == null || coords.length < 3) continue;
          _campusPerimeters.add(coords);
        }
      }

      // ── Parse place features ────────────────────────────────────
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>;
        final name = (props['name'] ?? '').toString().trim();
        final desc = (props['description'] ?? '').toString().trim();
        final parsedCategories = _parseCategories(props);
        
        // Skip boundary features (they're not places)
        if (_isCampusBoundaryFeature(props, parsedCategories)) continue;

        // Only keep places with valid categories
        final validCategories = parsedCategories
            .where((id) => _categoriesMetaData.containsKey(id))
            .toList();
        if (validCategories.isEmpty) continue;

        // Extract polygon and calculate centroid
        final geometry = f['geometry'] as Map<String, dynamic>?;
        final coords = _extractOuterRing(geometry);
        if (coords == null || coords.length < 3) continue;
        
        double sumLat = 0, sumLng = 0;
        for (final c in coords) {
          sumLng += c[0];
          sumLat += c[1];
        }
        final lat = sumLat / coords.length;
        final lng = sumLng / coords.length;

        // ── Deduplicate places ────────────────────────────────────
        // Use name + description (truncated) + coordinates as unique key
        // This prevents duplicate entries while preserving distinct places with same name
        final descKey = desc.length > 30 ? desc.substring(0, 30) : desc;
        final key =
            '$name|$descKey|${lat.toStringAsFixed(6)}|${lng.toStringAsFixed(6)}';
        if (seen.contains(key)) continue;
        seen.add(key);

        loaded.add(
          CampusPlace(
            name: name,
            description: desc.isEmpty ? name : desc,
            latitude: lat,
            longitude: lng,
            categories: validCategories,
            polygon: coords,
          ),
        );
      }

      // ── Store results ──────────────────────────────────────────
      _campusPlaceAll = loaded;
      _campusPlaceFiltered = List.from(_campusPlaceAll);
      _isDataLoaded = true;
      notifyListeners();

      // ── Log statistics ─────────────────────────────────────────
      final stats = <String, int>{};
      for (final p in _campusPlaceAll) {
        for (final cat in p.categories) {
          stats[cat] = (stats[cat] ?? 0) + 1;
        }
      }
      debugPrint('✅ GeoJSON: ${_campusPlaceAll.length} lugares');
      stats.forEach((id, n) {
        final label = _categoriesMetaData[id]?.label ?? id;
        debugPrint('   $label: $n');
      });
    } catch (e) {
      debugPrint('❌ GeoJSON error: $e');
    }
  }

  // ─── Category Parsing ─────────────────────────────────────────────────────

  /// Extracts category IDs from feature properties.
  /// 
  /// Supports both list format ('categories': ['id1', 'id2']) and
  /// single string format ('category': 'id') for backward compatibility.
  List<String> _parseCategories(Map<String, dynamic> props) {
    final rawList = props['categories'];
    if (rawList is List) {
      final values = rawList
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      if (values.isNotEmpty) return values;
    }

    final single = props['category'];
    if (single != null && single.toString().trim().isNotEmpty) {
      return [single.toString().trim()];
    }

    return const [];
  }

  // ─── Geometry Helpers ────────────────────────────────────────────────────

  /// Converts raw JSON coordinates to a list of [lng, lat] pairs.
  List<List<double>> _parseCoords(List<dynamic> raw) {
    return raw
        .map<List<double>>(
          (c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()],
        )
        .toList();
  }

  /// Extracts the outer ring from a Polygon or MultiPolygon geometry.
  /// 
  /// For Polygon: returns the first ring (outer boundary)
  /// For MultiPolygon: returns the largest polygon by area
  /// Returns null for unsupported geometry types or invalid data.
  List<List<double>>? _extractOuterRing(Map<String, dynamic>? geometry) {
    if (geometry == null) return null;

    final type = (geometry['type'] ?? '').toString();
    final rawCoords = geometry['coordinates'];

    if (type == 'Polygon' && rawCoords is List && rawCoords.isNotEmpty) {
      return _parseCoords(rawCoords[0] as List);
    }

    if (type == 'MultiPolygon' && rawCoords is List && rawCoords.isNotEmpty) {
      List<List<double>>? best;
      double bestArea = -1;

      for (final polygon in rawCoords) {
        if (polygon is! List || polygon.isEmpty) continue;
        final candidate = _parseCoords(polygon[0] as List);
        if (candidate.length < 3) continue;
        final area = _polygonAreaAbs(candidate);
        if (area > bestArea) {
          bestArea = area;
          best = candidate;
        }
      }

      return best;
    }

    return null;
  }

  /// Checks if a feature represents the campus perimeter/boundary.
  /// 
  /// Detection methods (in order):
  /// 1. Explicit flags: is_boundary, campus_boundary, isCampusBoundary
  /// 2. Category hints: categories containing words like 'perimetro', 'campus'
  /// 3. Name hints: name containing boundary-related keywords
  bool _isCampusBoundaryFeature(
    Map<String, dynamic> props,
    List<String> categories,
  ) {
    final lowerCategories = categories.map((c) => c.toLowerCase()).toList();
    final name = (props['name'] ?? '').toString().toLowerCase();

    final explicitFlag =
        props['is_boundary'] == true ||
        props['campus_boundary'] == true ||
        props['isCampusBoundary'] == true;
    if (explicitFlag) return true;

    const boundaryHints = [
      'perimetro',
      'perímetro',
      'campus',
      'universidad',
      'university',
      'boundary',
      'limite',
      'límite',
    ];

    final categoryHasHint = lowerCategories.any(
      (value) => boundaryHints.any((hint) => value.contains(hint)),
    );
    if (categoryHasHint) return true;

    return boundaryHints.any(name.contains);
  }

  /// Calculates the absolute area of a polygon using the Shoelace formula.
  /// 
  /// Returns 0 for polygons with fewer than 3 points.
  /// Used to identify the largest polygon in MultiPolygon geometries.
  double _polygonAreaAbs(List<List<double>> coords) {
    if (coords.length < 3) return 0;
    var sum = 0.0;

    for (int i = 0; i < coords.length; i++) {
      final j = (i + 1) % coords.length;
      final xi = coords[i][0];
      final yi = coords[i][1];
      final xj = coords[j][0];
      final yj = coords[j][1];
      sum += (xi * yj) - (xj * yi);
    }

    return sum.abs() / 2;
  }

  // ─── Spatial Queries ─────────────────────────────────────────────────────

  /// Tests if a point (latitude, longitude) is inside the campus boundaries.
  /// 
  /// Uses ray-casting algorithm (_pip) on each campus perimeter polygon.
  bool isInsideCampus(double lat, double lng) {
    if (_campusPerimeters.isEmpty) return false;
    return _campusPerimeters.any((poly) => _pip(lat, lng, poly));
  }

  /// Tests if a place is inside the campus boundaries.
  /// 
  /// First checks if any point of the place's polygon is inside campus,
  /// then falls back to checking the centroid point.
  bool isPlaceInsideCampus(CampusPlace place) {
    if (_campusPerimeters.isEmpty) return false;

    final poly = place.polygon;
    if (poly != null && poly.isNotEmpty) {
      for (final p in poly) {
        if (isInsideCampus(p[1], p[0])) return true;
      }
    }

    return isInsideCampus(place.latitude, place.longitude);
  }

  /// Finds which place contains a given point (latitude, longitude).
  /// 
  /// Useful for tap-to-select features on a map.
  /// Returns null if no place contains the point.
  CampusPlace? getPlaceContaining(double lat, double lng) {
    for (final p in _campusPlaceAll) {
      if (p.polygon != null && _pip(lat, lng, p.polygon!)) return p;
    }
    return null;
  }

  /// Point-in-polygon test using the ray-casting algorithm.
  /// 
  /// Determines if a point (lat, lng) is inside the given polygon.
  /// Polygon coordinates are in [lng, lat] format.
  bool _pip(double lat, double lng, List<List<double>> poly) {
    bool inside = false;
    int j = poly.length - 1;
    for (int i = 0; i < poly.length; i++) {
      final xi = poly[i][0], yi = poly[i][1];
      final xj = poly[j][0], yj = poly[j][1];
      if (((yi > lat) != (yj > lat)) &&
          (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  // ─── Filtering ────────────────────────────────────────────────────────────

  /// Filters places by category ID.
  /// 
  /// If categoryId is null, shows all places.
  /// Results are sorted alphabetically by name.
  void filterByCategory(String? categoryId) {
    var result = List<CampusPlace>.from(_campusPlaceAll);
    if (categoryId != null) {
      result = result.where((p) => p.categories.contains(categoryId)).toList();
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    _campusPlaceFiltered = result;
    notifyListeners();
  }

  /// Filters places by proximity to user location (HU-13).
  /// 
  /// Sorts all places by distance from the user and returns the closest N.
  /// Default limit is 10 places.
  void filterByProximity(double lat, double lng, {int limit = 10}) {
    final sorted = List<CampusPlace>.from(_campusPlaceAll)
      ..sort((a, b) =>
          a.distanceFrom(lat, lng).compareTo(b.distanceFrom(lat, lng)));
    _campusPlaceFiltered = sorted.take(limit).toList();
    notifyListeners();
  }

  // ─── Category Helpers ────────────────────────────────────────────────────

  /// Retrieves category metadata by ID.
  CategoryMeta? categoryById(String id) => _categoriesMetaData[id];

  /// Gets the appropriate icon for a place based on its primary category.
  IconData iconForPlace(CampusPlace place) {
    final meta = categoryById(place.primaryCategory);
    return meta?.iconData ?? Icons.place_rounded;
  }

  // ─── Proximity Queries ──────────────────────────────────────────────────

  /// Gets the N closest places to a location (default: 3).
  /// 
  /// Useful for "nearby points of interest" features.
  List<CampusPlace> getNearby(double lat, double lng, {int limit = 3}) {
    if (_campusPlaceAll.isEmpty) return [];
    final sorted = List<CampusPlace>.from(_campusPlaceAll)
      ..sort(
        (a, b) => a.distanceFrom(lat, lng).compareTo(b.distanceFrom(lat, lng)),
      );
    return sorted.take(limit).toList();
  }

  // ─── Landmark Reference System (HU-16) ──────────────────────────────────

  /// Gets the nearest landmark for voice navigation guidance.
  /// 
  /// Searches in priority order:
  /// 1. bloque (buildings) - academic buildings
  /// 2. porteria (entrances) - campus gates
  /// 3. jardin (gardens) - green spaces
  /// 4. cafeteria - food locations
  /// 
  /// Returns natural language text like "el Bloque 38" or "la Portería El Poblado".
  /// Returns null if no landmark found within maxDistanceMeters (default: 45m).
  String? getNearestLandmark(
    double lat,
    double lng, {
    double maxDistanceMeters = 45,
  }) {
    final candidate = _nearestLandmarkCandidate(
      lat,
      lng,
      maxDistanceMeters: maxDistanceMeters,
    );
    return candidate?.label;
  }

  /// Generates natural language label with correct Spanish article.
  /// 
  /// Examples:
  /// - bloque → "el Bloque 38"
  /// - porteria → "la Portería Norte"
  /// - jardin → "el Jardín Central"
  String _landmarkLabel(CampusPlace place, String category) {
    switch (category) {
      case 'bloque':
        return 'el ${place.name}';
      case 'porteria':
        return 'la ${place.name}';
      case 'jardin':
        return 'el ${place.name}';
      case 'cafeteria':
        return 'la ${place.name}';
      default:
        return place.name;
    }
  }

  /// Alias for compatibility with NavigationMapScreen and other widgets.
  /// 
  /// Delegates to getNearestLandmark() with the same parameters.
  String? getNearestBlockReference(
    double lat,
    double lng, {
    double maxDistanceMeters = 45,
  }) =>
      getNearestLandmark(lat, lng, maxDistanceMeters: maxDistanceMeters);

  /// Internal method that finds the best landmark candidate.
  /// 
  /// Iterates through categories in priority order and returns the
  /// first category that has a place within maxDistanceMeters.
  ({CampusPlace place, String label})? _nearestLandmarkCandidate(
    double lat,
    double lng, {
    double maxDistanceMeters = 45,
  }) {
    if (_campusPlaceAll.isEmpty) return null;

    const orderedCategories = ['bloque', 'porteria', 'jardin', 'cafeteria'];

    for (final category in orderedCategories) {
      CampusPlace? nearest;
      double bestDistance = double.infinity;

      for (final place in _campusPlaceAll) {
        if (!place.categories.contains(category)) continue;
        final d = place.distanceFrom(lat, lng);
        if (d < bestDistance) {
          bestDistance = d;
          nearest = place;
        }
      }

      if (nearest != null && bestDistance <= maxDistanceMeters) {
        return (place: nearest, label: _landmarkLabel(nearest, category));
      }
    }

    return null;
  }
}