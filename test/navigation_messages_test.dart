import 'package:campus_guia/services/voidce_guidance/voice_guidance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HU-28 navigation state messages match accessible announcements', () {
    expect(NavigationMessages.navigationPaused(), 'Navegación pausada');
    expect(NavigationMessages.navigationResumed(), 'Navegación reanudada');
    expect(NavigationMessages.navigationFinished(), 'Navegación finalizada');
  });
}
