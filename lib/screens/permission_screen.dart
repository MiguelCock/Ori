// ============================================================
// permission_screen.dart
// Pantalla de solicitud de permisos accesible
// Maneja ubicación y micrófono
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../services/permission_service.dart';

enum _FlowState { explaining, requesting, done }

class PermissionScreen extends StatefulWidget {
  final VoidCallback onPermissionsHandled;

  const PermissionScreen({
    super.key,
    required this.onPermissionsHandled,
  });

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  _FlowState _flowState = _FlowState.explaining;

  PermissionResult? _locationResult;
  PermissionResult? _micResult;

  bool _isProcessing = false;
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

  Future<void> _requestAllPermissions() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _flowState = _FlowState.requesting;
    });

    HapticFeedback.mediumImpact();

    _announce('Solicitando permiso de ubicación.');

    final locationResult = await PermissionService.request(AppPermission.location);
    if (!mounted) return;
    setState(() => _locationResult = locationResult);
    _announce(locationResult.message);
    await Future<Duration>.delayed(const Duration(milliseconds: 1500));

    _announce('Solicitando permiso de micrófono.');

    final micResult = await PermissionService.request(AppPermission.microphone);
    if (!mounted) return;
    setState(() {
      _micResult = micResult;
      _isProcessing = false;
      _flowState = _FlowState.done;
    });
    _announce(micResult.message);

    await Future<Duration>.delayed(const Duration(milliseconds: 1500));

    final bool allGranted = locationResult.isGranted && micResult.isGranted;
    _announce(
      allGranted
          ? 'Todos los permisos concedidos. La aplicación está lista.'
          : 'Permisos procesados con limitaciones. '
            'Puedes continuar usando las funciones disponibles.',
    );

    HapticFeedback.heavyImpact();
  }

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
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  label: 'Permisos de la aplicación',
                  child: ExcludeSemantics(
                    child: Column(
                      children: [
                        const Icon(Icons.security_rounded, size: 56, color: Color(0xFF82B1FF)),
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

                Semantics(
                  container: true,
                  sortKey: const OrdinalSortKey(1),
                  label: 'Lista de permisos. Dos elementos.',
                  child: Column(
                    children: [
                      _PermissionCard(
                        icon: Icons.location_on_rounded,
                        title: 'Ubicación',
                        reason: 'Para guiarte por los caminos y edificios del campus.',
                        result: _locationResult,
                      ),
                      const SizedBox(height: 16),
                      _PermissionCard(
                        icon: Icons.mic_rounded,
                        title: 'Micrófono',
                        reason: 'Para que puedas decir tu destino con tu voz.',
                        result: _micResult,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                if (_flowState == _FlowState.explaining || _flowState == _FlowState.requesting)
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
        button: true,
        label: _isProcessing
            ? 'Solicitando permisos, por favor espere.'
            : 'Conceder permisos. Permite que la app funcione correctamente.',
        hint: _isProcessing ? null : 'Toca dos veces para conceder los permisos.',
        onTap: _isProcessing ? null : _requestAllPermissions,
        child: ExcludeSemantics(
          child: ElevatedButton(
            focusNode: _actionButtonFocus,
            onPressed: _isProcessing ? null : _requestAllPermissions,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF1565C0).withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 24),
              minimumSize: const Size(double.infinity, 80),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            child: ExcludeSemantics(
              child: _isProcessing
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
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
      ),
    );
  }

  Widget _buildContinueButton() {
    final bool allGranted = (_locationResult?.isGranted ?? false) && (_micResult?.isGranted ?? false);

    return FocusTraversalOrder(
      order: const NumericFocusOrder(1),
      child: Semantics(
        button: true,
        label: allGranted
            ? 'Iniciar navegación. Todos los permisos están activos. Toca dos veces para continuar.'
            : 'Continuar con funciones limitadas. Toca dos veces para seguir.',
        onTap: _continueToNavigation,
        child: ExcludeSemantics(
          child: ElevatedButton(
            focusNode: _actionButtonFocus,
            onPressed: _continueToNavigation,
            style: ElevatedButton.styleFrom(
              backgroundColor: allGranted ? const Color(0xFF2E7D32) : const Color(0xFFE65100),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 24),
              minimumSize: const Size(double.infinity, 80),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            child: ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(allGranted ? Icons.navigation_rounded : Icons.warning_amber_rounded, size: 28),
                  const SizedBox(width: 12),
                  Text(allGranted ? 'Iniciar navegación' : 'Continuar (limitado)'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// _PermissionCard - Tarjeta de cada permiso
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

  String _buildSemanticLabel() {
    final base = 'Permiso de $title. $reason';
    if (result == null) return '$base Estado: pendiente.';
    switch (result!.status) {
      case PermissionStatus.granted:
        return '$base Estado: concedido.';
      case PermissionStatus.denied:
        return '$base Estado: denegado. Algunas funciones no estarán disponibles.';
      case PermissionStatus.permanentlyDenied:
        return '$base Estado: bloqueado permanentemente. Ve a Ajustes del sistema para activarlo.';
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

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _buildSemanticLabel(),
      sortKey: OrdinalSortKey(title == 'Ubicación' ? 1 : 2),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2A3A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor(), width: 1.5),
          ),
          child: Row(
            children: [
              Icon(icon, size: 36, color: const Color(0xFF82B1FF)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      reason,
                      style: const TextStyle(color: Colors.white60, fontSize: 14, height: 1.4),
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
}

// ── Chip visual de estado ──
class _StatusChip extends StatelessWidget {
  final PermissionStatus status;
  const _StatusChip({required this.status});

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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color().withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _color().withValues(alpha: 0.4)),
      ),
      child: Text(_label(), style: TextStyle(color: _color(), fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}
