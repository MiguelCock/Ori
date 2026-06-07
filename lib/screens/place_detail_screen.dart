import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../models/campus_place.dart';

class PlaceDetailScreen extends StatefulWidget {
  final CampusPlace place;

  const PlaceDetailScreen({super.key, required this.place});

  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  int _sectionIndex = 0;

  late Map<String, dynamic> info;
  late List<String> sections;

  @override
  void initState() {
    super.initState();
    info = widget.place.extendedInfo();
    sections = info.keys.toList();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _announceSection();
    });
  }

  void _announceSection() {
    final key = sections[_sectionIndex];
    final value = info[key];

    final text = "$key: ${value is List ? value.join(', ') : value}";
    SemanticsService.announce(text, TextDirection.ltr);
  }

  void _nextSection() {
    if (_sectionIndex < sections.length - 1) {
      setState(() => _sectionIndex++);
      _announceSection();
    }
  }

  void _prevSection() {
    if (_sectionIndex > 0) {
      setState(() => _sectionIndex--);
      _announceSection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = sections[_sectionIndex];
    final value = info[key];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.place.name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Sección actual
            Expanded(
              child: Semantics(
                label: 'Sección $key',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      key.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      value is List ? value.join('\n') : value.toString(),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

            // Navegación
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton(
                  onPressed: _prevSection,
                  child: const Text('Anterior'),
                ),
                ElevatedButton(
                  onPressed: _nextSection,
                  child: const Text('Siguiente'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}