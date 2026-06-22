import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/campus_place.dart';
import '../../../services/geojson_service.dart';
import '../../../services/location_service.dart';
import '../../../utils/accessibility_scale.dart';

/// "Cerca de ti" card showing the three nearest places and a "see more" button.
class NearbySection extends StatelessWidget {
  final VoidCallback onSeeMore;
  final Future<void> Function(CampusPlace) onSelect;

  const NearbySection({
    super.key,
    required this.onSeeMore,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer2<LocationService, GeoJsonService>(
      builder: (_, loc, geo, _) {
        if (loc.currentLocation == null || !geo.isDataLoaded) {
          return const SizedBox.shrink();
        }

        final here = loc.currentLocation!;
        final nearby =
            geo.getNearby(here.latitude, here.longitude, limit: 3);
        if (nearby.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: EdgeInsets.fromLTRB(
            responsiveSpace(context, 16),
            responsiveSpace(context, 20),
            responsiveSpace(context, 16),
            0,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
              _Header(context: context),
              const SizedBox(height: 10),
              const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0x15FFFFFF),
                  indent: 16,
                  endIndent: 16),
              const SizedBox(height: 6),
              ...nearby.map((p) => _PlaceRow(
                    place: p,
                    userLat: here.latitude,
                    userLng: here.longitude,
                    icon: geo.iconForPlace(p),
                    onSelect: onSelect,
                  )),
              const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0x15FFFFFF),
                  indent: 16,
                  endIndent: 16),
              _SeeMoreButton(onSeeMore: onSeeMore),
              const SizedBox(height: 2),
            ],
          ),
        );
      },
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final BuildContext context;
  const _Header({required this.context});

  @override
  Widget build(BuildContext ctx) {
    final textScaler = clampedTextScaler(ctx);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        responsiveSpace(ctx, 16),
        responsiveSpace(ctx, 14),
        responsiveSpace(ctx, 16),
        0,
      ),
      child: Semantics(
        header: true,
        label: 'Cerca de ti, lugares cercanos a tu ubicación actual',
        child: Row(
          children: [
            const Icon(Icons.near_me_rounded,
                color: Color(0xFF82B1FF), size: 18),
            SizedBox(width: responsiveSpace(ctx, 8)),
            ExcludeSemantics(
              child: Text(
                'Cerca de ti',
                textScaler: textScaler,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  final CampusPlace place;
  final double userLat;
  final double userLng;
  final IconData icon;
  final Future<void> Function(CampusPlace) onSelect;

  const _PlaceRow({
    required this.place,
    required this.userLat,
    required this.userLng,
    required this.icon,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    final d = place.distanceFrom(userLat, userLng);
    final dt = d >= 1000
        ? '${(d / 1000).toStringAsFixed(1)} km'
        : '${d.round()} m';

    return Semantics(
      button: true,
      label: '${place.name}, a $dt. Toca dos veces para navegar.',
      onTap: () => onSelect(place),
      child: ExcludeSemantics(
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSelect(place),
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
                    color: const Color(0xFF1565C0).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: const Color(0xFF82B1FF), size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    place.name,
                    textScaler: textScaler,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.2),
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
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SeeMoreButton extends StatelessWidget {
  final VoidCallback onSeeMore;
  const _SeeMoreButton({required this.onSeeMore});

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    return Semantics(
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
                const Icon(Icons.expand_more_rounded,
                    color: Color(0xFF82B1FF), size: 18),
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
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}