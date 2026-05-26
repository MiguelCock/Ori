// ============================================================
// tutorial_screen.dart
// HU-27: Tutorial accesible inicial.
//
// Se muestra automáticamente la primera vez que se abre la app
// y también puede invocarse manualmente desde el botón Ayuda.
//
// Diseño:
//   - 6 pasos cortos, claros y orientados al uso principal.
//   - Auto-avance encadenado: el siguiente paso arranca al
//     terminar el TTS del anterior (sin requerir pulsaciones).
//     Si el lector de pantalla está activo se usa una duración
//     estimada por longitud de texto para no atropellar a
//     TalkBack / VoiceOver.
//   - Totalmente navegable con lector de pantalla: cada paso
//     se anuncia como liveRegion y los controles tienen
//     Semantics propios.
//   - Dos rutas de salida:
//       Ruta A — el usuario llega al final del tutorial.
//                Aparece una pantalla con "Repetir tutorial" y
//                "Terminar tutorial".
//       Ruta B — el usuario pulsa "Saltar" durante la
//                reproducción y se cierra inmediatamente.
//     "Saltar" sigue disponible durante cualquier repetición.
// ============================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/voice_guidance_service.dart';
import '../utils/accessibility_scale.dart';

const String kTutorialCompletedPrefKey = 'tutorial_completed';

class TutorialStep {
  final String title;
  final String body;
  const TutorialStep({required this.title, required this.body});

  String get spoken => '$title. $body';
}

const List<TutorialStep> _kTutorialSteps = [
  TutorialStep(
    title: 'Bienvenido a CampusGuía',
    body:
        'CampusGuía es tu guía de voz para moverte por la Universidad EAFIT. '
        'Este tutorial avanza solo y dura menos de un minuto. '
        'Si quieres saltarlo, pulsa el botón en la esquina superior derecha.',
  ),
  TutorialStep(
    title: 'Diseñada para tu lector de pantalla',
    body:
        'La aplicación es totalmente compatible con TalkBack y VoiceOver. '
        'Recorre los botones deslizando el dedo y actívalos tocando dos veces.',
  ),
  TutorialStep(
    title: 'Cómo empezar',
    body:
        'Al terminar el tutorial llegarás a la pantalla principal. '
        'Allí verás los tres lugares más cercanos a ti con su distancia. '
        'Toca cualquiera para que la aplicación calcule la ruta y te guíe.',
  ),
  TutorialStep(
    title: 'Explorar más destinos',
    body:
        'Si tu destino no está entre los cercanos, busca por categorías como '
        'bloques, baños, cafeterías o zonas de estudio. '
        'Cada categoría te muestra los lugares ordenados del más cerca al más lejos.',
  ),
  TutorialStep(
    title: 'Guía por voz durante el recorrido',
    body:
        'Durante la navegación, la aplicación te dará instrucciones paso a paso, '
        'te avisará cuando pases junto a puntos de referencia, '
        'y el celular vibrará al iniciar, al girar y al llegar al destino.',
  ),
  TutorialStep(
    title: 'Listo para empezar',
    body:
        'Si te alejas del camino o pierdes el GPS, la aplicación te avisará y '
        'recalculará la ruta. Eso es todo. '
        'Al terminar podrás repetir el tutorial o cerrarlo para usar la app.',
  ),
];

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  int _index = 0;
  bool _completed = false; // true cuando termina la voz del último paso
  bool _finishing = false;
  Timer? _advanceTimer;
  int _playToken = 0;

  final FocusNode _endActionFocus = FocusNode();

  TutorialStep get _step => _kTutorialSteps[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _announce(
        'Tutorial de CampusGuía. '
        'El tutorial avanza solo. '
        'Si quieres saltarlo, pulsa el botón saltar en la esquina superior derecha.',
      );
      // Pequeña pausa para que el anuncio inicial no se pise con el primer paso.
      Future.delayed(const Duration(milliseconds: 600), _playCurrentStep);
    });
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _playToken++;
    _endActionFocus.dispose();
    try {
      Provider.of<VoiceGuidanceService>(context, listen: false).stopSpeaking();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _announce(String message) {
    return SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  bool get _accessibilityActive {
    return SemanticsBinding.instance.semanticsEnabled ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .accessibleNavigation;
  }

  // Duración estimada para auto-avance cuando el TTS de la app está suprimido
  // (caso TalkBack/VoiceOver activos). Pensada para dar tiempo de lectura
  // cómoda al lector de pantalla sin ser estorbosa.
  Duration _estimatedReadingDuration(String text) {
    final seconds = (text.length / 13).clamp(4, 18).toDouble();
    const pause = Duration(milliseconds: 2000);
    return Duration(milliseconds: (seconds * 1000).round()) + pause;
  }

  void _playCurrentStep() {
    _advanceTimer?.cancel();
    final myToken = ++_playToken;

    if (!mounted) return;

    final voice = Provider.of<VoiceGuidanceService>(context, listen: false);
    final text = _step.spoken;

    // Si hay lector de pantalla, evitamos anunciar explícitamente para
    // no duplicar con el `liveRegion` del widget visual; dejamos que
    // el framework anuncie el contenido del paso.
    if (_accessibilityActive) {
      _scheduleAutoAdvance(myToken, _estimatedReadingDuration(text));
      return;
    }

    voice.speak(text).then((_) {
      if (!mounted) return;
      if (myToken != _playToken) return;
      _scheduleAutoAdvance(myToken, const Duration(milliseconds: 1200));
    }).catchError((_) {
      if (!mounted) return;
      if (myToken != _playToken) return;
      _scheduleAutoAdvance(myToken, _estimatedReadingDuration(text));
    });
  }

  void _scheduleAutoAdvance(int token, Duration delay) {
    _advanceTimer?.cancel();
    _advanceTimer = Timer(delay, () {
      if (!mounted) return;
      if (token != _playToken) return;
      if (_index >= _kTutorialSteps.length - 1) {
        _onTutorialPlaybackFinished();
      } else {
        setState(() => _index += 1);
        _playCurrentStep();
      }
    });
  }

  void _onTutorialPlaybackFinished() {
    setState(() => _completed = true);
    HapticFeedback.mediumImpact();
    _announce(
      'Tutorial completado. '
      'Pulsa Repetir tutorial para escucharlo de nuevo, '
      'o Terminar tutorial para cerrarlo e ir a la aplicación.',
    );
    // Llevar el foco a la acción principal del estado completado.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _endActionFocus.requestFocus();
    });
  }

  void _onRestartTutorial() {
    HapticFeedback.selectionClick();
    _advanceTimer?.cancel();
    _playToken++;
    try {
      Provider.of<VoiceGuidanceService>(context, listen: false).stopSpeaking();
    } catch (_) {}
    setState(() {
      _completed = false;
      _index = 0;
    });
    _announce('Reiniciando tutorial.');
    Future.delayed(const Duration(milliseconds: 400), _playCurrentStep);
  }

  Future<void> _finishTutorial({required bool completed}) async {
    if (_finishing) return;
    _finishing = true;
    _advanceTimer?.cancel();
    _playToken++;

    HapticFeedback.mediumImpact();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kTutorialCompletedPrefKey, true);
    } catch (_) {}

    if (!mounted) return;

    try {
      Provider.of<VoiceGuidanceService>(context, listen: false).stopSpeaking();
    } catch (_) {}

    _announce(completed ? 'Tutorial finalizado.' : 'Tutorial omitido.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = clampedTextScaler(context);
    final totalSteps = _kTutorialSteps.length;
    final stepNumber = _index + 1;

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: responsiveSpace(context, 20),
              vertical: responsiveSpace(context, 20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Barra superior: contador + Saltar (solo durante reproducción) ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Semantics(
                      header: true,
                      label: _completed
                          ? 'Tutorial de CampusGuía. Tutorial completado.'
                          : 'Tutorial de CampusGuía. Paso $stepNumber de $totalSteps.',
                      sortKey: const OrdinalSortKey(1),
                      child: ExcludeSemantics(
                        child: Row(
                          children: [
                            const Icon(
                              Icons.school_rounded,
                              size: 22,
                              color: Color(0xFF82B1FF),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _completed
                                  ? 'Tutorial completado'
                                  : 'Paso $stepNumber de $totalSteps',
                              textScaler: scaler,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_completed)
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(99),
                        child: Semantics(
                          sortKey: const OrdinalSortKey(99),
                          button: true,
                          label: 'Saltar tutorial',
                          hint:
                              'Toca dos veces para cerrar el tutorial e ir a la app.',
                          onTap: () => _finishTutorial(completed: false),
                          child: TextButton.icon(
                            onPressed: () => _finishTutorial(completed: false),
                            icon: const Icon(
                              Icons.skip_next_rounded,
                              color: Color(0xFF82B1FF),
                            ),
                            label: const Text(
                              'Saltar',
                              style: TextStyle(
                                color: Color(0xFF82B1FF),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(64, 44),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),

                // ── Indicador de progreso (decorativo) ──
                ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _completed ? 1.0 : stepNumber / totalSteps,
                      minHeight: 6,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFF82B1FF),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── Cuerpo: paso actual o pantalla de fin ──
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: _completed
                        ? _CompletionBody(scaler: scaler)
                        : _StepBody(
                            step: _step,
                            stepNumber: stepNumber,
                            totalSteps: totalSteps,
                            scaler: scaler,
                          ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Acciones del estado completado ──
                if (_completed) ...[
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(20),
                    child: Semantics(
                      sortKey: const OrdinalSortKey(20),
                      container: true,
                      explicitChildNodes: true,
                      excludeSemantics: true,
                      button: true,
                      enabled: true,
                      label: 'Repetir tutorial',
                      hint:
                          'Toca dos veces para escuchar el tutorial desde el principio.',
                      onTap: _onRestartTutorial,
                      child: OutlinedButton(
                        focusNode: _endActionFocus,
                        onPressed: _onRestartTutorial,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF82B1FF), width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 22),
                          minimumSize: const Size(double.infinity, 72),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.replay_rounded, size: 28),
                            SizedBox(width: 12),
                            Text('Repetir tutorial'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(21),
                    child: Semantics(
                      sortKey: const OrdinalSortKey(21),
                      container: true,
                      explicitChildNodes: true,
                      excludeSemantics: true,
                      button: true,
                      enabled: true,
                      label: 'Terminar tutorial',
                      hint:
                          'Toca dos veces para cerrar el tutorial e ir a la aplicación.',
                      onTap: () => _finishTutorial(completed: true),
                      child: ElevatedButton(
                        onPressed: () => _finishTutorial(completed: true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 22),
                          minimumSize: const Size(double.infinity, 72),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_rounded, size: 28),
                            SizedBox(width: 12),
                            Text('Terminar tutorial'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepBody extends StatelessWidget {
  final TutorialStep step;
  final int stepNumber;
  final int totalSteps;
  final TextScaler scaler;

  const _StepBody({
    required this.step,
    required this.stepNumber,
    required this.totalSteps,
    required this.scaler,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      sortKey: const OrdinalSortKey(2),
      liveRegion: true,
      label:
          'Paso $stepNumber de $totalSteps. ${step.title}. ${step.body}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.title,
              textScaler: scaler,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              step.body,
              textScaler: scaler,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 18,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletionBody extends StatelessWidget {
  final TextScaler scaler;
  const _CompletionBody({required this.scaler});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      sortKey: const OrdinalSortKey(2),
      liveRegion: true,
      label:
          'Tutorial completado. '
          'Puedes repetir el tutorial o terminarlo para ir a la aplicación.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.check_circle_outline_rounded,
              size: 56,
              color: Color(0xFF66BB6A),
            ),
            const SizedBox(height: 16),
            Text(
              'Tutorial completado',
              textScaler: scaler,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Pulsa "Repetir tutorial" para escucharlo de nuevo, '
              'o "Terminar tutorial" para ir a la aplicación.',
              textScaler: scaler,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 18,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
