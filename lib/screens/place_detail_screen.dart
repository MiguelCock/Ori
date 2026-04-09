import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../models/campus_place.dart';
import '../services/voice_guidance_service.dart';

class PlaceDetailScreen extends StatefulWidget {
  final CampusPlace place;

  const PlaceDetailScreen({super.key, required this.place});

  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  // Accedemos al servicio de voz existente — es un singleton,
  // el mismo que usa la navegación
  final VoiceGuidanceService _voice = VoiceGuidanceService();

  // Envía el anuncio tanto por TTS como por TalkBack
  Future<void> _announce(String msg) async {
    await SemanticsService.sendAnnouncement(
      View.of(context),
      msg,
      Directionality.of(context),
    );
    await _voice.speak(msg);
  }

  Future<void> _readAll() async {
    final p = widget.place;
    final buffer = StringBuffer();

    buffer.write('Información de ${p.name}. ');

    if (p.buildingType.isNotEmpty) {
      buffer.write('Tipo de lugar: ${p.buildingType}. ');
    }
    if (p.schedule.isNotEmpty) {
      buffer.write('Horario: ${p.schedule}. ');
    }
    if (p.extendedDescription.isNotEmpty) {
      buffer.write('${p.extendedDescription}. ');
    }
    if (p.services.isNotEmpty) {
      buffer.write('Servicios disponibles: ${p.services.join(", ")}. ');
    }
    if (p.accessibilityInfo.isNotEmpty) {
      buffer.write('Accesibilidad: ${p.accessibilityInfo}.');
    }

    await _announce(buffer.toString());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readAll());
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.place;

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
          label: p.name,
          child: ExcludeSemantics(
            child: Text(
              p.name,
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _InfoSection(
              title: 'Descripción',
              content: p.extendedDescription.isNotEmpty
                  ? p.extendedDescription
                  : p.description,
            ),
            if (p.buildingType.isNotEmpty)
              _InfoSection(title: 'Tipo de lugar', content: p.buildingType),
            if (p.schedule.isNotEmpty)
              _InfoSection(title: 'Horario', content: p.schedule),
            if (p.services.isNotEmpty)
              _InfoSection(
                title: 'Servicios',
                content: p.services.join('\n'),
              ),
            if (p.accessibilityInfo.isNotEmpty)
              _InfoSection(
                title: 'Accesibilidad',
                content: p.accessibilityInfo,
              ),
            const SizedBox(height: 24),
            Semantics(
              button: true,
              label: 'Leer información nuevamente',
              hint: 'Toca dos veces para escuchar toda la información de este lugar',
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _readAll,
                  icon: const Icon(Icons.record_voice_over_rounded),
                  label: const Text('Leer información nuevamente'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF82B1FF)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final String title;
  final String content;

  const _InfoSection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$title: $content',
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2A3A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF82B1FF),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Text(
                content,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}