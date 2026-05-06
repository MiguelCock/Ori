import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../models/campus_place.dart';
import '../utils/accessibility_scale.dart';

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
    final textScaler = clampedTextScaler(context);
    final titleScaler = clampedTextScaler(context, maxScale: 1.3);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.place.name,
          textScaler: titleScaler,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: responsiveInsets(context, horizontal: 16, vertical: 16),
          child: Column(
            children: [
              Expanded(
                child: Semantics(
                  label: 'Seccion $key',
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          key.toUpperCase(),
                          textScaler: titleScaler,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: responsiveSpace(context, 10)),
                        Text(
                          value is List ? value.join('\n') : value.toString(),
                          textScaler: textScaler,
                          softWrap: true,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _prevSection,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Anterior', textScaler: textScaler),
                      ),
                    ),
                  ),
                  SizedBox(width: responsiveSpace(context, 12)),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _nextSection,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Siguiente', textScaler: textScaler),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
