# CampusGuía EAFIT

Aplicación móvil desarrollada en Flutter para orientar recorridos dentro del campus EAFIT. La app integra mapas, geolocalización, rutas, guía por voz y componentes de accesibilidad para apoyar la navegación en el campus.

## Características

- Ubicación en tiempo real dentro del campus.
- Cálculo y visualización de rutas.
- Guía por voz para acompañar el recorrido.
- Soporte de accesibilidad y escalado visual.
- Mapa del campus con datos locales incluidos en el proyecto.

## Descarga del APK

Puedes descargar la versión compilada desde este enlace:

[Descargar APK](https://drive.google.com/file/d/1Gk-PAOrzjAgPbGZ6IByvYBJpmCcHC1mo/view?usp=drive_link)

## Requisitos

- Flutter SDK 3.x o superior.
- Android Studio o VS Code con soporte para Flutter.
- Dispositivo Android o emulador para pruebas.

## Instalación

1. Clona el repositorio.
2. Ejecuta `flutter pub get`.
3. Conecta un dispositivo o inicia un emulador.
4. Ejecuta `flutter run`.

## Compilación

Para generar el APK de producción:

```bash
flutter build apk --release
```

El archivo generado se encuentra en `build/app/outputs/flutter-apk/`.

## Estructura del proyecto

```text
Ori/
├── android/
├── assets/
│   └── data/
│       ├── campus_eafit.geojson
│       ├── campus_eafit.mbtiles
│       ├── campus_eafit_categories.json
│       ├── campus_eafit_info.json
│       └── routing_graph.json
├── ios/
├── lib/
│   ├── main.dart
│   ├── models/
│   │   └── campus_place.dart
│   ├── screens/
│   │   ├── destination_screen.dart
│   │   ├── home_screen.dart
│   │   ├── main_screen.dart
│   │   ├── navigation_map_screen.dart
│   │   ├── permission_screen.dart
│   │   ├── place_detail_screen.dart
│   │   ├── tutorial_screen.dart
│   │   └── validation_screen.dart
│   ├── services/
│   │   ├── geojson_service.dart
│   │   ├── haptic_service.dart
│   │   ├── location_service.dart
│   │   ├── route_guidance_builder.dart
│   │   ├── routing_service.dart
│   │   └── voice_guidance_service.dart
│   └── utils/
│       └── accessibility_scale.dart
├── linux/
├── macos/
├── test/
│   ├── navigation_messages_test.dart
│   └── widget_test.dart
├── web/
└── windows/
```

## Tecnologías usadas

- Flutter
- Provider
- Geolocator
- flutter_map
- flutter_tts
- flutter_compass

## Notas

- La app está configurada en español (`es_CO`).
- El proyecto incluye recursos locales para mapas y rutas dentro de `assets/data`.
- Se recomienda ejecutar pruebas y compilaciones antes de publicar una nueva versión.

## Desarrollo


### Conectar al celular

Enable Developer Options on your phone.
Enable USB debugging.
Go to Developer Options → Wireless debugging and turn it on.
Make sure your phone and PC are on the same Wi-Fi network.
On your PC, run:
adb pair IP_ADDRESS:PAIRING_PORT
On your phone, tap Pair device with pairing code and enter the code shown on the phone.
Then connect:
adb connect IP_ADDRESS:ADB_PORT

You can find the IP address and ports in the Wireless Debugging screen.

Verify:
adb devices

You should see your phone listed as a network device.