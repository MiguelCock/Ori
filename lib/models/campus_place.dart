import 'dart:math';
import 'package:flutter/material.dart';

class CategoryMeta {
  final String id;
  final String label;
  final String icon;
  final int order;

  CategoryMeta({
    required this.id,
    required this.label,
    required this.icon,
    required this.order,
  });

  factory CategoryMeta.fromJson(String id, Map<String, dynamic> json) {
    return CategoryMeta(
      id: id,
      label: (json['label'] ?? id).toString(),
      icon: (json['icon'] ?? 'place').toString(),
      order: (json['order'] is num) ? (json['order'] as num).toInt() : 999,
    );
  }

  IconData get iconData {
    switch (icon) {
      case 'restaurant':
        return Icons.restaurant_rounded;
      case 'apartment':
        return Icons.apartment_rounded;
      case 'wc':
        return Icons.wc_rounded;
      case 'door_front_door':
        return Icons.door_front_door_rounded;
      case 'directions_car':
        return Icons.directions_car_rounded;
      case 'park':
        return Icons.park_rounded;
      case 'sports_soccer':
        return Icons.sports_soccer_rounded;
      default:
        return Icons.place_rounded;
    }
  }
}

class CampusPlace {
  final String name;
  final String description;
  final double latitude;
  final double longitude;
  final List<String> categories;
  final List<List<double>>? polygon;

  // HU-2: información básica
  final String buildingType;
  final String schedule;

  // HU-3: información ampliada
  final List<String> services;
  final String accessibilityInfo;
  final String extendedDescription;

  late final String searchableText;

  CampusPlace({
    required this.name,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.categories,
    this.polygon,
    this.buildingType = '',
    this.schedule = '',
    this.services = const [],
    this.accessibilityInfo = '',
    this.extendedDescription = '',
  }) {
    searchableText = '$name $description'.toLowerCase();
  }

  String get primaryCategory => categories.isEmpty ? 'unknown' : categories.first;

  double distanceFrom(double lat, double lng) {
    const R = 6371000.0;
    final dLat = _rad(lat - latitude);
    final dLon = _rad(lng - longitude);
    final a = sin(dLat/2)*sin(dLat/2) +
        cos(_rad(latitude))*cos(_rad(lat))*sin(dLon/2)*sin(dLon/2);
    return R * 2 * asin(sqrt(a));
  }

  double _rad(double deg) => deg * pi / 180;

  @override
  String toString() => name;
}