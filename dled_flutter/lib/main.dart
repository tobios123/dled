import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'models/show_model.dart';
import 'screens/splash_screen.dart';
import 'screens/playback_screen.dart';
import 'screens/edit_screen.dart';
import 'screens/patch_screen.dart';
import 'services/live_sync.dart';
import 'widgets/design_scale.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
  }
  runApp(
    ChangeNotifierProvider(
      create: (_) => ShowModel(),
      child: const DLEDApp(),
    ),
  );
}

class DLEDApp extends StatelessWidget {
  const DLEDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DLED',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1A1A2E), brightness: Brightness.dark),
        fontFamily: 'DejaVuSans',
        useMaterial3: true,
      ),
      // The VN host wraps the navigator itself, so it lives as long as the
      // app. (As the splash page's child it was thrown away - and the LPU
      // service stopped - when the splash page was replaced.)
      // On a phone the whole app is scaled to the screen width, like the
      // reference app (widgets/design_scale.dart).
      builder: (context, child) => _VnHost(child: DesignScale(child: child!)),
      home: const SplashScreen(),
      routes: {
        '/playback': (_) => const PlaybackScreen(),
        '/edit': (_) => const EditScreen(),
        '/patch': (_) => const PatchScreen(),
      },
    );
  }
}

// Hosts the VN service (LPU discovery + live connection) for the lifetime of
// the app. The app sends no DMX itself: the LPU does all DMX output.
class _VnHost extends StatefulWidget {
  final Widget child;
  const _VnHost({required this.child});

  @override
  State<_VnHost> createState() => _VnHostState();
}

class _VnHostState extends State<_VnHost> {
  ShowModel? _model;

  @override
  void initState() {
    super.initState();
    // Start LPU discovery after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final model = context.read<ShowModel>();
      _model = model;
      // VN service runs on all platforms (web stub is a no-op).
      model.vnService.start();
      // Sync VN-discovered devices into model.networkDevices so the Options
      // screen can display them. Preserves existing Art-Net/sACN/label
      // settings for devices already in the list.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      model.vnService.onDevicesChanged = (vnDevices) {
        // Add or refresh each discovered VN device in networkDevices.
        for (final vd in vnDevices) {
          final idx = model.networkDevices
              .indexWhere((d) => d.ipAddress == vd.ip);
          if (idx >= 0) {
            // Update label/name from the live device; preserve user overrides.
            final existing = model.networkDevices[idx];
            if (existing.shortName != vd.label) {
              existing.shortName = vd.label;
              existing.longName = vd.label;
            }
            if (existing.firmware.isEmpty) existing.firmware = vd.version;
          } else {
            model.networkDevices.add(NetworkDevice(
              ipAddress: vd.ip,
              shortName: vd.label,
              longName: vd.label,
              label: '',
              firmware: vd.version,
            ));
          }
        }
        // Remove entries that the VN service has expired (no longer in its list).
        model.networkDevices.removeWhere((d) =>
            !vnDevices.any((vd) => vd.ip == d.ipAddress));
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        model.notifyListeners();
      };
      model.vnService.onConnectionChanged = (device) {
        // Disconnected: back to offline mode (local playback logic).
        if (device == null) model.liveConnected = false;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        model.notifyListeners();
      };
      // Everything the connected LPU reports (the downloaded show first, then
      // live changes) goes into the model; the LPU is the truth (read-only).
      model.vnService.onLiveEvent = (e) =>
          LiveSync.apply(model, e, deviceIp: model.vnService.connected?.ip);
    });
  }

  @override
  void dispose() {
    // Stop VN keepalive and discovery when app is torn down.
    // Use the saved reference — calling context.read in dispose is unsafe.
    _model?.vnService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
