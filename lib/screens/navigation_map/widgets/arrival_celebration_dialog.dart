import 'package:flutter/material.dart';

import '../../../services/haptic_service.dart';

/// Full-screen celebratory dialog shown on arrival.
/// Auto-dismisses after ~1.2 seconds.
class ArrivalCelebrationDialog extends StatefulWidget {
  final String destination;

  const ArrivalCelebrationDialog({super.key, required this.destination});

  @override
  State<ArrivalCelebrationDialog> createState() =>
      _ArrivalCelebrationDialogState();
}

class _ArrivalCelebrationDialogState extends State<ArrivalCelebrationDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await HapticService.trigger(HapticEvent.destinationReached);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B1620),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale:
                  CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
              child: const Icon(
                Icons.celebration_rounded,
                size: 64,
                color: Color(0xFF66BB6A),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Has llegado',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.destination,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'La navegación se cerrará en un momento.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}