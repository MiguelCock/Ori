import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// The upper panel of the navigation screen.
/// Contains the back/cancel button, destination title (semantic), current
/// instruction text, remaining distance, and the tap-to-repeat hint.
class NavigationHeader extends StatelessWidget {
  final String destinationName;
  final String instruction;
  final double? remainingDistanceMeters;
  final String semanticTitleLabel;
  final VoidCallback onCancel;

  const NavigationHeader({
    super.key,
    required this.destinationName,
    required this.instruction,
    required this.remainingDistanceMeters,
    required this.semanticTitleLabel,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          // ── Visual layer (hidden from TalkBack) ───────────────────────────
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title row (back button mirror + title + mirror)
                  SizedBox(
                    height: 48,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: Text(
                            destinationName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Main instruction
                  Expanded(
                    child: Center(
                      child: Text(
                        instruction,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                  // Distance
                  Text(
                    remainingDistanceMeters == null
                        ? 'Distancia restante no disponible.'
                        : 'Distancia restante: ${_formatDistance(remainingDistanceMeters!)}.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Toca la pantalla para repetir la indicación.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          // ── Semantic node 1: back button ──────────────────────────────────
          Positioned(
            left: 0,
            top: 10,
            child: Semantics(
              button: true,
              label: 'Finalizar navegación',
              hint: 'Detiene la navegación y regresa',
              excludeSemantics: true,
              child: IconButton(
                icon: const Icon(Icons.arrow_back,
                    color: Colors.white, size: 26),
                onPressed: onCancel,
                tooltip: 'Finalizar navegación',
                padding: const EdgeInsets.all(8),
              ),
            ),
          ),

          // ── Semantic node 2: title label ──────────────────────────────────
          Positioned(
            left: 48,
            right: 48,
            top: 10,
            height: 48,
            child: Semantics(
              label: semanticTitleLabel,
              excludeSemantics: true,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }
}