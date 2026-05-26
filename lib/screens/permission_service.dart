// ============================================================
// permission_service.dart
// Servicio centralizado de permisos
// Maneja ubicación, micrófono y audio de forma accesible
// Usa platform channels de Flutter
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ── Enumeración de permisos que maneja la app ──
enum AppPermission { location, microphone }

// ── Estado posible de un permiso ──
enum PermissionStatus { granted, denied, permanentlyDenied, unknown }

// ── Resultado de una solicitud de permiso ──
class PermissionResult {
  final AppPermission permission;
  final PermissionStatus status;
  final String message; // Mensaje accesible para TalkBack

  const PermissionResult({
    required this.permission,
    required this.status,
    required this.message,
  });

  bool get isGranted => status == PermissionStatus.granted;
}

// ============================================================
// PermissionService
// Usa MethodChannel para comunicarse con el código nativo
// Android y gestionar permisos en tiempo de ejecución.
// ============================================================
class PermissionService {
  static const MethodChannel _channel =
      MethodChannel('campus_guia/permissions');

  // Solicita un permiso y retorna el resultado con mensaje accesible
  static Future<PermissionResult> request(AppPermission permission) async {
    if (kIsWeb) {
      return PermissionResult(
        permission: permission,
        status: PermissionStatus.denied,
        message: 'Gestión de permisos nativos no disponible en versión web. '
            'Puedes continuar con funciones compatibles con navegador.',
      );
    }

    try {
      final String permissionKey = _toKey(permission);
      final String result = await _channel.invokeMethod(
        'requestPermission',
        {'permission': permissionKey},
      );
      return _buildResult(permission, result);
    } on PlatformException catch (e) {
      // Si el channel falla, se trata como denegado
      // para que la app no falle — criterio de aceptación: no falla si rechaza
      debugPrint('PermissionService error: ${e.message}');
      return PermissionResult(
        permission: permission,
        status: PermissionStatus.denied,
        message: _deniedMessage(permission),
      );
    }
  }

  // Verifica si un permiso ya fue concedido sin pedirlo de nuevo
  static Future<PermissionStatus> check(AppPermission permission) async {
    if (kIsWeb) {
      return PermissionStatus.unknown;
    }

    try {
      final String permissionKey = _toKey(permission);
      final String result = await _channel.invokeMethod(
        'checkPermission',
        {'permission': permissionKey},
      );
      return _toStatus(result);
    } on PlatformException {
      return PermissionStatus.unknown;
    }
  }

  // ── Helpers privados ──

  static String _toKey(AppPermission p) {
    switch (p) {
      case AppPermission.location:
        return 'location';
      case AppPermission.microphone:
        return 'microphone';
    }
  }

  static PermissionStatus _toStatus(String result) {
    switch (result) {
      case 'granted':
        return PermissionStatus.granted;
      case 'permanently_denied':
        return PermissionStatus.permanentlyDenied;
      case 'denied':
      default:
        return PermissionStatus.denied;
    }
  }

  static PermissionResult _buildResult(AppPermission p, String result) {
    final status = _toStatus(result);
    String message;
    switch (status) {
      case PermissionStatus.granted:
        message = _grantedMessage(p);
        break;
      case PermissionStatus.permanentlyDenied:
        message = _permanentlyDeniedMessage(p);
        break;
      case PermissionStatus.denied:
      default:
        message = _deniedMessage(p);
    }
    return PermissionResult(permission: p, status: status, message: message);
  }

  // ── Mensajes accesibles por permiso y estado ──
  // Los mensajes son específicos y accionables para que TalkBack
  // comunique exactamente qué pasó y qué puede hacer el usuario.

  static String _grantedMessage(AppPermission p) {
    switch (p) {
      case AppPermission.location:
        return 'Permiso de ubicación concedido. La navegación está lista.';
      case AppPermission.microphone:
        return 'Permiso de micrófono concedido. Puedes usar comandos de voz.';
    }
  }

  static String _deniedMessage(AppPermission p) {
    switch (p) {
      case AppPermission.location:
        return 'Permiso de ubicación denegado. '
            'No podrás usar la navegación GPS. '
            'Puedes cambiar esto en Ajustes del sistema.';
      case AppPermission.microphone:
        return 'Permiso de micrófono denegado. '
            'No podrás usar comandos de voz. '
            'Puedes navegar usando el teclado o los botones.';
    }
  }

  static String _permanentlyDeniedMessage(AppPermission p) {
    switch (p) {
      case AppPermission.location:
        return 'El permiso de ubicación fue bloqueado permanentemente. '
            'Ve a Ajustes del sistema, luego Aplicaciones, '
            'luego CampusGuía, luego Permisos, y activa Ubicación.';
      case AppPermission.microphone:
        return 'El permiso de micrófono fue bloqueado permanentemente. '
            'Ve a Ajustes del sistema, luego Aplicaciones, '
            'luego CampusGuía, luego Permisos, y activa Micrófono.';
    }
  }
}