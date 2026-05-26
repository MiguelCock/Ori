import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/geojson_service.dart';
import '../services/location_service.dart';
import '../models/campus_place.dart';
import 'place_detail_screen.dart';

class DestinationScreen extends StatefulWidget {
  final String categoryName;
  final void Function(CampusPlace) onDestinationSelected;

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
        'Desliza para explorar los lugares. Toca dos veces para seleccionar y abrir el lugar.',
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
    _announce('Seleccionado: ${place.name}. Abriendo...');
    // Abrir inmediatamente la navegación o detalle sin paso extra de confirmación
    widget.onDestinationSelected(place);
  }

  void _confirm() {
    // Método obsoleto: la selección abre directamente.
    if (_selected == null) return;
    HapticFeedback.heavyImpact();
    widget.onDestinationSelected(_selected!);
  }

  @override
  Widget build(BuildContext context) {
    // HU-19: textScaleFactor para detectar fuente grande del sistema
    final textScale = MediaQuery.of(context).textScaler.scale(1.0);
    final isLargeText = textScale > 1.3;

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
            child: Text(
              widget.categoryName,
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Lista ocupa el espacio disponible
            Expanded(
              child: _PlaceList(
                selected: _selected,
                onTap: _onTap,
              ),
            ),

            // HU-19: Botones en columna cuando la fuente es grande,
            // para que no se salgan de pantalla
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: isLargeText
                  ? _buildButtonsColumn()
                  : _buildButtonsNormal(),
            ),
          ],
        ),
      ),
    );
  }

  // Layout normal (fuente estándar): botones uno debajo del otro
  Widget _buildButtonsNormal() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildListenButton(),
        if (_selected != null) ...[
          const SizedBox(height: 4),
          _buildInfoButton(),
          const SizedBox(height: 4),
          _buildDetailButton(),
        ],
      ],
    );
  }

  // HU-19: Layout fuente grande — igual estructura, menos padding vertical
  Widget _buildButtonsColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildListenButton(compact: true),
        if (_selected != null) ...[
          const SizedBox(height: 2),
          _buildInfoButton(compact: true),
          const SizedBox(height: 2),
          _buildDetailButton(compact: true),
        ],
      ],
    );
  }

  Widget _buildListenButton({bool compact = false}) {
    return Semantics(
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
            // HU-19: padding vertical adaptable
            padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoButton({bool compact = false}) {
    return Semantics(
      button: true,
      label: 'Escuchar información del lugar seleccionado',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () async {
            await _speakBasicInfo(_selected!);
          },
          icon: const Icon(Icons.info_outline),
          label: const Text('Escuchar información'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFF82B1FF)),
            padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailButton({bool compact = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PlaceDetailScreen(place: _selected!),
            ),
          );
        },
        icon: const Icon(Icons.menu_book),
        label: const Text('Ver información detallada'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFF82B1FF)),
          padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
        ),
      ),
    );
  }

  

  Future<void> _speakBasicInfo(CampusPlace place) async {
    final info = place.basicInfo();
    final message = '''
${info['nombre']}.
Tipo: ${info['tipo']}.
${info['descripcion']}.
${info['horario']}.
''';
    await _announce(message);
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
                  ? 'A ${(d / 1000).toStringAsFixed(1)} km'
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
                  ? 'Opción ${i + 1} de ${places.length}: ${place.name}'
                      '${distText.isNotEmpty ? ", $distText" : ""}. Seleccionado'
                  : 'Opción ${i + 1} de ${places.length}: ${place.name}'
                      '${distText.isNotEmpty ? ", $distText" : ""}',
                hint: isSelected
                  ? 'Seleccionado. Toca dos veces para abrir la navegación'
                  : 'Toca dos veces para seleccionar y abrir',
              onTap: () => onTap(place),
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
                    child: Icon(
                      geo.iconForPlace(place),
                      color: isSelected ? Colors.white : const Color(0xFF82B1FF),
                      size: 22,
                    ),
                  ),
                  title: ExcludeSemantics(
                    child: Text(
                      place.name,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 16,
                      ),
                    ),
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
                          Text(
                            distText,
                            style: const TextStyle(
                                color: Color(0xFF82B1FF), fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle_rounded,
                          color: Color(0xFF1565C0), size: 22)
                      : null,
                ),
              ),
            );
          },
        );
      },
    );
  }
}