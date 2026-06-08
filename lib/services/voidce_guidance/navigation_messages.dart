/// Centralized voice and UI strings for navigation.
class NavigationMessages {
  NavigationMessages._();

  static String navigationStarted(String destination) =>
      'Navegación iniciada hacia $destination.';

  static String navigationStopped() => 'Navegación detenida.';

  static String navigationPaused() => 'Navegación pausada';

  static String navigationResumed() => 'Navegación reanudada';

  static String navigationFinished() => 'Navegación finalizada';

  static String destinationReached(String destination) =>
      'Has llegado a $destination. Navegación finalizada.';

  static String offRoute() => 'Te has alejado de la ruta. Recalculando.';

  static String routeUpdated(String firstInstruction) =>
      'Ruta actualizada. $firstInstruction';

  static String rerouteFailed() =>
      'No pude recalcular la ruta en este momento.';

  static String periodicProgress({
    required int nextInstructionMeters,
    required String remainingDistanceText,
    required String destination,
  }) =>
      'Vas correctamente por la ruta. Próxima indicación en $nextInstructionMeters metros. '
      'Faltan $remainingDistanceText para llegar a $destination.';

  static String passingLandmark(String landmark) =>
      'Estás pasando junto a $landmark.';

  static String noPointsForGuidance() =>
      'No hay suficientes puntos para guiar por voz.';
}