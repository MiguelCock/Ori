import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/accessibility_scale.dart';
// Haptic moved to main screen; keep HomeScreen minimal
import 'permission_screen.dart';
import 'main_screen.dart';

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
    if (!mounted) return;
    await _checkIfAlreadyAccepted();
  }

  // Startup vibration test removed — moved to main screen as a single manual control.

  /// Si ya aceptó permisos antes, va directo a MainScreen
  Future<void> _checkIfAlreadyAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool(_prefKey) ?? false;
    if (!mounted) return;
    if (accepted) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const MainScreen()));
    } else {
      setState(() => _checking = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _announce(
          'Bienvenido a CampusGuia. '
          'Aplicacion de navegacion para el campus universitario EAFIT. '
          'El boton Iniciar navegacion se encuentra al centro de la pantalla.',
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
      MaterialPageRoute(
        builder: (_) => PermissionScreen(
          onPermissionsHandled: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(_prefKey, true);
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MainScreen()),
              (route) => false,
            );
            _announce('Permisos listos. Abriendo navegacion.');
          },
        ),
      ),
    );
  }

  void _onHelp() {
    HapticFeedback.mediumImpact();
    final dialogTextScaler = clampedTextScaler(context);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: Text(
          'Ayuda',
          textScaler: dialogTextScaler,
          style: const TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: SingleChildScrollView(
          child: Text(
            'CampusGuia te ayuda a navegar por el campus EAFIT.\n\n'
            '1. Toca "Iniciar navegacion" para comenzar.\n'
            '2. Acepta los permisos de ubicacion.\n'
            '3. Selecciona una categoria.\n'
            '4. Elige tu destino de la lista.\n\n'
            'Disenada para ser compatible con TalkBack.',
            textScaler: dialogTextScaler,
            softWrap: true,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              height: 1.6,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: Text(
              'Entendido',
              textScaler: dialogTextScaler,
              style: const TextStyle(color: Color(0xFF82B1FF)),
            ),
          ),
        ],
      ),
    );
  }

  // Vibrate handler removed from HomeScreen — centralised on MainScreen.

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);
    final titleScaler = clampedTextScaler(context, maxScale: 1.3);
    final screenSize = MediaQuery.sizeOf(context);
    final isCompactHeight = screenSize.height < 640;

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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final padding = responsiveInsets(
                context,
                horizontal: isCompactHeight ? 18 : 24,
                vertical: isCompactHeight ? 18 : 32,
              );

              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: padding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            header: true,
                            label:
                                'CampusGuia, aplicacion de navegacion universitaria EAFIT',
                            child: ExcludeSemantics(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.navigation_rounded,
                                    size: responsiveSpace(
                                      context,
                                      isCompactHeight ? 52 : 64,
                                    ),
                                    color: const Color(0xFF82B1FF),
                                  ),
                                  SizedBox(
                                    height: responsiveSpace(context, 12),
                                  ),
                                  Text(
                                    'CampusGuia',
                                    textScaler: titleScaler,
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                    textAlign: TextAlign.center,
                                    softWrap: true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(height: responsiveSpace(context, 16)),
                          Semantics(
                            label:
                                'Navegacion por voz y audio dentro del campus universitario EAFIT.',
                            child: ExcludeSemantics(
                              child: Text(
                                'Navegacion por voz y audio dentro del campus universitario.',
                                textScaler: textScaler,
                                style: const TextStyle(
                                  fontSize: 20,
                                  color: Colors.white70,
                                  height: 1.5,
                                ),
                                textAlign: TextAlign.center,
                                softWrap: true,
                              ),
                            ),
                          ),
                          const Spacer(),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(1),
                            child: Semantics(
                              sortKey: const OrdinalSortKey(1),
                              button: true,
                              label: 'Iniciar navegacion',
                              hint:
                                  'Toca dos veces para comenzar. Se solicitaran permisos de ubicacion.',
                              onTap: _onStartNavigation,
                              child: ElevatedButton(
                                focusNode: _mainButtonFocusNode,
                                onPressed: _onStartNavigation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1565C0),
                                  foregroundColor: Colors.white,
                                  padding: EdgeInsets.symmetric(
                                    vertical: responsiveSpace(context, 20),
                                  ),
                                  minimumSize: const Size(double.infinity, 88),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                child: ExcludeSemantics(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 32,
                                      ),
                                      SizedBox(
                                        width: responsiveSpace(context, 12),
                                      ),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'Iniciar navegacion',
                                            textScaler: textScaler,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: responsiveSpace(
                              context,
                              isCompactHeight ? 18 : 32,
                            ),
                          ),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(2),
                            child: Semantics(
                              sortKey: const OrdinalSortKey(2),
                              button: true,
                              label: 'Ayuda',
                              hint:
                                  'Toca dos veces para escuchar instrucciones de uso.',
                              onTap: _onHelp,
                              child: OutlinedButton(
                                onPressed: _onHelp,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white38),
                                  padding: EdgeInsets.symmetric(
                                    vertical: responsiveSpace(context, 16),
                                  ),
                                  minimumSize: const Size(double.infinity, 64),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: ExcludeSemantics(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.help_outline_rounded,
                                        size: 22,
                                      ),
                                      SizedBox(
                                        width: responsiveSpace(context, 8),
                                      ),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'Ayuda',
                                            textScaler: textScaler,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: responsiveSpace(context, 16)),
                          ExcludeSemantics(
                            child: Text(
                              'Compatible con TalkBack',
                              textScaler: textScaler,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white24,
                              ),
                              textAlign: TextAlign.center,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
