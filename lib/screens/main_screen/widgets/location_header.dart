import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../services/geojson_service.dart';
import '../../../services/location_service.dart';
import '../../../utils/accessibility_scale.dart';

/// Gradient header that shows the user's current location name and, when
/// outside campus, reverse-geocodes the coordinates via Nominatim.
class LocationHeader extends StatefulWidget {
  const LocationHeader({super.key});

  @override
  State<LocationHeader> createState() => _LocationHeaderState();
}

class _LocationHeaderState extends State<LocationHeader> {
  String _address = '';
  double? _lastLat, _lastLng;

  Future<void> _fetchAddress(double lat, double lng) async {
    if (_lastLat == lat && _lastLng == lng) return;
    _lastLat = lat;
    _lastLng = lng;

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=json&lat=$lat&lon=$lng&accept-language=es',
      );
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'CampusGuiaEAFIT/1.0'},
      );
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = (data['address'] as Map<String, dynamic>?) ?? {};

      final parts = <String>[
        if (addr['road'] ?? addr['pedestrian'] ?? addr['path']
            case final String r) r,
        if (addr['suburb'] ?? addr['neighbourhood'] ?? addr['quarter']
            case final String s) s,
        if (addr['city'] ?? addr['town'] ?? addr['municipality']
            case final String c)
          if (c != (addr['suburb'] ?? addr['neighbourhood'] ?? '')) c,
      ];

      if (mounted) setState(() => _address = parts.join(', '));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);

    return Consumer2<LocationService, GeoJsonService>(
      builder: (_, loc, geo, _) {
        final (title, subtitle, showEafit) = _resolveContent(loc, geo);

        return Semantics(
          label:
              'Ubicación actual: $title${subtitle.isNotEmpty ? ". $subtitle" : ""}',
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A237E), Color(0xFF1565C0)],
              ),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ubicación actual',
                          textScaler: textScaler,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          textScaler:
                              clampedTextScaler(context, maxScale: 1.3),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            height: 1.1,
                          ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            textScaler: textScaler,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        if (showEafit) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.school_rounded,
                                  color: Colors.white38, size: 13),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'Universidad EAFIT, Medellín',
                                  textScaler: textScaler,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Returns (title, subtitle, showEafitBadge).
  (String, String, bool) _resolveContent(
    LocationService loc,
    GeoJsonService geo,
  ) {
    if (loc.currentLocation == null) {
      return switch (loc.status) {
        LocationStatus.permissionDenied => (
            'Permiso denegado',
            'Activa la ubicación en ajustes',
            false
          ),
        LocationStatus.disabled => (
            'GPS desactivado',
            'Activa el GPS para navegar',
            false
          ),
        _ => ('Buscando señal GPS...', '', false),
      };
    }

    final lat = loc.currentLocation!.latitude;
    final lng = loc.currentLocation!.longitude;

    if (geo.isDataLoaded && geo.isInsideCampus(lat, lng)) {
      final place = geo.getPlaceContaining(lat, lng);
      return (
        place?.name ?? 'Campus EAFIT',
        place?.description.split('\n').first ?? '',
        true,
      );
    }

    // Outside campus: kick off reverse geocode (no-op if coords unchanged).
    _fetchAddress(lat, lng);
    return (
      'Fuera del campus',
      _address.isNotEmpty ? _address : 'Obteniendo dirección...',
      false,
    );
  }
}