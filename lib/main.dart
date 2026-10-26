import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'config.dart';
import 'firestore_api.dart';
import 'login_page.dart';
import 'viewer_page.dart';

/// FieldForce route viewer (Flutter web): agents see their own routes,
/// the admin login sees every user.
///
/// Run: flutter run -d chrome --dart-define-from-file=dev_config.json
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (useGoogleMaps) await _loadGoogleMaps();
  runApp(const DevViewerApp());
}

/// google_maps_flutter on the web needs the Maps JavaScript API on the page.
Future<void> _loadGoogleMaps() {
  final done = Completer<void>();
  final script = web.HTMLScriptElement()
    ..src = 'https://maps.googleapis.com/maps/api/js?key=$kMapsApiKey'
    ..async = true;
  script.addEventListener('load', ((web.Event _) => done.complete()).toJS);
  script.addEventListener('error', ((web.Event _) => done.complete()).toJS);
  web.document.head!.append(script);
  return done.future;
}

class DevViewerApp extends StatefulWidget {
  const DevViewerApp({super.key});

  @override
  State<DevViewerApp> createState() => _DevViewerAppState();
}

class _DevViewerAppState extends State<DevViewerApp> {
  Session? _session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldForce Route Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF12A594),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1113),
      ),
      home: _session == null
          ? LoginPage(onLogin: (s) => setState(() => _session = s))
          : ViewerPage(
              key: ValueKey(_session),
              session: _session!,
              onLogout: () => setState(() => _session = null),
            ),
    );
  }
}
