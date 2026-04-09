import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/geojson_service.dart';
import '../services/location_service.dart';
import '../models/campus_place.dart';
import '../screens/place_detail_screen.dart';

class DestinationScreen extends StatefulWidget {
  final String categoryName;
  final Function(CampusPlace) onDestinationSelected;

  const DestinationScreen({
    super.key,
    required this.categoryName,
    required this.onDestinationSelected,
  });

  @override
  State<DestinationScreen> createState() => _DestinationScreenState();
}

class _DestinationScreenState extends State<DestinationScreen> {
  static const int _groupSize = 6;

  CampusPlace? _selected;
  GeoJsonService? _geo;
  bool _didAnnounceOptions = false;
  List<List<CampusPlace>> _optionGroups = const [];
  int _nextGroupIndex = 0;

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
      _announce(
        'Lista de ${widget.categoryName}. '
        'Desliza para explorar los lugares. Toca dos veces para seleccionar.',
      );
      _geo = Provider.of<GeoJsonService>(context, listen: false);
      _geo?.addListener(_onGeoUpdated);
      _announceOptionsIfReady();
    });
  }

  @override
  void dispose() {
    _geo?.removeListener(_onGeoUpdated);
    super.dispose();
  }

  void _onGeoUpdated() {
    _announceOptionsIfReady();
  }

  Future<void> _announceOptionsIfReady() async {
    if (!mounted || _didAnnounceOptions) return;
    final geo = _geo;
    if (geo == null || !geo.isLoaded) return;

    final places = geo.places;
    if (places.isEmpty) {
      _didAnnounceOptions = true;
      await _announce('No hay opciones disponibles en ${widget.categoryName}.');
      return;
    }

    _optionGroups = _buildGroups(places);
    _nextGroupIndex = 0;
    _didAnnounceOptions = true;
    await _announce(
      'En ${widget.categoryName} hay ${places.length} opciones. '
      'Estan organizadas en ${_optionGroups.length} grupos. '
      'Voy a leerte el primer grupo. Usa el boton escuchar opciones para oir el siguiente grupo.',
    );
    await _announceNextGroup();
  }

  List<List<CampusPlace>> _buildGroups(List<CampusPlace> places) {
    final groups = <List<CampusPlace>>[];
    for (int i = 0; i < places.length; i += _groupSize) {
      final end = (i + _groupSize < places.length) ? i + _groupSize : places.length;
      groups.add(places.sublist(i, end));
    }
    return groups;
  }

  Future<void> _announceNextGroup() async {
    if (_optionGroups.isEmpty) {
      await _announce('No hay opciones para leer en este momento.');
      return;
    }

    if (_nextGroupIndex >= _optionGroups.length) {
      _nextGroupIndex = 0;
    }

    final group = _optionGroups[_nextGroupIndex];
    final start = _nextGroupIndex * _groupSize + 1;
    final end = start + group.length - 1;
    final names = group.map((p) => p.name).join('. ');

    await _announce(
      'Grupo ${_nextGroupIndex + 1} de ${_optionGroups.length}. '
      'Opciones $start a $end: $names.',
    );

    _nextGroupIndex++;
    if (_nextGroupIndex >= _optionGroups.length) {
      _nextGroupIndex = 0;
    }
  }

  void _onTap(CampusPlace place) {
    setState(() => _selected = place);
    HapticFeedback.lightImpact();
    _announce('Seleccionado: ${place.name}. Toca Confirmar al final para continuar.');
  }

  void _confirm() {
    if (_selected == null) return;
    HapticFeedback.heavyImpact();
    widget.onDestinationSelected(_selected!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A237E),
        elevation: 0,
        leading: Semantics(
          button: true,
          label: 'Volver',
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Semantics(
          header: true,
          label: widget.categoryName,
          child: ExcludeSemantics(
            child: Text(widget.categoryName,
                style: const TextStyle(color: Colors.white, fontSize: 20)),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _PlaceList(
              selected: _selected,
              onTap: _onTap,
            )),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Semantics(
                button: true,
                label: 'Escuchar opciones de nuevo',
                hint: 'Lee el siguiente grupo de opciones de ruta',
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      await _announceNextGroup();
                    },
                    icon: const Icon(Icons.record_voice_over_rounded),
                    label: const Text('Escuchar opciones de nuevo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF82B1FF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            ),
            _ConfirmButton(
              selected: _selected,
              onConfirm: _confirm,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceList extends StatelessWidget {
  final CampusPlace? selected;
  final void Function(CampusPlace) onTap;
  const _PlaceList({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Consumer2<GeoJsonService, LocationService>(
      builder: (_, geo, loc, __) {
        if (!geo.isLoaded) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF1565C0)),
          );
        }

        final places = geo.places;

        if (places.isEmpty) {
          return Semantics(
            label: 'No se encontraron lugares en esta categoría',
            child: const Center(
              child: ExcludeSemantics(
                child: Text(
                  'No hay lugares en esta categoría',
                  style: TextStyle(color: Colors.white54, fontSize: 16),
                ),
              ),
            ),
          );
        }

        final here = loc.currentLocation;

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          itemCount: places.length,
          itemBuilder: (_, i) {
            final place = places[i];
            final isSelected = selected == place;
            String distText = '';
            if (here != null) {
              final d = place.distanceFrom(here.latitude, here.longitude);
              distText = d >= 1000
                  ? 'A ${(d/1000).toStringAsFixed(1)} km'
                  : 'A ${d.round()} m';
            }

            return Semantics(
              container: true,
              explicitChildNodes: true,
              excludeSemantics: true,
              button: true,
              selected: isSelected,
              enabled: true,
              label: isSelected
                ? 'Opción ${i + 1} de ${places.length}: ${place.name}${distText.isNotEmpty ? ", $distText" : ""}. Seleccionado'
                : 'Opción ${i + 1} de ${places.length}: ${place.name}${distText.isNotEmpty ? ", $distText" : ""}',
              hint: isSelected
                  ? 'Ya seleccionado. Toca Confirmar para continuar'
                  : 'Toca dos veces para seleccionar. Mantén presionado para escuchar información del lugar',
              onTap: () => onTap(place),
              onLongPress: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PlaceDetailScreen(place: place),
                  ),
                );
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                    color: isSelected
                      ? const Color(0xFF1565C0).withValues(alpha: 0.25)
                      : const Color(0xFF1A2A3A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF1565C0)
                        : Colors.white12,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  onTap: () => onTap(place),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF1565C0)
                          : const Color(0xFF0D1B2A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(geo.iconForPlace(place),
                        color: isSelected
                          ? Colors.white
                          : const Color(0xFF82B1FF),
                        size: 22),
                  ),
                  title: ExcludeSemantics(
                    child: Text(place.name,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 16,
                        )),
                  ),
                  subtitle: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.description.split('\n').first,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (distText.isNotEmpty)
                          Text(distText,
                              style: const TextStyle(
                                  color: Color(0xFF82B1FF), fontSize: 12)),
                      ],
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle_rounded,
                          color: Color(0xFF1565C0), size: 22)
                      : Semantics(
                          button: true,
                          label: 'Ver información de ${place.name}',
                          hint: 'Toca dos veces para escuchar los detalles de este lugar',
                          child: IconButton(
                            icon: const Icon(
                              Icons.info_outline_rounded,
                              color: Color(0xFF82B1FF),
                              size: 22,
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => PlaceDetailScreen(place: place),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  final CampusPlace? selected;
  final VoidCallback onConfirm;
  const _ConfirmButton({required this.selected, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final hasSelection = selected != null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Semantics(
        button: true,
        label: hasSelection ? 'Confirmar' : 'Confirmar. Primero selecciona un lugar',
        hint: hasSelection ? 'Toca dos veces para confirmar' : '',
        child: SizedBox(
          width: double.infinity,
          height: 60,
          child: ElevatedButton(
            onPressed: hasSelection ? onConfirm : null,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  hasSelection ? const Color(0xFF2E7D32) : Colors.grey[800],
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              textStyle: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            child: ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    hasSelection
                        ? Icons.check_circle_rounded
                        : Icons.touch_app_rounded,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  const Text('Confirmar'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}