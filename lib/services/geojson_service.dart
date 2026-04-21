import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../models/campus_place.dart';

class GeoJsonService extends ChangeNotifier {
  static final GeoJsonService _instance = GeoJsonService._internal();
  factory GeoJsonService() => _instance;
  GeoJsonService._internal();

  List<CampusPlace> _all = [];
  List<CampusPlace> _filtered = [];
  Map<String, CategoryMeta> _categories = {};
  bool _isLoaded = false;
  List<List<List<double>>> _campusPerimeters = [];

  List<CampusPlace> get places => _filtered;
  List<CampusPlace> get allPlaces => _all;
  List<CategoryMeta> get categories {
    final list = _categories.values.toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }
  bool get isLoaded => _isLoaded;

  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final categoriesRaw =
          await rootBundle.loadString('assets/data/campus_eafit_categories.json');
      final categoriesJson = jsonDecode(categoriesRaw) as Map<String, dynamic>;
      final categoriesMap =
          categoriesJson['categories'] as Map<String, dynamic>? ?? {};
      _categories = categoriesMap.map(
        (key, value) => MapEntry(
          key,
          CategoryMeta.fromJson(key, value as Map<String, dynamic>),
        ),
      );

      final raw = await rootBundle.loadString('assets/data/campus_eafit.geojson');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final features = json['features'] as List<dynamic>;

      final List<CampusPlace> loaded = [];
      final Set<String> seen = {};

      _campusPerimeters.clear();
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>? ?? {};
        final featureCategories = _parseCategories(props);
        if (featureCategories.contains('perimetro')) {
          final coords = _parseCoords(f['geometry']['coordinates'][0] as List);
          _campusPerimeters.add(coords);
        }
      }

      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>;
        final name = (props['name'] ?? '').toString().trim();
        final desc = (props['description'] ?? '').toString().trim();
        final parsedCategories = _parseCategories(props);
        if (parsedCategories.contains('perimetro')) continue;

        final validCategories = parsedCategories
            .where((id) => _categories.containsKey(id))
            .toList();
        if (validCategories.isEmpty) continue;

        final coords = _parseCoords(f['geometry']['coordinates'][0] as List);
        double sumLat = 0, sumLng = 0;
        for (final c in coords) {
          sumLng += c[0];
          sumLat += c[1];
        }
        final lat = sumLat / coords.length;
        final lng = sumLng / coords.length;

        final descKey = desc.length > 30 ? desc.substring(0, 30) : desc;
        final key = '$name|$descKey';
        if (seen.contains(key)) continue;
        seen.add(key);

        loaded.add(CampusPlace(
          name: name,
          description: desc.isEmpty ? name : desc,
          latitude: lat,
          longitude: lng,
          categories: validCategories,
          polygon: coords,
        ));
      }

      _all = loaded;
      _filtered = List.from(_all);
      _isLoaded = true;
      notifyListeners();

      final stats = <String, int>{};
      for (final p in _all) {
        for (final cat in p.categories) {
          stats[cat] = (stats[cat] ?? 0) + 1;
        }
      }
      debugPrint('✅ GeoJSON: ${_all.length} lugares');
      stats.forEach((id, n) {
        final label = _categories[id]?.label ?? id;
        debugPrint('   $label: $n');
      });
    } catch (e) {
      debugPrint('❌ GeoJSON error: $e');
    }
  }

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

  List<List<double>> _parseCoords(List raw) {
    return raw
        .map<List<double>>(
            (c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()])
        .toList();
  }

  bool isInsideCampus(double lat, double lng) {
    if (_campusPerimeters.isEmpty) {
      return lat >= 6.196 && lat <= 6.204 && lng >= -75.582 && lng <= -75.575;
    }
    return _campusPerimeters.any((poly) => _pip(lat, lng, poly));
  }

  CampusPlace? getPlaceContaining(double lat, double lng) {
    for (final p in _all) {
      if (p.polygon != null && _pip(lat, lng, p.polygon!)) return p;
    }
    return null;
  }

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

  void filterByCategory(String? categoryId) {
    var result = List<CampusPlace>.from(_all);
    if (categoryId != null) {
      result = result.where((p) => p.categories.contains(categoryId)).toList();
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    _filtered = result;
    notifyListeners();
  }

  // ── HU-13: Filtra y ordena por proximidad al usuario ──
  void filterByProximity(double lat, double lng, {int limit = 10}) {
    final sorted = List<CampusPlace>.from(_all)
      ..sort((a, b) =>
          a.distanceFrom(lat, lng).compareTo(b.distanceFrom(lat, lng)));
    _filtered = sorted.take(limit).toList();
    notifyListeners();
  }

  CategoryMeta? categoryById(String id) => _categories[id];

  IconData iconForPlace(CampusPlace place) {
    final meta = categoryById(place.primaryCategory);
    return meta?.iconData ?? Icons.place_rounded;
  }

  List<CampusPlace> getNearby(double lat, double lng, {int limit = 3}) {
    if (_all.isEmpty) return [];
    final sorted = List<CampusPlace>.from(_all)
      ..sort((a, b) =>
          a.distanceFrom(lat, lng).compareTo(b.distanceFrom(lat, lng)));
    return sorted.take(limit).toList();
  }

  // ── HU-16: Punto de referencia más cercano para anunciar durante navegación ──
  // Busca en 4 categorías ordenadas por prioridad:
  //   1. bloque   — edificios académicos
  //   2. porteria — entradas del campus
  //   3. jardin   — zonas verdes y espacios abiertos
  //   4. cafeteria — referencias conocidas por todos
  // Retorna texto listo para leer en voz, por ejemplo:
  //   "el Bloque 38", "la Portería El Poblado", "el Jardín Central"
  String? getNearestLandmark(
    double lat,
    double lng, {
    double maxDistanceMeters = 45,
  }) {
    if (_all.isEmpty) return null;

    const orderedCategories = ['bloque', 'porteria', 'jardin', 'cafeteria'];

    for (final category in orderedCategories) {
      CampusPlace? nearest;
      double bestDistance = double.infinity;

      for (final place in _all) {
        if (!place.categories.contains(category)) continue;
        final d = place.distanceFrom(lat, lng);
        if (d < bestDistance) {
          bestDistance = d;
          nearest = place;
        }
      }

      if (nearest != null && bestDistance <= maxDistanceMeters) {
        return _landmarkLabel(nearest, category);
      }
    }

    return null;
  }

  // Texto natural según categoría: "el Bloque 38", "la Portería Norte"
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

  // Alias para no romper código existente en NavigationMapScreen y otros
  String? getNearestBlockReference(
    double lat,
    double lng, {
    double maxDistanceMeters = 45,
  }) =>
      getNearestLandmark(lat, lng, maxDistanceMeters: maxDistanceMeters);
}