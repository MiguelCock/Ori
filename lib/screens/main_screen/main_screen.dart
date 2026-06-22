import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/campus_place.dart';
import '../../services/geojson_service.dart';
import '../../services/location_service.dart';
import '../../services/routing/routing.dart';
import '../../services/voidce_guidance/voice_guidance.dart';
import '../../utils/accessibility_scale.dart';
import '../destination_screen.dart';
import 'logic/navigation_handler.dart';
import 'widgets/category_grid.dart';
import 'widgets/exploration_toggle.dart';
import 'widgets/location_header.dart';
import 'widgets/nearby_section.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with NavigationHandlerMixin<MainScreen> {

  // ── NavigationHandlerMixin requirement ───────────────────────────────────

  @override
  Future<void> announce(String message) => SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LocationService>(context, listen: false).initialize();
      Provider.of<GeoJsonService>(context, listen: false).load();
      Provider.of<RoutingService>(context, listen: false).load();

      final voice =
          Provider.of<VoiceGuidanceService>(context, listen: false);
      voice.setLocationService(
          Provider.of<LocationService>(context, listen: false));
      voice.setGeoJsonService(
          Provider.of<GeoJsonService>(context, listen: false));
      voice.setAnnouncer(announce);

      announce('Pantalla principal de CampusGuía. Siete categorías disponibles.');
    });
  }

  // ── Category / nearby navigation ─────────────────────────────────────────

  void _openCategory(CategoryMeta cat) {
    HapticFeedback.lightImpact();
    announce('Abriendo ${cat.label}');

    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final loc = Provider.of<LocationService>(context, listen: false);
    geo.filterByCategory(cat.id);

    Navigator.of(context).push(MaterialPageRoute<dynamic>(
      builder: (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: geo),
          ChangeNotifierProvider.value(value: loc),
        ],
        child: DestinationScreen(
          categoryName: cat.label,
          onDestinationSelected: (place) {
            Navigator.of(context).pop();
            onDestinationSelected(place);
          },
        ),
      ),
    ));
  }

  void _openNearby() {
    final loc = Provider.of<LocationService>(context, listen: false);
    if (loc.currentLocation == null) {
      announce(
          'No se puede mostrar lugares cercanos. Ubicación no disponible.');
      return;
    }

    HapticFeedback.lightImpact();
    announce('Abriendo más lugares cercanos a ti.');

    final geo = Provider.of<GeoJsonService>(context, listen: false);
    final here = loc.currentLocation!;
    geo.filterByProximity(here.latitude, here.longitude, limit: 10);

    Navigator.of(context).push(MaterialPageRoute<dynamic>(
      builder: (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: geo),
          ChangeNotifierProvider.value(value: loc),
        ],
        child: DestinationScreen(
          categoryName: 'Cerca de ti',
          onDestinationSelected: (place) {
            Navigator.of(context).pop();
            onDestinationSelected(place);
          },
        ),
      ),
    ));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Column(
          children: [
            const LocationHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NearbySection(
                      onSeeMore: _openNearby,
                      onSelect: onDestinationSelected,
                    ),
                    _divider(),
                    _sectionLabel(context),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: responsiveSpace(context, 16),
                      ),
                      child: ExplorationToggle(onAnnounce: announce),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: responsiveSpace(context, 16),
                      ),
                      child: CategoryGrid(onCategoryTap: _openCategory),
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

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Row(
        children: [
          Expanded(child: Divider(color: Colors.white12, thickness: 1)),
          ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('·  ·  ·',
                  style: TextStyle(color: Colors.white24, fontSize: 12)),
            ),
          ),
          Expanded(child: Divider(color: Colors.white12, thickness: 1)),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context) {
    return Padding(
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
            textScaler: clampedTextScaler(context),
            softWrap: true,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}