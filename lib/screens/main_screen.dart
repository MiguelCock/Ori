import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/location_service.dart';
import '../services/geojson_service.dart';
import '../services/routing_service.dart';
import '../services/voice_guidance_service.dart';
import '../models/campus_place.dart';
import '../utils/accessibility_scale.dart';
import 'destination_screen.dart';
import 'navigation_map_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isInsidePolygon(double lat, double lng, List<List<double>> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i][0], yi = polygon[i][1];
      final xj = polygon[j][0], yj = polygon[j][1];
      if (((yi > lat) != (yj > lat)) &&
          (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  Future<void> _announce(String message) {
    return SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LocationService>(context, listen: false).initialize();
      Provider.of<GeoJsonService>(context, listen: false).load();
      Provider.of<RoutingService>(context, listen: false).load();

      // Conectar servicios permanentemente para modo exploración
      final voice = Provider.of<VoiceGuidanceService>(context, listen: false);
      voice.setLocationService(Provider.of<LocationService>(context, listen: false));
      voice.setGeoJsonService(Provider.of<GeoJsonService>(context, listen: false));
      voice.setAnnouncer(_announce);

      _announce(
        'Pantalla principal de CampusGuía. Siete categorías disponibles.',
      );
    });
  }

  void _openCategory(CategoryMeta cat) {
    HapticFeedback.lightImpact();
    _announce('Abriendo ${cat.label}');
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final loc = Provider.of<LocationService>(context, listen: false);
    geo.filterByCategory(cat.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: geo),
            ChangeNotifierProvider.value(value: loc),
          ],
          child: DestinationScreen(
            categoryName: cat.label,
            onDestinationSelected: (place) {
              Navigator.of(context).pop();
              _onSelected(place);
            },
          ),
        ),
      ),
    );
  }

  void _openNearby() {
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final loc = Provider.of<LocationService>(context, listen: false);

    if (loc.currentLocation == null) {
      _announce(
        'No se puede mostrar lugares cercanos. Ubicación no disponible.',
      );
      return;
    }

    HapticFeedback.lightImpact();
    _announce('Abriendo más lugares cercanos a ti.');

    final here = loc.currentLocation!;
    geo.filterByProximity(here.latitude, here.longitude, limit: 10);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: geo),
            ChangeNotifierProvider.value(value: loc),
          ],
          child: DestinationScreen(
            categoryName: 'Cerca de ti',
            onDestinationSelected: (place) {
              Navigator.of(context).pop();
              _onSelected(place);
            },
          ),
        ),
      ),
    );
  }

  CampusPlace? _pickTestDestination(
    GeoJsonService geo,
    LocationService loc,
  ) {
    final current = loc.currentLocation;
    if (current == null) return null;

    final currentPlace = geo.getPlaceContaining(
      current.latitude,
      current.longitude,
    );
    final nearby = geo.getNearby(current.latitude, current.longitude, limit: 10);

    for (final place in nearby) {
      final samePlace = currentPlace != null &&
          place.name == currentPlace.name &&
          place.description == currentPlace.description;
      final tooClose = place.distanceFrom(current.latitude, current.longitude) < 20;
      if (!samePlace && !tooClose) {
        return place;
      }
    }

    return nearby.isNotEmpty ? nearby.first : null;
  }

  Future<void> _onSelected(CampusPlace place) async {
    HapticFeedback.heavyImpact();
    final location = Provider.of<LocationService>(context, listen: false);
    final routing = Provider.of<RoutingService>(context, listen: false);
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final voice = Provider.of<VoiceGuidanceService>(context, listen: false);

    if (!location.canStartNavigation()) {
      _announce('No se pudo generar la ruta. Ubicación actual no disponible.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            location.currentLocation == null
                ? 'Activa el GPS para generar la ruta.'
                : 'No se puede iniciar navegación en este momento.',
          ),
          backgroundColor: const Color(0xFFB00020),
        ),
      );
      return;
    }

    if (!geo.isLoaded) {
      await geo.load();
    }

    final origin = location.currentLocation!;
    if (!geo.isInsideCampus(origin.latitude, origin.longitude)) {
      _announce('No puedes iniciar navegación fuera del área del campus.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Debes estar dentro del campus para iniciar navegación.',
          ),
          backgroundColor: Color(0xFFB00020),
        ),
      );
      return;
    }

    if (!geo.isPlaceInsideCampus(place)) {
      _announce('El destino seleccionado no está dentro del área del campus.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El destino no pertenece al campus.'),
          backgroundColor: Color(0xFFB00020),
        ),
      );
      return;
    }

    final destinationPolygon = place.polygon;
    final alreadyAtDestination =
        destinationPolygon != null &&
        destinationPolygon.length >= 3 &&
        _isInsidePolygon(origin.latitude, origin.longitude, destinationPolygon);
    if (alreadyAtDestination) {
      final message = 'Ya estás dentro de ${place.name}.';
      _announce(message);
      await voice.speakMessage(message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFF1565C0),
        ),
      );
      return;
    }

    final originPlace = geo.getPlaceContaining(
      origin.latitude,
      origin.longitude,
    );
    if (originPlace?.polygon != null) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
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
        ),
      );
      return;
    }

    final route = await routing.buildRoute(
      originLat: origin.latitude,
      originLng: origin.longitude,
      destinationLat: place.latitude,
      destinationLng: place.longitude,
      originPolygon: geo
          .getPlaceContaining(origin.latitude, origin.longitude)
          ?.polygon,
      destinationPolygon: place.polygon,
    );

    final hasRoute = route != null;
    _announce(
      hasRoute
          ? 'Destino: ${place.name}. Ruta generada localmente.'
          : 'Destino: ${place.name}. No se pudo generar una ruta conectada.',
    );
    if (!mounted) return;

    if (hasRoute) {
      voice.startNavigation(
        route: route,
        locationService: location,
        routingService: routing,
        destinationName: place.name,
        destinationLat: place.latitude,
        destinationLng: place.longitude,
        announceForTalkBack: _announce,
        landmarkResolver: (lat, lng, headingDegrees) =>
            geo.getNearestBlockReference(
          lat,
          lng,
        ),
      );

      await Navigator.of(context).push(
        MaterialPageRoute(
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
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: const Text(
          'Ruta no disponible',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          routing.lastError.isEmpty
              ? 'No hay conexión peatonal entre origen y destino.'
              : routing.lastError,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Entendido',
              style: TextStyle(color: Color(0xFF82B1FF)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Column(
          children: [
            const _LocationHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _NearbySection(
                      onSeeMore: _openNearby,
                      onSelect: _onSelected,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: Row(
                        children: const [
                          Expanded(
                            child: Divider(
                              color: Colors.white12,
                              thickness: 1,
                            ),
                          ),
                          ExcludeSemantics(
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                '·  ·  ·',
                                style: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Divider(
                              color: Colors.white12,
                              thickness: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        responsiveSpace(context, 20),
                        responsiveSpace(context, 14),
                        responsiveSpace(context, 20),
                        responsiveSpace(context, 12),
                      ),
                      child: Semantics(
                        header: true,
                        label: 'Categorías de lugares',
                        child: ExcludeSemantics(
                          child: Text(
                            '¿A dónde quieres ir?',
                            textScaler: textScaler,
                            softWrap: true,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: responsiveSpace(context, 16),
                      ),
                      child: Consumer<VoiceGuidanceService>(
                        builder: (_, voice, __) {
                          final enabled = voice.explorationModeEnabled;
                          return Semantics(
                            button: true,
                            label: enabled
                                ? 'Modo exploración activado. Anunciará lugares al caminar sin necesidad de navegación. Toca dos veces para desactivar.'
                                : 'Modo exploración desactivado. Toca dos veces para activar y escuchar lugares al caminar.',
                            child: ExcludeSemantics(
                              child: SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    HapticFeedback.mediumImpact();
                                    voice.setExplorationModeEnabled(!enabled);
                                    _announce(
                                      enabled
                                          ? 'Modo exploración desactivado.'
                                          : 'Modo exploración activado. Escucharás anuncios de lugares al caminar.',
                                    );
                                  },
                                  icon: Icon(
                                    enabled
                                        ? Icons.explore_rounded
                                        : Icons.explore_off_rounded,
                                    size: 20,
                                  ),
                                  label: Text(
                                    enabled
                                        ? 'Exploración: activada'
                                        : 'Exploración: desactivada',
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: enabled
                                        ? const Color(0xFF82B1FF)
                                        : Colors.white38,
                                    side: BorderSide(
                                      color: enabled
                                          ? const Color(0xFF82B1FF)
                                          : Colors.white24,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                    ),
                                    minimumSize: const Size(double.infinity, 48),
                                    textStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: responsiveSpace(context, 16),
                      ),
                      child: Consumer<GeoJsonService>(
                        builder: (_, geo, __) {
                          final cats = geo.categories;
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              final availableWidth = constraints.maxWidth;
                              final columns = availableWidth < 330
                                  ? 2
                                  : availableWidth > 520
                                  ? 4
                                  : 3;
                              final spacing = responsiveSpace(context, 12);
                              final itemWidth =
                                  (availableWidth - spacing * (columns - 1)) /
                                  columns;
                              return Wrap(
                                spacing: spacing,
                                runSpacing: spacing,
                                children: [
                                  for (final cat in cats)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _CatBtn(
                                        cat: cat,
                                        onTap: _openCategory,
                                      ),
                                    ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 28),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HU-13 — Sección "Cerca de ti" (CORREGIDA para TalkBack)
// ============================================================
class _NearbySection extends StatelessWidget {
  final VoidCallback onSeeMore;
  final Future<void> Function(CampusPlace) onSelect;

  const _NearbySection({required this.onSeeMore, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    return Consumer2<LocationService, GeoJsonService>(
      builder: (_, loc, geo, __) {
        if (loc.currentLocation == null || !geo.isLoaded) {
          return const SizedBox.shrink();
        }
        final here = loc.currentLocation!;
        final nearby = geo.getNearby(here.latitude, here.longitude, limit: 3);
        if (nearby.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: EdgeInsets.fromLTRB(
            responsiveSpace(context, 16),
            responsiveSpace(context, 20),
            responsiveSpace(context, 16),
            0,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  responsiveSpace(context, 16),
                  responsiveSpace(context, 14),
                  responsiveSpace(context, 16),
                  0,
                ),
                child: Semantics(
                  header: true,
                  label: 'Cerca de ti, lugares cercanos a tu ubicación actual',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.near_me_rounded,
                        color: Color(0xFF82B1FF),
                        size: 18,
                      ),
                      SizedBox(width: responsiveSpace(context, 8)),
                      ExcludeSemantics(
                        child: Text(
                          'Cerca de ti',
                          textScaler: textScaler,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Divider(
                height: 1,
                thickness: 1,
                color: Color(0x15FFFFFF),
                indent: 16,
                endIndent: 16,
              ),
              const SizedBox(height: 6),
              ...nearby.map((p) {
                final d = p.distanceFrom(here.latitude, here.longitude);
                final dt = d >= 1000
                    ? '${(d / 1000).toStringAsFixed(1)} km'
                    : '${d.round()} m';

                return Semantics(
                  button: true,
                  label: '${p.name}, a $dt. Toca dos veces para navegar.',
                  onTap: () => onSelect(p),
                  child: ExcludeSemantics(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onSelect(p),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: responsiveSpace(context, 16),
                          vertical: responsiveSpace(context, 10),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1565C0).withOpacity(0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                geo.iconForPlace(p),
                                color: const Color(0xFF82B1FF),
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                p.name,
                                textScaler: textScaler,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1565C0).withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                dt,
                                textScaler: textScaler,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF82B1FF),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              const Divider(
                height: 1,
                thickness: 1,
                color: Color(0x15FFFFFF),
                indent: 16,
                endIndent: 16,
              ),
              // Botón "Ver más opciones cercanas" CORREGIDO
              Semantics(
                button: true,
                label: 'Ver más opciones cercanas',
                hint: 'Toca dos veces para explorar más lugares cerca de tu ubicación',
                onTap: onSeeMore,
                child: ExcludeSemantics(
                  child: InkWell(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    ),
                    onTap: onSeeMore,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: responsiveSpace(context, 16),
                        vertical: responsiveSpace(context, 14),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.expand_more_rounded,
                            color: Color(0xFF82B1FF),
                            size: 18,
                          ),
                          SizedBox(width: responsiveSpace(context, 6)),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Ver más opciones cercanas',
                                textScaler: textScaler,
                                style: const TextStyle(
                                  color: Color(0xFF82B1FF),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
          ),
        );
      },
    );
  }
}

// ── Header con gradiente ──
class _LocationHeader extends StatefulWidget {
  const _LocationHeader();
  @override
  State<_LocationHeader> createState() => _LocationHeaderState();
}

class _LocationHeaderState extends State<_LocationHeader> {
  String _address = '';
  double? _lastLat, _lastLng;

  Future<void> _fetchAddress(double lat, double lng) async {
    if (_lastLat == lat && _lastLng == lng) return;
    _lastLat = lat;
    _lastLng = lng;
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&accept-language=es',
      );
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'CampusGuiaEAFIT/1.0'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = data['address'] as Map<String, dynamic>? ?? {};
        final parts = <String>[];
        final road = addr['road'] ?? addr['pedestrian'] ?? addr['path'];
        final suburb =
            addr['suburb'] ?? addr['neighbourhood'] ?? addr['quarter'];
        final city = addr['city'] ?? addr['town'] ?? addr['municipality'];
        if (road != null) parts.add(road as String);
        if (suburb != null) parts.add(suburb as String);
        if (city != null && city != suburb) parts.add(city as String);
        if (mounted) setState(() => _address = parts.join(', '));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    return Consumer2<LocationService, GeoJsonService>(
      builder: (_, loc, geo, __) {
        String title = 'Buscando ubicación...';
        String subtitle = '';
        bool showEafit = false;

        if (loc.currentLocation != null) {
          final lat = loc.currentLocation!.latitude;
          final lng = loc.currentLocation!.longitude;
          if (geo.isLoaded && geo.isInsideCampus(lat, lng)) {
            final place = geo.getPlaceContaining(lat, lng);
            title = place?.name ?? 'Campus EAFIT';
            subtitle = place?.description.split('\n').first ?? '';
            showEafit = true;
          } else {
            title = 'Fuera del campus';
            _fetchAddress(lat, lng);
            subtitle = _address.isNotEmpty
                ? _address
                : 'Obteniendo dirección...';
          }
        } else {
          switch (loc.status) {
            case LocationStatus.permissionDenied:
              title = 'Permiso denegado';
              subtitle = 'Activa la ubicación en ajustes';
            case LocationStatus.disabled:
              title = 'GPS desactivado';
              subtitle = 'Activa el GPS para navegar';
            default:
              title = 'Buscando señal GPS...';
          }
        }

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
                  color: const Color(0xFF1565C0).withOpacity(0.35),
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
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          textScaler: clampedTextScaler(context, maxScale: 1.3),
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
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (showEafit) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(
                                Icons.school_rounded,
                                color: Colors.white38,
                                size: 13,
                              ),
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
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.25),
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
}

// ── Botón de categoría CORREGIDO para TalkBack ──
class _CatBtn extends StatelessWidget {
  final CategoryMeta cat;
  final void Function(CategoryMeta) onTap;
  const _CatBtn({required this.cat, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    return Semantics(
      button: true,
      label: cat.label,
      hint: 'Toca dos veces para explorar lugares',
      onTap: () => onTap(cat),
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: () => onTap(cat),
            borderRadius: BorderRadius.circular(16),
            splashColor: const Color(0xFF1565C0).withValues(alpha: 0.28),
            highlightColor: const Color(0xFF1565C0).withValues(alpha: 0.14),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: responsiveSpace(context, 90),
                  minWidth: 48,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: responsiveSpace(context, 6),
                    vertical: responsiveSpace(context, 8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: responsiveSpace(context, 40),
                        height: responsiveSpace(context, 40),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0).withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          cat.iconData,
                          color: const Color(0xFF82B1FF),
                          size: 22,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        cat.label,
                        textScaler: textScaler,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
