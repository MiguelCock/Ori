import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/voidce_guidance/voice_guidance.dart';

/// Outlined toggle button that enables or disables exploration mode.
/// Separated so it can be rebuilt independently via [Consumer].
class ExplorationToggle extends StatelessWidget {
  /// Called after toggling so the screen can send an accessibility announcement.
  final void Function(String message) onAnnounce;

  const ExplorationToggle({super.key, required this.onAnnounce});

  @override
  Widget build(BuildContext context) {
    return Consumer<VoiceGuidanceService>(
      builder: (_, voice, _) {
        final enabled = voice.explorationModeEnabled;
        return Semantics(
          button: true,
          label: enabled
              ? 'Modo exploración activado. Anunciará lugares al caminar sin '
                'necesidad de navegación. Toca dos veces para desactivar.'
              : 'Modo exploración desactivado. Toca dos veces para activar y '
                'escuchar lugares al caminar.',
          child: ExcludeSemantics(
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  voice.setExplorationModeEnabled(!enabled);
                  onAnnounce(
                    enabled
                        ? 'Modo exploración desactivado.'
                        : 'Modo exploración activado. '
                          'Escucharás anuncios de lugares al caminar.',
                  );
                },
                icon: Icon(
                  enabled
                      ? Icons.explore_rounded
                      : Icons.explore_off_rounded,
                  size: 20,
                ),
                label: Text(
                  enabled ? 'Exploración: activada' : 'Exploración: desactivada',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      enabled ? const Color(0xFF82B1FF) : Colors.white38,
                  side: BorderSide(
                    color: enabled
                        ? const Color(0xFF82B1FF)
                        : Colors.white24,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  minimumSize: const Size(double.infinity, 48),
                  textStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}