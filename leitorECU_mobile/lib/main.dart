import 'package:material_ui/material_ui.dart';

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
  });

  final TelemetryController? controller;

  @override
  State<LeitorEcuApp> createState() => _LeitorEcuAppState();
}

class _LeitorEcuAppState extends State<LeitorEcuApp> {
  late final TelemetryController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TelemetryController();
    _controller.loadSettings();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'leitorECU Mobile',
      debugShowCheckedModeBanner: false,
      theme: MotorsportTheme.darkTheme(),
      home: AppShell(controller: _controller),
    );
  }
}
