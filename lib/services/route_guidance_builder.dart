import 'dart:math';

import 'routing_service.dart';

class GuidanceStep {
  final RoutePoint endPoint;
  final String instruction;
  final double triggerDistanceMeters;

  const GuidanceStep({
    required this.endPoint,
    required this.instruction,
    required this.triggerDistanceMeters,
  });
}

class RouteGuidanceBuilder {
  static List<GuidanceStep> buildSteps({
    required List<RoutePoint> polyline,
    required double destinationLat,
    required double destinationLng,
    required String destinationName,
    ({String name, String side})? Function(
      double lat,
      double lng,
      double? headingDegrees,
    )?
    landmarkResolver,
    double? initialHeadingDegrees,
    double minInstructionDistanceMeters = 12,
    double straightBearingThresholdDegrees = 18.0,
    double turnBearingThresholdDegrees = 28.0,
  }) {
    final legs = _compactRouteLegs(
      polyline,
      straightBearingThresholdDegrees: straightBearingThresholdDegrees,
    );
    if (legs.isEmpty) return const [];

    final steps = <GuidanceStep>[];
    String? lastReference;

    for (int i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final reference = landmarkResolver?.call(
        leg.endPoint.latitude,
        leg.endPoint.longitude,
        leg.bearingDegrees,
      );

      final includeReference =
          reference != null && reference.name != lastReference;
      if (reference != null) {
        lastReference = reference.name;
      }

      final instruction = _legInstruction(
        leg: leg,
        previousLeg: i > 0 ? legs[i - 1] : null,
        isFinalLeg: i == legs.length - 1,
        initialHeadingDegrees: initialHeadingDegrees,
        includeReference: includeReference,
        reference: reference,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        destinationName: destinationName,
        turnBearingThresholdDegrees: turnBearingThresholdDegrees,
      );

      final trigger = max(
        i == legs.length - 1 ? 5.0 : minInstructionDistanceMeters,
        min(20.0, leg.distanceMeters * 0.35),
      );

      steps.add(
        GuidanceStep(
          endPoint: leg.endPoint,
          instruction: instruction,
          triggerDistanceMeters: trigger,
        ),
      );
    }

    return steps;
  }

  static List<_RouteLeg> _compactRouteLegs(
    List<RoutePoint> polyline, {
    required double straightBearingThresholdDegrees,
  }) {
    if (polyline.length < 2) return const [];

    final legs = <_RouteLeg>[];
    var segmentStart = polyline.first;
    var segmentEnd = polyline[1];
    var segmentDistance = _haversineMeters(
      segmentStart.latitude,
      segmentStart.longitude,
      segmentEnd.latitude,
      segmentEnd.longitude,
    );
    var segmentBearing = _bearingDegrees(segmentStart, segmentEnd);

    for (var i = 2; i < polyline.length; i++) {
      final nextPoint = polyline[i];
      final nextBearing = _bearingDegrees(segmentEnd, nextPoint);
      final delta = _normalizeAngle(nextBearing - segmentBearing);

      if (delta.abs() <= straightBearingThresholdDegrees) {
        segmentDistance += _haversineMeters(
          segmentEnd.latitude,
          segmentEnd.longitude,
          nextPoint.latitude,
          nextPoint.longitude,
        );
        segmentEnd = nextPoint;
        continue;
      }

      legs.add(
        _RouteLeg(
          startPoint: segmentStart,
          endPoint: segmentEnd,
          distanceMeters: segmentDistance,
          bearingDegrees: segmentBearing,
        ),
      );

      segmentStart = segmentEnd;
      segmentEnd = nextPoint;
      segmentDistance = _haversineMeters(
        segmentStart.latitude,
        segmentStart.longitude,
        segmentEnd.latitude,
        segmentEnd.longitude,
      );
      segmentBearing = _bearingDegrees(segmentStart, segmentEnd);
    }

    legs.add(
      _RouteLeg(
        startPoint: segmentStart,
        endPoint: segmentEnd,
        distanceMeters: segmentDistance,
        bearingDegrees: segmentBearing,
      ),
    );

    return legs;
  }

  static String _legInstruction({
    required _RouteLeg leg,
    required _RouteLeg? previousLeg,
    required bool isFinalLeg,
    required double? initialHeadingDegrees,
    required bool includeReference,
    required ({String name, String side})? reference,
    required double destinationLat,
    required double destinationLng,
    required String destinationName,
    required double turnBearingThresholdDegrees,
  }) {
    final movementText = 'avanza ${leg.distanceMeters.round()} metros';

    String baseInstruction;

    if (previousLeg == null) {
      baseInstruction = _initialOrientationInstruction(
        from: leg.startPoint,
        to: leg.endPoint,
        distanceMeters: leg.distanceMeters,
        deviceHeadingDegrees: initialHeadingDegrees,
      );
    } else {
      final delta = _normalizeAngle(
        leg.bearingDegrees - previousLeg.bearingDegrees,
      );
      if (delta.abs() >= turnBearingThresholdDegrees) {
        baseInstruction = 'GIRA ${_turnWord(delta)} y $movementText.';
      } else {
        baseInstruction = 'Continúa recto ${leg.distanceMeters.round()} metros.';
      }
    }

    if (isFinalLeg) {
      final arrival = _arrivalInstruction(
        leg,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        destinationName: destinationName,
      );
      if (includeReference && reference != null) {
        return '$baseInstruction $arrival. Pasarás junto a ${reference.name}${_referenceSideText(reference.side)}.';
      }
      return '$baseInstruction $arrival.';
    }

    if (includeReference && reference != null) {
      return '$baseInstruction Pasarás junto a ${reference.name}${_referenceSideText(reference.side)}.';
    }

    return baseInstruction;
  }

  static String _referenceSideText(String side) {
    switch (side) {
      case 'derecha':
        return ' a tu derecha';
      case 'izquierda':
        return ' a tu izquierda';
      case 'frente':
        return ' al frente';
      case 'detrás':
        return ' detrás de ti';
      default:
        return '';
    }
  }

  static String _initialOrientationInstruction({
    required RoutePoint from,
    required RoutePoint to,
    required double distanceMeters,
    required double? deviceHeadingDegrees,
  }) {
    if (deviceHeadingDegrees == null || deviceHeadingDegrees.isNaN) {
      return 'Avanza ${distanceMeters.round()} metros.';
    }

    final targetBearing = _bearingDegrees(from, to);
    final delta = _normalizeAngle(targetBearing - deviceHeadingDegrees);

    if (delta.abs() <= 30) {
      return 'Avanza hacia adelante ${distanceMeters.round()} metros.';
    }
    if (delta.abs() >= 150) {
      return 'Da media vuelta y avanza ${distanceMeters.round()} metros.';
    }

    return delta > 0
        ? 'GIRA a la derecha y avanza ${distanceMeters.round()} metros.'
        : 'GIRA a la izquierda y avanza ${distanceMeters.round()} metros.';
  }

  static String _turnWord(double delta) {
    return delta > 0 ? 'a la derecha' : 'a la izquierda';
  }

  static String _arrivalInstruction(
    _RouteLeg leg, {
    required double destinationLat,
    required double destinationLng,
    required String destinationName,
  }) {
    final destinationPoint = RoutePoint(
      latitude: destinationLat,
      longitude: destinationLng,
    );
    final destBearing = _bearingDegrees(leg.endPoint, destinationPoint);
    final referenceHeading = leg.bearingDegrees;
    final delta = _normalizeAngle(destBearing - referenceHeading);
    final destinationText = _normalizeText(destinationName);

    if (delta.abs() <= 30) {
      return 'Tu destino estará al frente. $destinationText';
    }
    if (delta.abs() >= 150) {
      return 'Tu destino estará detrás de ti. $destinationText';
    }

    return delta > 0
        ? 'Tu destino estará a tu derecha. $destinationText'
        : 'Tu destino estará a tu izquierda. $destinationText';
  }

  static String _normalizeText(String text) {
    return text
        .replaceAll('Ã¡', 'á')
        .replaceAll('Ã©', 'é')
        .replaceAll('Ã­', 'í')
        .replaceAll('Ã³', 'ó')
        .replaceAll('Ãº', 'ú')
        .replaceAll('Ã±', 'ñ')
        .replaceAll('Â', '');
  }

  static double _bearingDegrees(RoutePoint a, RoutePoint b) {
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final bearing = atan2(y, x) * 180.0 / pi;
    return (bearing + 360) % 360;
  }

  static double _normalizeAngle(double angle) {
    double a = angle;
    while (a > 180) a -= 360;
    while (a < -180) a += 360;
    return a;
  }

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return earthRadius * 2 * asin(sqrt(a));
  }

  static double _toRad(double deg) => deg * pi / 180.0;
}

class _RouteLeg {
  final RoutePoint startPoint;
  final RoutePoint endPoint;
  final double distanceMeters;
  final double bearingDegrees;

  const _RouteLeg({
    required this.startPoint,
    required this.endPoint,
    required this.distanceMeters,
    required this.bearingDegrees,
  });
}