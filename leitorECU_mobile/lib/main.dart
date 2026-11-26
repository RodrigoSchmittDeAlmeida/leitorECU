import 'package:material_ui/material_ui.dart';

import 'core/settings/app_settings.dart';
import 'state/telemetry_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme/motorsport_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LeitorEcuApp());
}

class LeitorEcuApp extends StatefulWidget {
  const LeitorEcuApp({
    super.key,
    this.controller,
    this.settings,
  });

  final TelemetryController? controller;
  final AppSettingsController? settings;

  @override
  State<LeitorEcuApp> createState() => _LeitorEcuAppState();
}

class _LeitorEcuAppState extends State<LeitorEcuApp> {
  late final TelemetryController _controller;
  late final bool _ownsController;
  late final AppSettingsController _settings;
  late final bool _ownsSettings;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TelemetryController();
    _controller.loadSettings();

    _ownsSettings = widget.settings == null;
    _settings = widget.settings ?? AppSettingsController();
    if (_ownsSettings) {
      _settings.load();
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    if (_ownsSettings) {
      _settings.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'leitorECU Mobile',
          debugShowCheckedModeBanner: false,
          theme: MotorsportTheme.buildTheme(
            accent: _settings.accentPreset,
            highContrast: _settings.highContrast,
          ),
          builder: (ctx, child) {
            final mq = MediaQuery.of(ctx);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(_settings.fontScale),
              ),
              child: child!,
            );
          },
          home: AppShell(
            controller: _controller,
            settings: _settings,
          ),
        );
      },
    );
  }
}
