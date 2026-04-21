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
import 'destination_screen.dart';
import 'navigation_map_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
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
      _announce('Pantalla principal de CampusGuía. Siete categorías disponibles.');
    });
  }

  void _openCategory(CategoryMeta cat) {
    HapticFeedback.lightImpact();
    _announce('Abriendo ${cat.label}');
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final loc = Provider.of<LocationService>(context, listen: false);
    geo.filterByCategory(cat.id);
    Navigator.of(context).push(MaterialPageRoute(
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
    ));
  }

  // HU-13: Abre DestinationScreen con los 10 lugares más cercanos
  void _openNearby() {
    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final loc = Provider.of<LocationService>(context, listen: false);

    if (loc.currentLocation == null) {
      _announce('No se puede mostrar lugares cercanos. Ubicación no disponible.');
      return;
    }

    HapticFeedback.lightImpact();
    _announce('Abriendo más lugares cercanos a ti.');

    final here = loc.currentLocation!;
    geo.filterByProximity(here.latitude, here.longitude, limit: 10);

    Navigator.of(context).push(MaterialPageRoute(
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
    ));
  }

  Future<void> _onSelected(CampusPlace place) async {
    HapticFeedback.heavyImpact();
    final location = Provider.of<LocationService>(context, listen: false);
    final routing = Provider.of<RoutingService>(context, listen: false);
    final geo = Provider.of<GeoJsonService>(context, listen: false);

    if (location.currentLocation == null) {
      _announce('No se pudo generar la ruta. Ubicación actual no disponible.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Activa el GPS para generar la ruta.'),
          backgroundColor: Color(0xFFB00020),
        ),
      );
      return;
    }

    final origin = location.currentLocation!;
    final route = await routing.buildRoute(
      originLat: origin.latitude,
      originLng: origin.longitude,
      destinationLat: place.latitude,
      destinationLng: place.longitude,
    );

    final hasRoute = route != null;
    _announce(hasRoute
        ? 'Destino: ${place.name}. Ruta generada localmente.'
        : 'Destino: ${place.name}. No se pudo generar una ruta conectada.');
    if (!mounted) return;

    if (hasRoute) {
      final voice = Provider.of<VoiceGuidanceService>(context, listen: false);
      await voice.startNavigation(
        route: route,
        locationService: location,
        routingService: routing,
        destinationName: place.name,
        destinationLat: place.latitude,
        destinationLng: place.longitude,
        announceForTalkBack: _announce,
        landmarkResolver: (lat, lng) => geo.getNearestLandmark(lat, lng),
      );
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: Text(
          hasRoute ? 'Ruta generada' : 'Ruta no disponible',
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(place.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(place.description.split('\n').first,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            if (hasRoute) ...[
              Text('Distancia: ${route.totalDistanceMeters.round()} m',
                  style: const TextStyle(color: Color(0xFF82B1FF))),
              Text('Tiempo estimado: ${route.estimatedWalkTime.inMinutes} min',
                  style: const TextStyle(color: Color(0xFF82B1FF))),
              Text('Nodos de ruta: ${route.nodePath.length}',
                  style: const TextStyle(color: Color(0xFF82B1FF))),
              Text('Cálculo: ${route.computationTimeMs} ms',
                  style: const TextStyle(color: Color(0xFF82B1FF))),
            ] else ...[
              Text(
                routing.lastError.isEmpty
                    ? 'No hay conexión peatonal entre origen y destino.'
                    : routing.lastError,
                style: const TextStyle(color: Color(0xFFFF8A80)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar',
                style: TextStyle(color: Color(0xFF82B1FF))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1F3C), Color(0xFF081526)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const _LocationHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _VoiceGuidanceCard(),

                      // HU-13: Lista de 3 cercanos + botón ver más
                      _NearbySection(
                        onSeeMore: _openNearby,
                        onSelect: _onSelected,
                      ),

                      // Separador decorativo
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                        child: Row(
                          children: const [
                            Expanded(child: Divider(color: Colors.white12, thickness: 1)),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text('·  ·  ·',
                                  style: TextStyle(color: Colors.white24, fontSize: 12)),
                            ),
                            Expanded(child: Divider(color: Colors.white12, thickness: 1)),
                          ],
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                        child: Semantics(
                          header: true,
                          label: 'Categorías de lugares',
                          child: const ExcludeSemantics(
                            child: Text(
                              '¿A dónde quieres ir?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Consumer<GeoJsonService>(
                          builder: (_, geo, __) {
                            final cats = geo.categories;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final cat in cats)
                                  SizedBox(
                                    width: (MediaQuery.of(context).size.width - 56) / 3,
                                    child: _CatBtn(cat: cat, onTap: _openCategory),
                                  ),
                              ],
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
      ),
    );
  }
}

// ============================================================
// HU-13 — Sección "Cerca de ti"
// Lista original de 3 lugares más cercanos con distancia,
// más un botón "Ver más opciones cercanas" al final
// que abre DestinationScreen con los 10 más cercanos.
// ============================================================
class _NearbySection extends StatelessWidget {
  final VoidCallback onSeeMore;
  final Future<void> Function(CampusPlace) onSelect;

  const _NearbySection({required this.onSeeMore, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Consumer2<LocationService, GeoJsonService>(
      builder: (_, loc, geo, __) {
        if (loc.currentLocation == null || !geo.isLoaded) {
          return const SizedBox.shrink();
        }
        final here = loc.currentLocation!;
        final nearby = geo.getNearby(here.latitude, here.longitude, limit: 3);
        if (nearby.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 8,
                  offset: Offset(0, 3)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Semantics(
                  header: true,
                  label: 'Cerca de ti',
                  child: Row(
                    children: const [
                      Icon(Icons.near_me_rounded,
                          color: Color(0xFF82B1FF), size: 18),
                      SizedBox(width: 8),
                      ExcludeSemantics(
                        child: Text(
                          'Cerca de ti',
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
                  endIndent: 16),
              const SizedBox(height: 6),

              // Lista de 3 lugares (igual que el original + tapeable)
              ...nearby.map((p) {
                final d = p.distanceFrom(here.latitude, here.longitude);
                final dt = d >= 1000
                    ? '${(d / 1000).toStringAsFixed(1)} km'
                    : '${d.round()} m';

                return Semantics(
                  button: true,
                  label: '${p.name}, a $dt. Toca dos veces para navegar.',
                  onTap: () => onSelect(p),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onSelect(p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1565C0).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(geo.iconForPlace(p),
                                color: const Color(0xFF82B1FF), size: 18),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(p.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1565C0).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(dt,
                                style: const TextStyle(
                                    color: Color(0xFF82B1FF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),

              // Divisor
              const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0x15FFFFFF),
                  indent: 16,
                  endIndent: 16),

              // Botón "Ver más opciones cercanas"
              Semantics(
                button: true,
                label: 'Ver más opciones cercanas',
                hint: 'Toca dos veces para explorar más lugares cerca de ti.',
                onTap: onSeeMore,
                child: InkWell(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                  ),
                  onTap: onSeeMore,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.expand_more_rounded,
                              color: Color(0xFF82B1FF), size: 18),
                          SizedBox(width: 6),
                          Text(
                            'Ver más opciones cercanas',
                            style: TextStyle(
                              color: Color(0xFF82B1FF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
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
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&accept-language=es');
      final res = await http.get(uri,
          headers: {'User-Agent': 'CampusGuiaEAFIT/1.0'});
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
            subtitle =
                _address.isNotEmpty ? _address : 'Obteniendo dirección...';
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
          label: 'Ubicación actual: $title${subtitle.isNotEmpty ? ". $subtitle" : ""}',
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
                        const Text('Ubicación actual',
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                letterSpacing: 0.8)),
                        const SizedBox(height: 4),
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                height: 1.1)),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(subtitle,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                        if (showEafit) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: const [
                              Icon(Icons.school_rounded,
                                  color: Colors.white38, size: 13),
                              SizedBox(width: 4),
                              Text('Universidad EAFIT, Medellín',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 12)),
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
                          color: Colors.white.withOpacity(0.25), width: 1.5),
                    ),
                    child: const Icon(Icons.navigation_rounded,
                        color: Colors.white, size: 28),
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

// ── Tarjeta de guía por voz activa ──
class _VoiceGuidanceCard extends StatelessWidget {
  const _VoiceGuidanceCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<VoiceGuidanceService>(
      builder: (_, voice, __) {
        if (!voice.isNavigating) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF2E7D32).withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF66BB6A), width: 1),
          ),
          child: Semantics(
            label:
                'Navegación por voz activa. ${voice.currentInstruction}. Pasos restantes ${voice.remainingSteps}.',
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.record_voice_over_rounded,
                          color: Color(0xFFA5D6A7), size: 20),
                      SizedBox(width: 8),
                      Text('Guía por voz activa',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(voice.currentInstruction,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Text('Pasos restantes: ${voice.remainingSteps}',
                      style: const TextStyle(
                          color: Color(0xFFA5D6A7), fontSize: 12)),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        Provider.of<VoiceGuidanceService>(context, listen: false)
                            .stopNavigation();
                      },
                      icon: const Icon(Icons.stop_circle_rounded,
                          color: Color(0xFFFFCDD2), size: 18),
                      label: const Text('Detener voz',
                          style: TextStyle(color: Color(0xFFFFCDD2))),
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

// ── Botón de categoría ──
class _CatBtn extends StatelessWidget {
  final CategoryMeta cat;
  final void Function(CategoryMeta) onTap;
  const _CatBtn({required this.cat, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(cat.order.toDouble()),
      child: Semantics(
        sortKey: OrdinalSortKey(cat.order.toDouble()),
        button: true,
        label: cat.label,
        hint: 'Toca dos veces para ver ${cat.label}',
        onTap: () => onTap(cat),
        child: GestureDetector(
          onTap: () => onTap(cat),
          child: Container(
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 6,
                    offset: Offset(0, 3)),
              ],
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(cat.iconData,
                        color: const Color(0xFF82B1FF), size: 22),
                  ),
                  const SizedBox(height: 7),
                  Text(cat.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
