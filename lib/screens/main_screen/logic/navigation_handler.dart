import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/campus_place.dart';
import '../../../services/geojson_service.dart';
import '../../../services/location_service.dart';
import '../../../services/routing/routing.dart';
import '../../../services/voidce_guidance/voice_guidance.dart';
import '../../navigation_map/navigation_map_screen.dart';

/// Handles destination selection, route building, and navigation launch.
/// Extracted from [_MainScreenState] to keep the screen widget focused on UI.
mixin NavigationHandlerMixin<T extends StatefulWidget> on State<T> {
  /// Override to provide an accessibility announcer bound to this widget's
  /// [BuildContext].
  Future<void> announce(String message);

  Future<void> onDestinationSelected(CampusPlace place) async {
    HapticFeedback.heavyImpact();

    final location = Provider.of<LocationService>(context, listen: false);
    final routing = Provider.of<RoutingService>(context, listen: false);
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final voice = Provider.of<VoiceGuidanceService>(context, listen: false);

    // ── Guard: GPS ────────────────────────────────────────────────────────
    if (!location.canStartNavigation()) {
      await announce(
          'No se pudo generar la ruta. Ubicación actual no disponible.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          location.currentLocation == null
              ? 'Activa el GPS para generar la ruta.'
              : 'No se puede iniciar navegación en este momento.',
        ),
        backgroundColor: const Color(0xFFB00020),
      ));
      return;
    }

    if (!geo.isDataLoaded) await geo.load();

    final origin = location.currentLocation!;

    // ── Guard: inside campus ──────────────────────────────────────────────
    if (!geo.isInsideCampus(origin.latitude, origin.longitude)) {
      await announce('No puedes iniciar navegación fuera del área del campus.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Debes estar dentro del campus para iniciar navegación.'),
        backgroundColor: Color(0xFFB00020),
      ));
      return;
    }

    if (!geo.isPlaceInsideCampus(place)) {
      await announce(
          'El destino seleccionado no está dentro del área del campus.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('El destino no pertenece al campus.'),
        backgroundColor: Color(0xFFB00020),
      ));
      return;
    }

    // ── Guard: already at destination ─────────────────────────────────────
    final destPolygon = place.polygon;
    if (destPolygon != null &&
        destPolygon.length >= 3 &&
        isInsidePolygon(origin.latitude, origin.longitude, destPolygon)) {
      final message = 'Ya estás dentro de ${place.name}.';
      await announce(message);
      await voice.speakMessage(message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1565C0),
      ));
      return;
    }

    // ── Origin is inside a building: skip routing, open map directly ──────
    final originPlace = geo.getPlaceContaining(
      origin.latitude,
      origin.longitude,
    );
    if (originPlace?.polygon != null) {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NavigationMapScreen(
          destinationName: place.name,
          startLat: origin.latitude,
          startLng: origin.longitude,
          destLat: place.latitude,
          destLng: place.longitude,
          highlightCategoryId: place.primaryCategory,
          initialRoute: null,
          destinationPolygon: place.polygon,
        ),
      ));
      return;
    }

    // ── Build route ───────────────────────────────────────────────────────
    final route = await routing.buildRoute(
      originLat: origin.latitude,
      originLng: origin.longitude,
      destinationLat: place.latitude,
      destinationLng: place.longitude,
      originPolygon: originPlace?.polygon,
      destinationPolygon: place.polygon,
    );

    await announce(
      route != null
          ? 'Destino: ${place.name}. Ruta generada localmente.'
          : 'Destino: ${place.name}. No se pudo generar una ruta conectada.',
    );
    if (!mounted) return;

    if (route != null) {
      // Fire-and-forget — navigation starts immediately, map opens on top.
      voice.startNavigation(
        route: route,
        locationService: location,
        routingService: routing,
        destinationName: place.name,
        destinationLat: place.latitude,
        destinationLng: place.longitude,
        announceForTalkBack: announce,
        landmarkResolver: (lat, lng, _) =>
            geo.getNearestBlockReference(lat, lng),
      );
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NavigationMapScreen(
          destinationName: place.name,
          startLat: origin.latitude,
          startLng: origin.longitude,
          destLat: place.latitude,
          destLng: place.longitude,
          highlightCategoryId: place.primaryCategory,
          initialRoute: route,
          destinationPolygon: place.polygon,
        ),
      ));
      return;
    }

    // ── No route: show error dialog ───────────────────────────────────────
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: const Text('Ruta no disponible',
            style: TextStyle(color: Colors.white)),
        content: Text(
          routing.lastError.isEmpty
              ? 'No hay conexión peatonal entre origen y destino.'
              : routing.lastError,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido',
                style: TextStyle(color: Color(0xFF82B1FF))),
          ),
        ],
      ),
    );
  }

  // ── Utility ──────────────────────────────────────────────────────────────

  /// Ray-casting point-in-polygon (polygon coords are [lon, lat] pairs).
  static bool isInsidePolygon(
      double lat, double lon, List<List<double>> polygon) {
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
}