import 'dart:math' as math;

import 'package:flutter/material.dart';

double clampScaleFactor(
  BuildContext context, {
  double minScale = 0.8,
  double maxScale = 1.3,
}) {
  final scale = MediaQuery.textScalerOf(context).scale(1.0);
  return scale.clamp(minScale, maxScale).toDouble();
}

TextScaler clampedTextScaler(
  BuildContext context, {
  double minScale = 0.8,
  double maxScale = 1.3,
}) {
  return TextScaler.linear(
    clampScaleFactor(context, minScale: minScale, maxScale: maxScale),
  );
}

double responsiveSpace(
  BuildContext context,
  double value, {
  double min = 0.85,
  double max = 1.15,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final height = MediaQuery.sizeOf(context).height;
  final shortestSide = math.min(width, height);
  final factor = (shortestSide / 360).clamp(min, max).toDouble();
  return value * factor;
}

EdgeInsets responsiveInsets(
  BuildContext context, {
  double horizontal = 16,
  double vertical = 16,
}) {
  return EdgeInsets.symmetric(
    horizontal: responsiveSpace(context, horizontal),
    vertical: responsiveSpace(context, vertical),
  );
}
