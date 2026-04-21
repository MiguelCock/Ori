// Servicio de geolocalización en tiempo real: Maneja permisos, precisión y estados del GPS

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

// Modelo de datos de ubicación
class LocationData {
  final double latitude;
  final double longitude;
  final double accuracy; // Precisión en metros
  final double speed; // Velocidad en m/s
  final double? heading; // Orientación del dispositivo en grados
  final DateTime timestamp;

  LocationData({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.timestamp,
  });

  // Crear desde Position de geolocator
  factory LocationData.fromPosition(Position position) {
    return LocationData(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading.isFinite && position.heading >= 0
          ? position.heading
          : null,
      timestamp: position.timestamp,
    );
  }

  // Verificar si la ubicación es válida para navegación
  bool get isValidForNavigation =>
      accuracy <= 15.0; // Precisión mínima 15 metros

  @override
  String toString() {
    return 'Lat: $latitude, Lon: $longitude, Precisión: ${accuracy.toStringAsFixed(1)}m';
  }
}

// Estados posibles del GPS
enum LocationStatus {
  initializing,
  active,
  lowAccuracy,
  noSignal,
  permissionDenied,
  disabled,
}

class LocationService extends ChangeNotifier {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  LocationStatus _status = LocationStatus.initializing;
  LocationData? _currentLocation;
  String _lastError = '';

  Stream<Position>? _positionStream;

  // Getters
  LocationStatus get status => _status;
  LocationData? get currentLocation => _currentLocation;
  String get lastError => _lastError;
  bool get hasValidLocation =>
      _currentLocation != null && _currentLocation!.isValidForNavigation;

  // Inicializar y comenzar a escuchar ubicación
  Future<void> initialize() async {
    try {
      // Verificar si el GPS está habilitado
      bool isLocationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isLocationEnabled) {
        _updateStatus(LocationStatus.disabled);
        _announce(
          'El GPS está desactivado. Actívalo en ajustes para usar la navegación.',
        );
        return;
      }

      // Verificar permisos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _updateStatus(LocationStatus.permissionDenied);
          _announce('Permiso de ubicación denegado.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _updateStatus(LocationStatus.permissionDenied);
        _announce(
          'Permiso de ubicación bloqueado permanentemente. Ve a ajustes para activarlo.',
        );
        return;
      }

      // Configurar y comenzar a escuchar ubicación
      await _startListening();
    } catch (e) {
      _lastError = 'Error al inicializar GPS: $e';
      _updateStatus(LocationStatus.noSignal);
      debugPrint(_lastError);
    }
  }

  // Iniciar escucha en tiempo real
  Future<void> _startListening() async {
    // En Android usamos AndroidSettings para forzar explícitamente el uso del
    // FusedLocationProvider de Google Play Services, que combina GPS + WiFi +
    // Cell towers con filtro Kalman interno — más preciso que el GPS puro.
    // forceLocationManager: false  →  FusedLocationProvider (recomendado)
    // forceLocationManager: true   →  Android LocationManager nativo (menos preciso)
    final LocationSettings locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            forceLocationManager: false, // Usar FusedLocationProvider
            intervalDuration: const Duration(seconds: 1),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    );

    // Escuchar actualizaciones
    _positionStream!.listen(_handlePositionUpdate, onError: _handleError);

    // Obtener una ubicación inicial inmediata
    // timeLimit evita que la app se cuelgue si el GPS tarda en adquirir señal
    try {
      Position initialPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 15),
      );
      _handlePositionUpdate(initialPosition);
    } catch (e) {
      // No es fatal: el stream seguirá entregando posiciones una vez haya señal
      debugPrint('GPS: posición inicial no disponible aún — $e');
    }
  }

  // Manejar actualización de posición
  void _handlePositionUpdate(Position position) {
    // Filtro de calidad: si ya tenemos una posición buena (< 15m) y llega una
    // muy mala (> 30m), la descartamos para evitar saltos bruscos en la ruta.
    // Si aún no tenemos ninguna posición, aceptamos cualquier precisión.
    if (_currentLocation != null &&
        _currentLocation!.accuracy < 15.0 &&
        position.accuracy > 30.0) {
      debugPrint(
        'GPS: posición descartada (precisión ${position.accuracy.toStringAsFixed(1)}m > 30m, manteniendo la anterior).',
      );
      return;
    }

    LocationData newLocation = LocationData.fromPosition(position);
    final previousStatus = _status;

    // Determinar estado según precisión
    final LocationStatus newStatus = position.accuracy <= 15.0
        ? LocationStatus.active
        : LocationStatus.lowAccuracy;

    // Anunciar cambios importantes de estado
    if (_status != newStatus) {
      switch (newStatus) {
        case LocationStatus.active:
          if (_status == LocationStatus.lowAccuracy) {
            _announce('Señal GPS recuperada.');
          }
          break;
        case LocationStatus.lowAccuracy:
          _announce(
            'Precisión GPS baja. La navegación puede ser menos precisa.',
          );
          break;
        default:
          break;
      }
    }

    _currentLocation = newLocation;
    _updateStatus(newStatus);

    if (previousStatus == newStatus) {
      notifyListeners();
    }
  }

  // Manejar errores del stream
  void _handleError(error) {
    _lastError = 'Error en GPS: $error';
    _updateStatus(LocationStatus.noSignal);
    _announce('Se perdió la señal GPS. Busca un área abierta.');
    debugPrint(_lastError);
  }

  // Actualizar estado y notificar
  void _updateStatus(LocationStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      notifyListeners();
    }
  }

  // Anuncio accesible
  void _announce(String message) {
    debugPrint('TalkBack: $message');
  }

  // Verificar si se puede iniciar navegación
  bool canStartNavigation() {
    if (_status == LocationStatus.disabled ||
        _status == LocationStatus.permissionDenied) {
      return false;
    }

    if (_currentLocation == null) {
      return false;
    }

    return true;
  }

  // Obtener mensaje de estado para el usuario
  String getStatusMessage() {
    switch (_status) {
      case LocationStatus.initializing:
        return 'Inicializando GPS...';
      case LocationStatus.active:
        return 'GPS activo';
      case LocationStatus.lowAccuracy:
        return 'Precisión baja';
      case LocationStatus.noSignal:
        return 'Sin señal GPS';
      case LocationStatus.permissionDenied:
        return 'Permiso denegado';
      case LocationStatus.disabled:
        return 'GPS desactivado';
    }
  }
}
