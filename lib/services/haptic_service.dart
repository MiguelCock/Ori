
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

// Eventos de navegación que tienen patrón propio
enum HapticEvent {
  navigationStarted,  // Navegación iniciada → pulso largo
  turnInstruction,    // Instrucción de giro → corto + largo
  destinationReached, // Llegada al destino → tres pulsos
  routeRecalculated,  // Ruta recalculada   → dos pulsos medios
  error,              // Error o sin ruta   → dos pulsos rápidos
  selection,          // Selección de ítem  → un pulso suave (igual que antes)
}

class HapticService {
  static const MethodChannel _channel =
      MethodChannel('campus_guia/haptic');

  // Reproduce el patrón de vibración correspondiente al evento.
  // Si el canal falla (dispositivo sin vibrador, etc.) cae silenciosamente.
  static Future<void> trigger(HapticEvent event) async {
    if (kIsWeb) return;

    // Patrón: lista de pares [pausa, vibración] en milisegundos.
    // El primer valor siempre es la pausa inicial (normalmente 0).
    final List<int> pattern = _patternFor(event);

    try {
      final success = await _channel.invokeMethod<bool>(
        'vibrate',
        {'pattern': pattern},
      );
      debugPrint('HapticService: native vibrate returned: $success');
      if (success != true) {
        debugPrint('HapticService: native vibrate failed, using fallback');
        _fallback(event);
      }
    } on PlatformException catch (e) {
      debugPrint('HapticService error: ${e.message}');
      _fallback(event);
    } catch (e) {
      // Fallback silencioso: si el canal no existe todavía,
      // usamos HapticFeedback estándar de Flutter.
      _fallback(event);
    }
  }

  // Patrones por evento
  // Formato: [pausa_inicial, duración, pausa, duración, ...]
  static List<int> _patternFor(HapticEvent event) {
    switch (event) {
      case HapticEvent.navigationStarted:
        // Un pulso largo: confirma inicio
        return [0, 400];

      case HapticEvent.turnInstruction:
        // Corto + largo: aviso + confirmación de giro
        return [0, 100, 100, 300];

      case HapticEvent.destinationReached:
        // Tres pulsos: celebración de llegada
        return [0, 200, 100, 200, 100, 200];

      case HapticEvent.routeRecalculated:
        // Dos pulsos medios: cambio de ruta
        return [0, 150, 150, 150];

      case HapticEvent.error:
        // Dos pulsos rápidos: algo falló
        return [0, 80, 80, 80];

      case HapticEvent.selection:
        // Pulso suave: feedback de selección
        return [0, 50];
    }
  }

  // Fallback con HapticFeedback de Flutter si el canal no responde
  static void _fallback(HapticEvent event) {
    switch (event) {
      case HapticEvent.navigationStarted:
      case HapticEvent.destinationReached:
        HapticFeedback.heavyImpact();
        break;
      case HapticEvent.turnInstruction:
      case HapticEvent.routeRecalculated:
        HapticFeedback.mediumImpact();
        break;
      case HapticEvent.error:
      case HapticEvent.selection:
        HapticFeedback.lightImpact();
        break;
    }
  }
}