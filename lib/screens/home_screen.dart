import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main_screen/main_screen.dart';
import 'permission_screen.dart';
import 'tutorial_screen.dart';
import 'validation_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FocusNode _mainButtonFocusNode = FocusNode();
  bool _checking = true;

  static const _prefKey = 'permissions_accepted';

  Future<void> _announce(String message) {
    return SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runStartupFlow();
    });
  }

  Future<void> _runStartupFlow() async {
    if (!mounted) return;

    // HU-27: la primera vez que se abre la app mostramos el tutorial
    final prefs = await SharedPreferences.getInstance();
    final tutorialCompleted = prefs.getBool(kTutorialCompletedPrefKey) ?? false;

    if (!tutorialCompleted) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<TutorialScreen>(builder: (_) => const TutorialScreen()),
      );
    }

    if (!mounted) return;

    // HU-21: Validación de compatibilidad (solo primera vez)
    final validationCompleted = prefs.getBool('validation_completed') ?? false;
    if (!validationCompleted) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<ValidationScreen>(
          builder: (_) => ValidationScreen(
            onValidationComplete: () async {
              await prefs.setBool('validation_completed', true);
              if (!mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ),
      );
    }

    if (!mounted) return;
    await _checkIfAlreadyAccepted();
  }

  /// Si ya aceptó permisos antes, va directo a MainScreen
  Future<void> _checkIfAlreadyAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool(_prefKey) ?? false;
    if (!mounted) return;
    if (accepted) {
      // Saltar directo sin animación de bienvenida
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<MainScreen>(builder: (_) => const MainScreen()),
      );
    } else {
      setState(() => _checking = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _announce(
          'Bienvenido a CampusGuía. '
          'Aplicación de navegación para el campus universitario EAFIT. '
          'El botón Iniciar navegación se encuentra al centro de la pantalla.',
        );
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _mainButtonFocusNode.requestFocus();
        });
      });
    }
  }

  @override
  void dispose() {
    _mainButtonFocusNode.dispose();
    super.dispose();
  }

  void _onStartNavigation() {
    HapticFeedback.heavyImpact();
    _announce('Abriendo pantalla de permisos.');
    Navigator.of(context).push(
      MaterialPageRoute<PermissionScreen>(
        builder: (_) => PermissionScreen(
          onPermissionsHandled: () async {
            // Guardar que ya aceptó para que la próxima vez vaya directo
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(_prefKey, true);
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute<MainScreen>(builder: (_) => const MainScreen()),
              (route) => false,
            );
            _announce('Permisos listos. Abriendo navegación.');
          },
        ),
      ),
    );
  }

  void _onHelp() {
    HapticFeedback.mediumImpact();
    showDialog<dynamic>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: const Text('Ayuda', style: TextStyle(color: Colors.white, fontSize: 20)),
        content: const Text(
          'CampusGuía te ayuda a navegar por el campus EAFIT.\n\n'
          '1. Toca "Iniciar navegación" para comenzar.\n'
          '2. Acepta los permisos de ubicación.\n'
          '3. Selecciona una categoría.\n'
          '4. Elige tu destino de la lista.\n\n'
          'Diseñada para ser compatible con TalkBack.',
          style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _replayTutorial();
            },
            child: const Text(
              'Repetir tutorial',
              style: TextStyle(color: Color(0xFF82B1FF)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Entendido', style: TextStyle(color: Color(0xFF82B1FF))),
          ),
        ],
      ),
    );
  }

  Future<void> _replayTutorial() async {
    _announce('Abriendo tutorial.');
    await Navigator.of(context).push(
      MaterialPageRoute<TutorialScreen>(builder: (_) => const TutorialScreen()),
    );
    if (!mounted) return;
    _mainButtonFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D1B2A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF82B1FF)),
        ),
      );
    }

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  label: 'CampusGuía, aplicación de navegación universitaria EAFIT',
                  child: const ExcludeSemantics(
                    child: Column(children: [
                      Icon(Icons.navigation_rounded, size: 64, color: Color(0xFF82B1FF)),
                      SizedBox(height: 12),
                      Text('CampusGuía',
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                        textAlign: TextAlign.center),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  label: 'Navegación por voz y audio dentro del campus universitario EAFIT.',
                  child: const ExcludeSemantics(
                    child: Text('Navegación por voz y audio dentro del campus universitario.',
                      style: TextStyle(fontSize: 20, color: Colors.white70, height: 1.5),
                      textAlign: TextAlign.center),
                  ),
                ),
                const Spacer(),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: Semantics(
                    sortKey: const OrdinalSortKey(1),
                    button: true,
                    label: 'Iniciar navegación',
                    hint: 'Toca dos veces para comenzar. Se solicitarán permisos de ubicación.',
                    onTap: _onStartNavigation,
                    child: ElevatedButton(
                      focusNode: _mainButtonFocusNode,
                      onPressed: _onStartNavigation,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        minimumSize: const Size(double.infinity, 88),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      child: const ExcludeSemantics(
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.play_arrow_rounded, size: 32),
                          SizedBox(width: 12),
                          Text('Iniciar navegación'),
                        ]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Row(children: [
                  Expanded(
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(2),
                      child: Semantics(
                        sortKey: const OrdinalSortKey(2),
                        button: true,
                        label: 'Ayuda',
                        hint: 'Toca dos veces para escuchar instrucciones de uso.',
                        onTap: _onHelp,
                        child: OutlinedButton(
                          onPressed: _onHelp,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white38),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            minimumSize: const Size(0, 64),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const ExcludeSemantics(
                            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(Icons.help_outline_rounded, size: 22),
                              SizedBox(width: 8),
                              Text('Ayuda'),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                const ExcludeSemantics(
                  child: Text('Compatible con TalkBack',
                    style: TextStyle(fontSize: 13, color: Colors.white24),
                    textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
