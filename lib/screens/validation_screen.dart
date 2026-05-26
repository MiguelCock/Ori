import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';

class ValidationScreen extends StatefulWidget {
  final VoidCallback onValidationComplete;

  const ValidationScreen({
    super.key,
    required this.onValidationComplete,
  });

  @override
  State<ValidationScreen> createState() => _ValidationScreenState();
}

class _ValidationScreenState extends State<ValidationScreen> {
  bool _isLoading = true;

  // Resultados de validación
  bool _gpsAvailable = false;
  bool _vibrationAvailable = false;
  bool _talkBackActive = false;
  bool _ttsAvailable = false;

  // Control de bloqueo
  bool get _canContinue => _gpsAvailable && _ttsAvailable;

  final FocusNode _continueButtonFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runValidation();
    });
  }

  @override
  void dispose() {
    _continueButtonFocus.dispose();
    super.dispose();
  }

  Future<void> _announce(String message) async {
    await SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  Future<void> _runValidation() async {
    setState(() => _isLoading = true);

    await _announce('Iniciando comprobación de compatibilidad.');

    // 1. GPS
    _gpsAvailable = await _checkGPS();
    setState(() {});
    await _announce(_gpsAvailable ? 'GPS correcto.' : 'GPS no disponible.');

    // 2. TTS (Voz)
    _ttsAvailable = await _checkTTS();
    setState(() {});
    await _announce(_ttsAvailable ? 'Voz correcta.' : 'Voz no disponible.');

    // 3. Vibración
    _vibrationAvailable = await _checkVibration();
    setState(() {});
    await _announce(_vibrationAvailable ? 'Vibración correcta.' : 'Vibración no disponible.');

    // 4. TalkBack
    _talkBackActive = _checkTalkBack();
    setState(() {});
    await _announce(_talkBackActive ? 'TalkBack activado.' : 'TalkBack desactivado.');

    setState(() => _isLoading = false);

    // Resultado final
    if (!_gpsAvailable || !_ttsAvailable) {
      _showBlockingDialog();
    } else if (!_vibrationAvailable || !_talkBackActive) {
      await _announce(
        'Hay algunas advertencias en tu dispositivo. '
        'Para continuar presiona el botón Continuar a permisos por favor.',
      );
    } else {
      await _announce(
        'Tu dispositivo es completamente compatible con CampusGuía. '
        'Continuando automáticamente.',
      );
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) widget.onValidationComplete();
    }
  }

  Future<bool> _checkGPS() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      debugPrint('Error verificando GPS: $e');
      return false;
    }
  }

  Future<bool> _checkVibration() async {
    try {
      await HapticFeedback.vibrate();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _checkTalkBack() {
    try {
      final semanticsOn = SemanticsBinding.instance.semanticsEnabled;
      final accessibleNavOn = WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .accessibleNavigation;
      return semanticsOn || accessibleNavOn;
    } catch (e) {
      debugPrint('Error verificando TalkBack: $e');
      return false;
    }
  }

  Future<bool> _checkTTS() async {
    try {
      final tts = FlutterTts();
      final isLanguageAvailable = await tts.isLanguageAvailable('es-ES');
      return isLanguageAvailable;
    } catch (e) {
      debugPrint('Error verificando TTS: $e');
      return false;
    }
  }

  void _showBlockingDialog() {
    String missingComponents = '';
    if (!_gpsAvailable) missingComponents += 'GPS. ';
    if (!_ttsAvailable) missingComponents += 'Voz (TTS). ';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: const Text(
          'Componentes necesarios no disponibles',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: Text(
          'La aplicación no puede funcionar sin: $missingComponents\n\n'
          'Por favor, activa el GPS y asegúrate de que el motor de voz (TTS) '
          'esté instalado y configurado en español.\n\n'
          'Puedes instalar Google Text-to-Speech desde Play Store si es necesario.',
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runValidation();
            },
            child: const Text(
              'Reintentar',
              style: TextStyle(color: Color(0xFF82B1FF)),
            ),
          ),
        ],
      ),
    );
  }

  void _continueToPermissions() {
    if (!_canContinue) {
      _announce('No se puede continuar. GPS o voz no están disponibles.');
      return;
    }

    if (!_vibrationAvailable) {
      _announce(
        'La vibración no está disponible. Continuarás sin retroalimentación háptica.',
      );
    }

    if (!_talkBackActive) {
      _announce(
        'TalkBack no está activado. La experiencia puede ser menos accesible.',
      );
    }

    _announce('Continuando a pantalla de permisos.');
    widget.onValidationComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Encabezado
              Semantics(
                header: true,
                label: 'Validación de compatibilidad del dispositivo',
                child: ExcludeSemantics(
                  child: Column(
                    children: [
                      const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 56,
                        color: Color(0xFF82B1FF),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isLoading ? 'Validando...' : 'Validación completada',
                        style: Theme.of(context).textTheme.displaySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Lista de validaciones
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _ValidationItem(
                        icon: Icons.gps_fixed_rounded,
                        title: 'GPS',
                        isAvailable: _gpsAvailable,
                        isLoading: _isLoading,
                        isCritical: true,
                        message: _gpsAvailable
                            ? 'GPS disponible para navegación'
                            : 'GPS no disponible. La navegación no funcionará.',
                      ),
                      const SizedBox(height: 12),
                      _ValidationItem(
                        icon: Icons.record_voice_over_rounded,
                        title: 'Voz (TTS)',
                        isAvailable: _ttsAvailable,
                        isLoading: _isLoading,
                        isCritical: true,
                        message: _ttsAvailable
                            ? 'Motor de voz disponible'
                            : 'Motor de voz no disponible. La aplicación necesita voz.',
                      ),
                      const SizedBox(height: 12),
                      _ValidationItem(
                        icon: Icons.vibration_rounded,
                        title: 'Vibración',
                        isAvailable: _vibrationAvailable,
                        isLoading: _isLoading,
                        isCritical: false,
                        message: _vibrationAvailable
                            ? 'Vibración disponible'
                            : 'Vibración no disponible. No habrá feedback háptico.',
                      ),
                      const SizedBox(height: 12),
                      _ValidationItem(
                        icon: Icons.accessibility_new_rounded,
                        title: 'TalkBack',
                        isAvailable: _talkBackActive,
                        isLoading: _isLoading,
                        isCritical: false,
                        message: _talkBackActive
                            ? 'TalkBack activado'
                            : 'TalkBack desactivado. La app sigue funcionando.',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Botón continuar (solo habilitado si GPS y TTS están disponibles)
              if (!_isLoading)
                Semantics(
                  button: true,
                  label: _canContinue
                      ? 'Continuar a permisos. Todos los componentes necesarios están disponibles.'
                      : 'Continuar no disponible. GPS o voz no están disponibles.',
                  hint: _canContinue ? 'Toca dos veces para continuar' : null,
                  onTap: _canContinue ? _continueToPermissions : null,
                  child: ExcludeSemantics(
                    child: ElevatedButton(
                      focusNode: _continueButtonFocus,
                      onPressed: _canContinue ? _continueToPermissions : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _canContinue
                            ? const Color(0xFF1565C0)
                            : Colors.grey.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        minimumSize: const Size(double.infinity, 64),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      child: ExcludeSemantics(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _canContinue
                                  ? Icons.check_circle_rounded
                                  : Icons.block_rounded,
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _canContinue
                                  ? 'Continuar a permisos'
                                  : 'Componentes faltantes',
                            ),
                          ],
                        ),
                      ),
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
// _ValidationItem - Tarjeta de cada validación
// ============================================================
class _ValidationItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isAvailable;
  final bool isLoading;
  final bool isCritical;
  final String message;

  const _ValidationItem({
    required this.icon,
    required this.title,
    required this.isAvailable,
    required this.isLoading,
    required this.isCritical,
    required this.message,
  });

  Color _getStatusColor() {
    if (isLoading) return Colors.white24;
    if (isAvailable) return const Color(0xFF4CAF50);
    return isCritical ? const Color(0xFFF44336) : const Color(0xFFFF9800);
  }

  IconData _getStatusIcon() {
    if (isLoading) return Icons.hourglass_empty_rounded;
    if (isAvailable) return Icons.check_circle_rounded;
    return isCritical ? Icons.error_rounded : Icons.warning_amber_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$title. $message',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2A3A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _getStatusColor(), width: 1.5),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _getStatusColor().withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white54,
                          ),
                        ),
                      )
                    : Icon(icon, color: _getStatusColor(), size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: TextStyle(
                        color: isAvailable ? Colors.white60 : Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isLoading)
                Icon(_getStatusIcon(), color: _getStatusColor(), size: 24),
            ],
          ),
        ),
      ),
    );
  }
}