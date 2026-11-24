import 'package:material_ui/material_ui.dart';

import '../state/telemetry_controller.dart';
import 'screens/charts_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/functions_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/map2d_screen.dart';
import 'theme/motorsport_theme.dart';
import 'widgets/connection_sheet.dart';

/// Shell responsivo: NavigationBar no Phone (< 840dp) e NavigationRail no Tablet (>= 840dp).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
  });

  final TelemetryController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  final ValueNotifier<String?> _pinnedChannel = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _pinnedChannel.dispose();
    super.dispose();
  }

  static const List<({String label, IconData icon, IconData activeIcon})> _tabs = [
    (label: 'Painel', icon: Icons.speed_outlined, activeIcon: Icons.speed),
    (label: 'Gráficos', icon: Icons.show_chart, activeIcon: Icons.stacked_line_chart),
    (label: 'Mapa 2D', icon: Icons.grid_on_outlined, activeIcon: Icons.grid_on),
    (label: 'Funções', icon: Icons.build_outlined, activeIcon: Icons.build),
    (label: 'Logs', icon: Icons.folder_outlined, activeIcon: Icons.folder),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isTablet = width >= MotorsportTheme.tabletBreakpoint;

    final body = IndexedStack(
      index: _selectedIndex,
      children: [
        DashboardScreen(
          controller: widget.controller,
          onOpenChannelChart: (key) {
            _pinnedChannel.value = key;
            setState(() => _selectedIndex = 1);
          },
        ),
        ChartsScreen(
          controller: widget.controller,
          pinnedChannelNotifier: _pinnedChannel,
        ),
        Map2DScreen(controller: widget.controller),
        FunctionsScreen(controller: widget.controller),
        LogsScreen(
          controller: widget.controller,
          onReplayLoaded: () => setState(() => _selectedIndex = 0),
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopStatusBar(
              controller: widget.controller,
              isTablet: isTablet,
            ),
            Expanded(
              child: isTablet
                  ? Row(
                      children: [
                        NavigationRail(
                          selectedIndex: _selectedIndex,
                          onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            for (final t in _tabs)
                              NavigationRailDestination(
                                icon: Icon(t.icon),
                                selectedIcon: Icon(t.activeIcon),
                                label: Text(t.label),
                              ),
                          ],
                        ),
                        const VerticalDivider(width: 1, thickness: 1),
                        Expanded(child: body),
                      ],
                    )
                  : body,
            ),
          ],
        ),
      ),
      bottomNavigationBar: isTablet
          ? null
          : NavigationBar(
              height: 64,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(
                    icon: Icon(t.icon),
                    selectedIcon: Icon(t.activeIcon),
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.controller,
    required this.isTablet,
  });

  final TelemetryController controller;
  final bool isTablet;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final (pillText, pillColor, pillBg, pillBorder) = switch (controller.connectionState) {
          ConnectionStateKind.connected => (
              '● ONLINE',
              const Color(0xFF71FFB2),
              const Color(0xFF0E2E1F),
              const Color(0xFF145939),
            ),
          ConnectionStateKind.connecting => (
              '● CONECTANDO',
              const Color(0xFFFFD26C),
              const Color(0xFF352608),
              const Color(0xFF6B4E10),
            ),
          ConnectionStateKind.ecuOff => (
              '● DESCONECTADO (ECU OFF)',
              const Color(0xFFFF8DA9),
              const Color(0xFF47121E),
              MotorsportColors.alarm,
            ),
          ConnectionStateKind.error => (
              '● ERRO',
              const Color(0xFFFF8DA9),
              const Color(0xFF38161E),
              const Color(0xFF631B2D),
            ),
          ConnectionStateKind.offline => (
              '● OFFLINE',
              MotorsportColors.muted,
              const Color(0xFF161C24),
              MotorsportColors.borderSubtle,
            ),
        };

        final hasProto = controller.protocolModeName.isNotEmpty;
        final protoBg = !hasProto
            ? const Color(0xFF161C24)
            : (controller.isProtocolFallback ? const Color(0xFF382A0B) : const Color(0xFF0E2E1F));
        final protoFg = !hasProto
            ? MotorsportColors.stale
            : (controller.isProtocolFallback ? const Color(0xFFFFD26C) : const Color(0xFF71FFB2));
        final protoBorder = !hasProto
            ? MotorsportColors.borderSubtle
            : (controller.isProtocolFallback ? const Color(0xFF664E14) : const Color(0xFF145939));

        final recBg = controller.isRecording ? const Color(0xFF531426) : MotorsportColors.elevated;
        final recBorder = controller.isRecording ? MotorsportColors.alarm : MotorsportColors.border;

        return Container(
          padding: EdgeInsets.symmetric(horizontal: isTablet ? 12 : 8, vertical: 6),
          decoration: const BoxDecoration(
            color: MotorsportColors.surfaceAlt,
            border: Border(bottom: BorderSide(color: MotorsportColors.borderSubtle)),
          ),
          child: Row(
            children: [
              if (isTablet) ...[
                const Text(
                  'leitorECU',
                  style: TextStyle(
                    color: MotorsportColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Flexible(
                flex: isTablet ? 0 : 1,
                child: InkWell(
                  onTap: () => ConnectionSheet.show(context, controller),
                  borderRadius: BorderRadius.circular(3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: pillBg,
                      border: Border.all(color: pillBorder),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      pillText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: pillColor,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              if (hasProto || isTablet) ...[
                const SizedBox(width: 6),
                Flexible(
                  flex: isTablet ? 1 : 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: protoBg,
                      border: Border.all(color: protoBorder),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      hasProto ? controller.protocolModeName : 'SEM PROTOCOLO',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: protoFg,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
              if (isTablet) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E2530),
                    border: Border.all(color: const Color(0xFF144959)),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${controller.responsesPerSec.toStringAsFixed(1)} R/S  |  '
                    '${controller.cyclesPerSec.toStringAsFixed(1)} C/S  |  '
                    '${controller.latencyMs > 0 ? controller.latencyMs.toStringAsFixed(0) : "--"} ms',
                    style: MotorsportTheme.tabularStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF57E2FF),
                    ),
                  ),
                ),
              ] else if (!hasProto) ...[
                const Spacer(),
              ],
              const SizedBox(width: 6),
              Material(
                color: recBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: BorderSide(color: recBorder),
                ),
                child: InkWell(
                  onTap: controller.toggleRecording,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          controller.isRecording ? Icons.stop : Icons.fiber_manual_record,
                          size: 13,
                          color: MotorsportColors.alarm,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          controller.isRecording
                              ? 'PARAR · ${controller.recordingRows}'
                              : 'GRAVAR',
                          style: MotorsportTheme.tabularStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: controller.isRecording
                                ? const Color(0xFFFFD6E0)
                                : MotorsportColors.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
