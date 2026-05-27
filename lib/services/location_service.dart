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

// Callback para anunciar mensajes al usuario (TTS o TalkBack)
typedef LocationAnnouncer = Future<void> Function(String message);

class LocationService extends ChangeNotifier {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  LocationStatus _status = LocationStatus.initializing;
  LocationData? _currentLocation;
  String _lastError = '';
  bool _simulationMode = false;

  // Callback inyectado desde la UI para hablar mensajes de estado del GPS.
  // Si no se asigna, los mensajes solo se imprimen en consola.
  LocationAnnouncer? _announcer;

  Stream<Position>? _positionStream;

  // Getters
  LocationStatus get status => _status;
  LocationData? get currentLocation => _currentLocation;
  String get lastError => _lastError;
  bool get isSimulationMode => _simulationMode;
  bool get hasValidLocation =>
      _currentLocation != null && _currentLocation!.isValidForNavigation;

  /// Asigna el callback que se usará para anunciar mensajes de estado GPS.
  /// Debe llamarse desde VoiceGuidanceService o la capa de UI con acceso
  /// a TTS / SemanticsService.
  void setAnnouncer(LocationAnnouncer announcer) {
    _announcer = announcer;
  }

  // Inicializar y comenzar a escuchar ubicación
  Future<void> initialize() async {
    try {
      if (_simulationMode) return;
      // Verificar si el GPS está habilitado
      bool isLocationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isLocationEnabled) {
        _updateStatus(LocationStatus.disabled);
        await _announce(
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
          await _announce('Permiso de ubicación denegado.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _updateStatus(LocationStatus.permissionDenied);
        await _announce(
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
    if (_simulationMode) return;
    final LocationSettings locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            forceLocationManager: false,
            intervalDuration: const Duration(milliseconds: 500),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    );

    _positionStream!.listen(_handlePositionUpdate, onError: _handleError);

    try {
      Position initialPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 15),
      );
      _handlePositionUpdate(initialPosition);
    } catch (e) {
      debugPrint('GPS: posición inicial no disponible aún — $e');
    }
  }

  // Manejar actualización de posición
  void _handlePositionUpdate(Position position) {
    if (_simulationMode) return;
    if (_currentLocation != null &&
        _currentLocation!.accuracy < 15.0 &&
        position.accuracy > 50.0) {
      debugPrint(
        'GPS: posición descartada (precisión ${position.accuracy.toStringAsFixed(1)}m > 50m, manteniendo la anterior).',
      );
      return;
    }

    LocationData newLocation = LocationData.fromPosition(position);
    final previousStatus = _status;

    final LocationStatus newStatus = position.accuracy <= 15.0
        ? LocationStatus.active
        : LocationStatus.lowAccuracy;

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
    if (_simulationMode) return;
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

  void startSimulation() {
    _simulationMode = true;
    _updateStatus(LocationStatus.active);
  }

  void stopSimulation() {
    _simulationMode = false;
    notifyListeners();
  }

  void seedLocation(LocationData location) {
    _currentLocation = location;
    _status = location.isValidForNavigation
        ? LocationStatus.active
        : LocationStatus.lowAccuracy;
    notifyListeners();
  }

  void setSimulatedLocation(LocationData location) {
    _simulationMode = true;
    seedLocation(location);
  }

  // Anuncio accesible — usa el callback si está disponible, si no solo log.
  Future<void> _announce(String message) async {
    debugPrint('GPS_ANNOUNCE: $message');
    await _announcer?.call(message);
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