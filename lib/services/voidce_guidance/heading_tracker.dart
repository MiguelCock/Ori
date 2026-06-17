import 'dart:async';
import 'dart:math';

import 'package:flutter_compass/flutter_compass.dart';

import '../routing/routing.dart'; // RoutePoint

/// Tracks the user's walking direction using GPS movement and compass data.
///
/// Responsibilities:
/// - Initial heading calibration (GPS movement + compass fusion).
/// - Ongoing walking heading updates from GPS deltas.
/// - Heading commitment on turns.
/// - Compacting a polyline into straight-ish [RouteLeg]s for map bearing.
class HeadingTracker {
  // ── Calibration tunables ──────────────────────────────────────────────────
  static const int _minHeadingSamples = 3;
  static const double _minMovementMetersForInitialHeading = 2.5;
  static const Duration _maxWaitForInitialHeading = Duration(seconds: 12);
  static const double _maxCompassDeviationDegrees = 30.0;
  static const double _minCompassConsistencyRatio = 0.75;

  // ── Ongoing heading tunables ──────────────────────────────────────────────
  static const double _minMovementMetersForHeadingUpdate = 2.5;
  static const double _straightBearingThresholdDegrees = 18.0;

  // ── State ─────────────────────────────────────────────────────────────────
  double? initialCalibratedHeading;
  double? latestWalkingHeading;
  double? committedHeading;
  RoutePoint? _lastHeadingSamplePoint;

  // ── Public: ongoing update ────────────────────────────────────────────────

  void reset({RoutePoint? seedPoint}) {
    initialCalibratedHeading = null;
    latestWalkingHeading = null;
    committedHeading = null;
    _lastHeadingSamplePoint = seedPoint;
  }

  /// Call on every GPS location update. Updates [latestWalkingHeading] when
  /// the user has moved enough since the last sample.
  void update(RoutePoint current) {
    final last = _lastHeadingSamplePoint;
    if (last == null) {
      _lastHeadingSamplePoint = current;
      return;
    }

    final moved = haversineMeters(
      last.latitude, last.longitude,
      current.latitude, current.longitude,
    );

    if (moved >= _minMovementMetersForHeadingUpdate) {
      latestWalkingHeading = bearingDegrees(last, current);
      _lastHeadingSamplePoint = current;
    }
  }

  /// Should be called when advancing to a turn step. Commits the current
  /// walking (or route-leg) heading so the map keeps a stable bearing.
  void commitOnTurn(String instruction, List<RouteLeg> legs, int stepIndex) {
    final isTurn = instruction.toUpperCase().contains('GIRA') ||
        instruction.toUpperCase().contains('MEDIA VUELTA');
    if (!isTurn) return;

    if (latestWalkingHeading != null) {
      committedHeading = latestWalkingHeading;
    } else if (legs.isNotEmpty) {
      final idx = stepIndex < legs.length ? stepIndex : legs.length - 1;
      committedHeading = legs[idx].bearingDegrees;
    }
  }

  /// Returns the best available reference heading for the map, in priority
  /// order: initial calibration → committed (post-turn) → walking → route leg.
  double? referenceHeading(List<RouteLeg> legs, int stepIndex, bool isFirst) {
    if (isFirst && initialCalibratedHeading != null) {
      return initialCalibratedHeading;
    }
    if (committedHeading != null) return committedHeading;
    if (latestWalkingHeading != null) return latestWalkingHeading;
    if (legs.isNotEmpty) {
      final idx = stepIndex < legs.length ? stepIndex : legs.length - 1;
      return legs[idx].bearingDegrees;
    }
    return initialCalibratedHeading;
  }

  // ── Initial calibration ───────────────────────────────────────────────────

  /// Waits up to [_maxWaitForInitialHeading] for the user to move, then fuses
  /// GPS-derived heading with compass samples. Returns null if neither source
  /// yields a reliable heading.
  Future<double?> calibrate({
    required RoutePoint? Function() currentPosition,
    required Future<void> Function(String) speak,
  }) async {
    await speak(
      'Para orientarte, mantén el teléfono apuntando al frente. '
      'Si puedes, camina en línea recta unos pasos para mejorar la precisión.',
    );

    final startPos = currentPosition();
    if (startPos == null) return null;

    final compassSamples = <double>[];
    StreamSubscription<CompassEvent>? compassSub;

    final stream = FlutterCompass.events;
    if (stream != null) {
      compassSub = stream.listen((e) {
        final h = e.heading;
        if (h != null && h.isFinite) compassSamples.add((h + 360) % 360);
      }, onError: (_) {});
    }

    double? gpsHeading;
    double movedMeters = 0;
    const checkInterval = Duration(milliseconds: 400);
    var elapsed = Duration.zero;

    try {
      while (elapsed < _maxWaitForInitialHeading) {
        await Future<void>.delayed(checkInterval);
        elapsed += checkInterval;

        final current = currentPosition();
        if (current == null) continue;

        movedMeters = haversineMeters(
          startPos.latitude, startPos.longitude,
          current.latitude, current.longitude,
        );

        if (movedMeters >= _minMovementMetersForInitialHeading) {
          gpsHeading = bearingDegrees(startPos, current);
          break;
        }
      }
    } finally {
      await compassSub?.cancel();
    }

    final compassHeading = _stableCompassHeading(compassSamples);

    if (gpsHeading == null) {
      if (compassHeading != null) {
        await speak('Orientación lista con brújula.');
        return compassHeading;
      }
      await speak(
        'No se detectó movimiento. '
        'La primera indicación puede no tener dirección precisa.',
      );
      return null;
    }

    if (compassHeading != null) {
      final delta = _normalizeAngle(compassHeading - gpsHeading).abs();
      if (movedMeters < 4.5 || delta >= 70) {
        await speak('Orientación lista.');
        return compassHeading;
      }
      // Weighted circular mean: 80 % GPS, 20 % compass.
      final gpsRad = _toRad(gpsHeading);
      final compassRad = _toRad(compassHeading);
      final combined = (atan2(
            0.8 * sin(gpsRad) + 0.2 * sin(compassRad),
            0.8 * cos(gpsRad) + 0.2 * cos(compassRad),
          ) *
              180 /
              pi +
          360) %
          360;
      await speak('Orientación lista.');
      return combined;
    }

    await speak('Orientación lista.');
    return gpsHeading;
  }

  // ── Route-leg compaction ──────────────────────────────────────────────────

  /// Merges consecutive collinear polyline segments into [RouteLeg]s so the
  /// map only rotates on real turns.
  static List<RouteLeg> compactLegs(List<RoutePoint> polyline) {
    if (polyline.length < 2) return const [];

    final legs = <RouteLeg>[];
    var segStart = polyline.first;
    var segEnd = polyline[1];
    var segDist = haversineMeters(
      segStart.latitude, segStart.longitude,
      segEnd.latitude, segEnd.longitude,
    );
    var segBearing = bearingDegrees(segStart, segEnd);

    for (var i = 2; i < polyline.length; i++) {
      final next = polyline[i];
      final nextBearing = bearingDegrees(segEnd, next);
      final delta = _normalizeAngle(nextBearing - segBearing);

      if (delta.abs() <= _straightBearingThresholdDegrees) {
        segDist += haversineMeters(
          segEnd.latitude, segEnd.longitude,
          next.latitude, next.longitude,
        );
        segEnd = next;
        continue;
      }

      legs.add(RouteLeg(
        startPoint: segStart,
        endPoint: segEnd,
        distanceMeters: segDist,
        bearingDegrees: segBearing,
      ));
      segStart = segEnd;
      segEnd = next;
      segDist = haversineMeters(
        segStart.latitude, segStart.longitude,
        segEnd.latitude, segEnd.longitude,
      );
      segBearing = bearingDegrees(segStart, segEnd);
    }

    legs.add(RouteLeg(
      startPoint: segStart,
      endPoint: segEnd,
      distanceMeters: segDist,
      bearingDegrees: segBearing,
    ));

    return legs;
  }

  // ── Math helpers (static, re-used internally) ────────────────────────────

  static double haversineMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return r * 2 * asin(sqrt(a));
  }

  static double bearingDegrees(RoutePoint a, RoutePoint b) {
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  static double _normalizeAngle(double a) {
    while (a > 180) {
      a -= 360;
    }
    while (a < -180) {
      a += 360;
    }
    return a;
  }

  static double _toRad(double deg) => deg * pi / 180;

  // ── Compass consistency ───────────────────────────────────────────────────

  double? _stableCompassHeading(List<double> samples) {
    if (samples.length < _minHeadingSamples) return null;
    final mean = _circularMean(samples);
    final consistent = samples
        .where((s) => _normalizeAngle(s - mean).abs() <= _maxCompassDeviationDegrees)
        .length;
    if (consistent / samples.length < _minCompassConsistencyRatio) return null;
    return mean;
  }

  double _circularMean(List<double> samples) {
    var sumSin = 0.0, sumCos = 0.0;
    for (final h in samples) {
      sumSin += sin(_toRad(h));
      sumCos += cos(_toRad(h));
    }
    if (sumSin.abs() < 1e-9 && sumCos.abs() < 1e-9) return samples.last;
    return (atan2(sumSin / samples.length, sumCos / samples.length) * 180 / pi +
            360) %
        360;
  }
}

// ── Value types ───────────────────────────────────────────────────────────────

class RouteLeg {
  final RoutePoint startPoint;
  final RoutePoint endPoint;
  final double distanceMeters;
  final double bearingDegrees;

  const RouteLeg({
    required this.startPoint,
    required this.endPoint,
    required this.distanceMeters,
    required this.bearingDegrees,
  });
}