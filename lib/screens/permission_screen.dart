// ============================================================
// permission_screen.dart
// Pantalla de solicitud de permisos accesible
// Muestra explicación del permiso, lo solicita y maneja
// todos los estados posibles con feedback para TalkBack
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'permission_service.dart';

// ============================================================
// PermissionScreen
// Se muestra antes de iniciar la navegación.
// Solicita permisos en orden: primero ubicación, luego micrófono.
// Si alguno se deniega, informa y permite continuar de todas formas.
// ============================================================
class PermissionScreen extends StatefulWidget {
  // Callback que se llama cuando los permisos fueron procesados
  // (concedidos o denegados) y la app puede continuar.
  final VoidCallback onPermissionsHandled;

  const PermissionScreen({
    super.key,
    required this.onPermissionsHandled,
  });

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  // Estado del flujo de permisos
  _FlowState _flowState = _FlowState.explaining;

  // Resultados de cada permiso
  PermissionResult? _locationResult;
  PermissionResult? _micResult;

  // Controla si estamos procesando una solicitud (evita doble tap)
  bool _isProcessing = false;

  // FocusNode para el botón de acción principal
  final FocusNode _actionButtonFocus = FocusNode();

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
    // Anunciar la pantalla al abrirse
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _announce(
        'Pantalla de permisos. '
        'Para navegar por el campus necesitamos tu permiso de ubicación. '
        'Para usar comandos de voz necesitamos acceso al micrófono. '
        'El botón Conceder permisos se encuentra al centro de la pantalla.',
      );
      Future.delayed(
        const Duration(milliseconds: 800),
        () { if (mounted) _actionButtonFocus.requestFocus(); },
      );
    });
  }

  @override
  void dispose() {
    _actionButtonFocus.dispose();
    super.dispose();
  }

  // ── Flujo principal: solicita permisos en secuencia ──
  Future<void> _requestAllPermissions() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _flowState = _FlowState.requesting;
    });

    HapticFeedback.mediumImpact();

    // ── 1. Permiso de ubicación ──
    _announce(
      'Solicitando permiso de ubicación. '
      'Aparecerá un cuadro de diálogo del sistema.',
    );

    final locationResult = await PermissionService.request(
      AppPermission.location,
    );

    if (!mounted) return;
    setState(() => _locationResult = locationResult);

    // Anunciar resultado de ubicación
    _announce(locationResult.message);
    await Future.delayed(const Duration(milliseconds: 1500));

    // ── 2. Permiso de micrófono ──
    _announce(
      'Solicitando permiso de micrófono. '
      'Aparecerá un cuadro de diálogo del sistema.',
    );

    final micResult = await PermissionService.request(
      AppPermission.microphone,
    );

    if (!mounted) return;
    setState(() {
      _micResult = micResult;
      _isProcessing = false;
      _flowState = _FlowState.done;
    });

    // Anunciar resultado de micrófono
    _announce(micResult.message);

    await Future.delayed(const Duration(milliseconds: 1500));

    // ── 3. Resumen final accesible ──
    final bool allGranted =
        locationResult.isGranted && micResult.isGranted;

    _announce(
      allGranted
          ? 'Todos los permisos concedidos. La aplicación está lista.'
          : 'Permisos procesados con limitaciones. '
            'Puedes continuar usando las funciones disponibles.',
    );

    HapticFeedback.heavyImpact();
  }

  // ── Continuar hacia la navegación ──
  void _continueToNavigation() {
    HapticFeedback.heavyImpact();
    _announce('Continuando a la pantalla de navegación.');
    widget.onPermissionsHandled();
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 32.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Encabezado ──
                Semantics(
                  header: true,
                  label: 'Permisos de la aplicación',
                  child: ExcludeSemantics(
                    child: Column(
                      children: [
                        const Icon(
                          Icons.security_rounded,
                          size: 56,
                          color: Color(0xFF82B1FF),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Permisos necesarios',
                          style: Theme.of(context).textTheme.displaySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── Tarjetas de permiso ──
                Semantics(
                  container: true,
                  sortKey: const OrdinalSortKey(1),
                  label: 'Lista de permisos. Dos elementos.',
                  child: Column(
                    children: [
                      _PermissionCard(
                        icon: Icons.location_on_rounded,
                        title: 'Ubicación',
                        reason:
                            'Para guiarte por los caminos y edificios del campus '
                            'con instrucciones precisas de a dónde girar.',
                        result: _locationResult,
                      ),
                      const SizedBox(height: 16),
                      _PermissionCard(
                        icon: Icons.mic_rounded,
                        title: 'Micrófono',
                        reason:
                            'Para que puedas decir tu destino con tu voz '
                            'en lugar de escribirlo.',
                        result: _micResult,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // ── Botón de acción principal (cambia según el estado) ──
                if (_flowState == _FlowState.explaining ||
                    _flowState == _FlowState.requesting)
                  _buildRequestButton(),

                if (_flowState == _FlowState.done)
                  _buildContinueButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestButton() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(1),
      child: Semantics(
        sortKey: const OrdinalSortKey(2),
        button: true,
        liveRegion: _isProcessing,
        label: _isProcessing
            ? 'Solicitando permisos, por favor espere.'
            : 'Conceder permisos. Permite que la app funcione correctamente.',
        hint: _isProcessing
            ? null
            : 'Toca dos veces para conceder los permisos de ubicación y micrófono.',
        onTap: _isProcessing ? null : _requestAllPermissions,
        child: ElevatedButton(
          focusNode: _actionButtonFocus,
          onPressed: _isProcessing ? null : _requestAllPermissions,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF1565C0).withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(vertical: 24),
            minimumSize: const Size(double.infinity, 80),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          child: ExcludeSemantics(
            child: _isProcessing
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      ),
                      SizedBox(width: 16),
                      Text('Solicitando...'),
                    ],
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 28),
                      SizedBox(width: 12),
                      Text('Conceder permisos'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildContinueButton() {
    final bool allGranted =
        (_locationResult?.isGranted ?? false) &&
        (_micResult?.isGranted ?? false);

    return FocusTraversalOrder(
      order: const NumericFocusOrder(1),
      child: Semantics(
        sortKey: const OrdinalSortKey(2),
        button: true,
        liveRegion: true,
        label: allGranted
            ? 'Continuar a navegación. Todos los permisos están activos.'
            : 'Continuar con funciones limitadas. '
              'Algunos permisos no fueron concedidos.',
        hint: 'Toca dos veces para ir a la pantalla de navegación.',
        onTap: _continueToNavigation,
        child: ElevatedButton(
          focusNode: _actionButtonFocus,
          onPressed: _continueToNavigation,
          style: ElevatedButton.styleFrom(
            backgroundColor: allGranted
                ? const Color(0xFF2E7D32)
                : const Color(0xFFE65100),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 24),
            minimumSize: const Size(double.infinity, 80),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          child: ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  allGranted
                      ? Icons.navigation_rounded
                      : Icons.warning_amber_rounded,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  allGranted ? 'Iniciar navegación' : 'Continuar (limitado)',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Estado interno del flujo ──
enum _FlowState { explaining, requesting, done }

// ============================================================
// _PermissionCard
// Tarjeta que muestra el estado de un permiso individual.
// Completamente accesible: TalkBack lee el nombre, la razón
// y el estado actual del permiso.
// ============================================================
class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String reason;
  final PermissionResult? result;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.reason,
    this.result,
  });

  @override
  Widget build(BuildContext context) {
    // Construir el label semántico completo según el estado
    final String semanticLabel = _buildSemanticLabel();

    return Semantics(
      label: semanticLabel,
      sortKey: OrdinalSortKey(title == 'Ubicación' ? 1 : 2),
      // Las tarjetas no son botones, solo información de estado
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2A3A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _borderColor(),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              // Ícono del permiso
              Icon(icon, size: 36, color: const Color(0xFF82B1FF)),
              const SizedBox(width: 16),
              // Texto
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
                      reason,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    if (result != null) ...[
                      const SizedBox(height: 8),
                      _StatusChip(status: result!.status),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildSemanticLabel() {
    final base = 'Permiso de $title. $reason';
    if (result == null) return '$base Estado: pendiente.';
    switch (result!.status) {
      case PermissionStatus.granted:
        return '$base Estado: concedido.';
      case PermissionStatus.denied:
        return '$base Estado: denegado. Algunas funciones no estarán disponibles.';
      case PermissionStatus.permanentlyDenied:
        return '$base Estado: bloqueado permanentemente. '
            'Ve a Ajustes del sistema para activarlo.';
      case PermissionStatus.unknown:
        return '$base Estado: desconocido.';
    }
  }

  Color _borderColor() {
    if (result == null) return Colors.white12;
    switch (result!.status) {
      case PermissionStatus.granted:
        return const Color(0xFF4CAF50);
      case PermissionStatus.denied:
        return const Color(0xFFFF9800);
      case PermissionStatus.permanentlyDenied:
        return const Color(0xFFF44336);
      case PermissionStatus.unknown:
        return Colors.white12;
    }
  }
}

// ── Chip visual de estado ──
class _StatusChip extends StatelessWidget {
  final PermissionStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color().withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _color().withValues(alpha: 0.4)),
      ),
      child: Text(
        _label(),
        style: TextStyle(
          color: _color(),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _label() {
    switch (status) {
      case PermissionStatus.granted:
        return '✓ Concedido';
      case PermissionStatus.denied:
        return '✗ Denegado';
      case PermissionStatus.permanentlyDenied:
        return '⊘ Bloqueado';
      case PermissionStatus.unknown:
        return '? Pendiente';
    }
  }

  Color _color() {
    switch (status) {
      case PermissionStatus.granted:
        return const Color(0xFF4CAF50);
      case PermissionStatus.denied:
        return const Color(0xFFFF9800);
      case PermissionStatus.permanentlyDenied:
        return const Color(0xFFF44336);
      case PermissionStatus.unknown:
        return Colors.white38;
    }
  }
}