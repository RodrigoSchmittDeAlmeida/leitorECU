import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/channel_def.dart';
import '../../core/protocols/vag_formulas.dart';
import '../../core/settings/app_settings.dart';
import '../../state/telemetry_controller.dart';
import '../../storage/csv_logger.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/card_customization_sheet.dart';
import '../widgets/channel_detail_chart_sheet.dart';
import '../widgets/connection_sheet.dart';
import '../widgets/replay_player_bar.dart';
import '../widgets/uniform_action_button.dart';
import '../widgets/value_card.dart';

/// Aba Painel: foco exclusivo nos cards numéricos motorsport e canais extras.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.controller,
    this.settings,
    this.onOpenChannelChart,
  });

  final TelemetryController controller;
  final AppSettingsController? settings;
  final ValueChanged<String>? onOpenChannelChart;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _showExtraChannels = false;
  bool _editCardsMode = false;
  String _extraFilter = '';
  final TextEditingController _filterCtrl = TextEditingController();

  String? _stableBadgeText;
  Color? _stableBadgeColor;
  String? _stableMessageText;
  ConnectionStateKind? _lastConnState;
  String? _lastExplicitInfo;
  int _lastEventCount = 0;
  DateTime? _lastStatusUpdateAt;

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      widget.controller,
      if (widget.settings != null) widget.settings!,
    ];

    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        final c = widget.controller;
        final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;
        final pad = isTablet ? 12.0 : 8.0;

        return Column(
          children: [
            if (c.replayMode)
              Padding(
                padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
                child: ReplayPlayerBar(
                  controller: c,
                  exitLabel: 'Sair do Replay',
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildActionBar(context, c),
                    const SizedBox(height: 8),
                    _buildStatusRibbon(context, c),
                    if (_editCardsMode) ...[
                      const SizedBox(height: 8),
                      _buildEditCardsBanner(context, c),
                    ],
                    const SizedBox(height: 10),
                    _buildCardsGrid(context, c),
                    const SizedBox(height: 12),
                    _buildExtraChannelsSection(c),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActionBar(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final connectedOrBusy = c.isConnected || c.connectionState == ConnectionStateKind.connecting;

    final buttons = <Widget>[
      _buildUniformActionBtn(
        icon: connectedOrBusy ? Icons.link_off : Icons.power_settings_new,
        label: connectedOrBusy ? 'Desconectar' : 'Conectar',
        bg: connectedOrBusy ? const Color(0xFF511D2B) : const Color(0xFF073B29),
        fg: connectedOrBusy ? const Color(0xFFFFD6E0) : const Color(0xFFA9FFD3),
        borderColor: connectedOrBusy ? MotorsportColors.alarm : MotorsportColors.ok,
        onTap: connectedOrBusy ? c.disconnect : () => ConnectionSheet.show(context, c),
      ),
      _buildUniformActionBtn(
        icon: c.isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
        iconColor: MotorsportColors.alarm,
        label: c.isRecording ? 'Parar (${c.recordingRows})' : 'Gravar Log',
        bg: c.isRecording ? const Color(0xFF531426) : tokens.elevated,
        fg: c.isRecording ? const Color(0xFFFFD6E0) : tokens.text,
        borderColor: c.isRecording ? MotorsportColors.alarm : tokens.border,
        onTap: c.toggleRecording,
      ),
      _buildUniformActionBtn(
        icon: Icons.bolt,
        label: 'Limpar Picos',
        bg: tokens.elevated,
        fg: tokens.text,
        borderColor: tokens.border,
        onTap: c.clearPeaks,
      ),
      _buildUniformActionBtn(
        icon: c.decelMode ? Icons.check_circle_outline : Icons.speed_outlined,
        iconColor: c.decelMode ? MotorsportColors.warning : tokens.muted,
        label: 'Desaceleração',
        bg: c.decelMode ? const Color(0xFF493512) : tokens.elevated,
        fg: c.decelMode ? const Color(0xFFFFE2A1) : tokens.text,
        borderColor: c.decelMode ? MotorsportColors.warning : tokens.border,
        onTap: () {
          final v = !c.decelMode;
          c.decelMode = v;
          c.emitInfo(
            v
                ? 'Modo Prioridade de Desaceleração ATIVADO'
                : 'Modo Prioridade de Desaceleração desativado',
          );
        },
      ),
      _buildUniformActionBtn(
        icon: Icons.tune,
        iconColor: _showExtraChannels ? tokens.accent : tokens.muted,
        label: 'Extras (${_extraChannelKeys(c).length})',
        bg: _showExtraChannels ? tokens.accent.withValues(alpha: 0.16) : tokens.elevated,
        fg: _showExtraChannels ? tokens.accent : tokens.text,
        borderColor: _showExtraChannels ? tokens.accent : tokens.border,
        onTap: () => setState(() => _showExtraChannels = !_showExtraChannels),
      ),
      _buildUniformActionBtn(
        icon: Icons.dashboard_customize_outlined,
        iconColor: _editCardsMode ? tokens.accent : tokens.muted,
        label: 'Personalizar',
        bg: _editCardsMode ? tokens.accent.withValues(alpha: 0.16) : tokens.elevated,
        fg: _editCardsMode ? tokens.accent : tokens.text,
        borderColor: _editCardsMode ? tokens.accent : tokens.border,
        onTap: () => setState(() => _editCardsMode = !_editCardsMode),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w >= 840 ? 6 : (w >= 320 ? 3 : 2);
        const gap = 6.0;
        final btnW = (w - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final b in buttons) SizedBox(width: btnW, height: 38, child: b),
          ],
        );
      },
    );
  }

  Widget _buildUniformActionBtn({
    required IconData icon,
    required String label,
    required Color bg,
    required Color fg,
    required Color borderColor,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return UniformActionButton(
      label: label,
      icon: icon,
      height: 38,
      customBg: bg,
      customFg: fg,
      customBorder: borderColor,
      customIconColor: iconColor,
      onTap: onTap,
    );
  }

  Widget _buildEditCardsBanner(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final settings = widget.settings;
    final activeKeys = settings?.dashboardCardKeys ?? cardChannelKeys;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.accent.withValues(alpha: 0.10),
        border: Border.all(
          color: tokens.accent.withValues(alpha: 0.5),
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note, size: 18, color: tokens.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Editando Cards (${activeKeys.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          UniformButtonGrid(
            columns: 2,
            tabletColumns: 3,
            spacing: 6,
            children: [
              UniformActionButton(
                label: '+ Adicionar Card',
                icon: Icons.add,
                variant: UniformActionVariant.info,
                height: 38,
                onTap: () async {
                  if (settings == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Personalização disponível no modo completo.'),
                      ),
                    );
                    return;
                  }
                  final chosen = await CardCustomizationSheet.show(
                    context,
                    controller: c,
                    currentCardKeys: activeKeys,
                    title: 'Adicionar Card ao Painel',
                  );
                  if (chosen != null) {
                    await settings.addCard(chosen);
                  }
                },
              ),
              UniformActionButton(
                label: 'Restaurar Padrão',
                icon: Icons.restart_alt,
                variant: UniformActionVariant.neutral,
                height: 38,
                onTap: settings == null
                    ? null
                    : () async {
                        await settings.resetDashboardCards();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Cards restaurados para o padrão de fábrica.',
                            ),
                          ),
                        );
                      },
              ),
              UniformActionButton(
                label: 'Concluir',
                icon: Icons.check,
                variant: UniformActionVariant.primary,
                height: 38,
                onTap: () => setState(() => _editCardsMode = false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRibbon(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final lastEv = c.events.isNotEmpty ? c.events.last : null;
    final String rawBadgeText;
    final Color rawBadgeColor;
    final String rawMessageText;
    var isCritical = false;

    if (c.isEcuOff) {
      rawBadgeText = '● ECU OFF';
      rawBadgeColor = MotorsportColors.alarm;
      rawMessageText = c.statusMessage;
      isCritical = true;
    } else if (lastEv != null) {
      rawBadgeText = switch (lastEv.level) {
        'alarm' => '● ALARME',
        'warn' => '▲ ATENÇÃO',
        _ => '● INFO',
      };
      rawBadgeColor = switch (lastEv.level) {
        'alarm' => MotorsportColors.alarm,
        'warn' => MotorsportColors.warning,
        _ => tokens.accent,
      };
      rawMessageText = lastEv.message;
      isCritical = lastEv.level == 'alarm';
    } else if (c.lastInfoMessage != null && c.lastInfoMessage!.isNotEmpty) {
      rawBadgeText = c.isConnected ? '● ECU' : '● INFO';
      rawBadgeColor = c.isConnected ? MotorsportColors.ok : tokens.accent;
      rawMessageText = c.lastInfoMessage!;
    } else {
      rawBadgeText = c.isConnected ? '● ECU' : '● INFO';
      rawBadgeColor = c.isConnected ? MotorsportColors.ok : tokens.accent;
      rawMessageText = c.ecuMetadata.ecuName.isNotEmpty && c.isConnected
          ? '${c.ecuMetadata.ecuName} — ${c.statusMessage}'
          : c.statusMessage;
    }

    final now = DateTime.now();
    final connChanged = _lastConnState != c.connectionState;
    final explicitInfoChanged = _lastExplicitInfo != c.lastInfoMessage;
    final firstEventArrived = _lastEventCount == 0 && c.events.isNotEmpty;
    final elapsedOk = _lastStatusUpdateAt == null ||
        now.difference(_lastStatusUpdateAt!).inMilliseconds >= 4000;
    if (_stableMessageText == null ||
        connChanged ||
        explicitInfoChanged ||
        firstEventArrived ||
        isCritical ||
        elapsedOk) {
      _stableBadgeText = rawBadgeText;
      _stableBadgeColor = rawBadgeColor;
      _stableMessageText = rawMessageText;
      _lastConnState = c.connectionState;
      _lastExplicitInfo = c.lastInfoMessage;
      _lastEventCount = c.events.length;
      _lastStatusUpdateAt = now;
    }

    final badgeText = _stableBadgeText ?? rawBadgeText;
    final badgeColor = _stableBadgeColor ?? rawBadgeColor;
    final messageText = _stableMessageText ?? rawMessageText;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                badgeText,
                style: TextStyle(
                  color: badgeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (c.events.isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _showEventsHistorySheet(context, c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history, size: 13, color: tokens.accent),
                        const SizedBox(width: 4),
                        Text(
                          'Histórico (${c.events.length})',
                          style: TextStyle(
                            color: tokens.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            messageText,
            softWrap: true,
            style: TextStyle(
              color: tokens.text,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEventsHistorySheet(
    BuildContext context,
    TelemetryController c,
  ) {
    final tokens = MotorsportTheme.tokensOf(context);
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.border),
      ),
      builder: (ctx) {
        final reversed = c.events.reversed.toList();
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Icon(Icons.history, color: tokens.accent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Histórico de Diagnóstico (${reversed.length})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tokens.text,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          c.clearEvents();
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Limpar'),
                      ),
                      IconButton(
                        tooltip: 'Fechar',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: Icon(Icons.close, color: tokens.muted),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: tokens.borderSubtle),
                Flexible(
                  child: reversed.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Nenhum evento registrado.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: tokens.muted),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: reversed.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final ev = reversed[i];
                            final (lvlLabel, lvlColor, lvlBg) = switch (ev.level) {
                              'alarm' => (
                                  'ALARME',
                                  MotorsportColors.alarm,
                                  MotorsportColors.alarmBg,
                                ),
                              'warn' => (
                                  'ATENÇÃO',
                                  MotorsportColors.warning,
                                  MotorsportColors.warnBg,
                                ),
                              _ => (
                                  'INFO',
                                  tokens.accent,
                                  tokens.surfaceAlt,
                                ),
                            };
                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: lvlBg,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: lvlColor.withValues(alpha: 0.45)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: lvlColor.withValues(alpha: 0.16),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          lvlLabel,
                                          style: TextStyle(
                                            color: lvlColor,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        't = ${ev.timeSec.toStringAsFixed(1)}s',
                                        style: MotorsportTheme.tabularStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: tokens.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    ev.message,
                                    softWrap: true,
                                    style: TextStyle(
                                      color: tokens.text,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCardsGrid(BuildContext context, TelemetryController c) {
    final activeKeys = widget.settings?.dashboardCardKeys ?? cardChannelKeys;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final int cols;
        if (w >= 1120) {
          cols = 7;
        } else if (w >= 800) {
          cols = 5;
        } else if (w >= 540) {
          cols = 3;
        } else {
          cols = 2;
        }
        const spacing = 8.0;
        final cardWidth = (w - spacing * (cols - 1)) / cols;
        final compact = cols >= 5 || w < 440;

        final settings = widget.settings;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < activeKeys.length; i++)
              SizedBox(
                width: cardWidth,
                child: DragTarget<int>(
                  onWillAcceptWithDetails: (details) =>
                      settings != null && details.data != i,
                  onAcceptWithDetails: (details) {
                    settings?.moveCard(details.data, i);
                  },
                  builder: (context, candidateData, _) {
                    final card = _buildAdaptedCard(
                      context,
                      c,
                      activeKeys[i],
                      index: i,
                      totalCount: activeKeys.length,
                      activeKeys: activeKeys,
                      compact: compact,
                    );
                    final highlighted = candidateData.isNotEmpty
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: MotorsportTheme.tokensOf(context).accent,
                                width: 2,
                              ),
                            ),
                            child: card,
                          )
                        : card;
                    if (settings == null) return highlighted;
                    return LongPressDraggable<int>(
                      data: i,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Opacity(
                          opacity: 0.85,
                          child: SizedBox(width: cardWidth, child: card),
                        ),
                      ),
                      childWhenDragging: Opacity(opacity: 0.35, child: card),
                      child: highlighted,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  int _smartDecimalsFor(String key, String unit) {
    if (unit == 'rpm' ||
        unit == '°C' ||
        unit == 'kPa' ||
        unit == 'km/h' ||
        unit == 'un' ||
        unit == 'bit' ||
        unit == 'id' ||
        unit == 'cod') {
      return 0;
    }
    if (unit == 'λ') return 3;
    if (unit == 'bar' || unit == 'ms' || unit == 'G') return 2;
    if (unit == 'V') {
      if (key.contains('lambda')) return 3;
      if (key.contains('knock') || key == 'ecu_volt' || key == 'obd_pin16_v') return 2;
      return 1;
    }
    if (unit == '%' ||
        unit == '°' ||
        unit == '°KW' ||
        unit == 'L/h' ||
        unit == 'l/h' ||
        unit == 'km/l' ||
        unit == 'cv' ||
        unit == 'kgfm' ||
        unit == 'psi') {
      return 1;
    }
    return key.startsWith('g') ? 2 : 1;
  }

  bool _smartSignedFor(String key) {
    return key.contains('stft') ||
        key.contains('ltft') ||
        key.contains('trim') ||
        key == 'lambda_error_pct' ||
        key == 'boost_bar' ||
        key == 'boost_psi' ||
        key == 'accel_g';
  }

  Widget _buildAdaptedCard(
    BuildContext context,
    TelemetryController c,
    String key, {
    required int index,
    required int totalCount,
    required List<String> activeKeys,
    required bool compact,
  }) {
    final latest = c.latest;
    final hasTurboData = c.ecuMetadata.isTurbo ||
        (latest['map'] ?? 0.0) > 105.0 ||
        latest.containsKey('boost_target_bar') ||
        latest.containsKey('wastegate_pct') ||
        latest.containsKey('fuel_rail_bar') ||
        latest.containsKey('turbo_inlet_kpa');

    final def = coreChannels[key];
    final desc = describeChannel(key, c.knownChannels);
    String activeKey = key;
    String title = def?.label ?? _channelLabelForExtra(c, key);
    String unit = def?.unit ?? desc.unit;
    int decimals = def?.decimals ?? _smartDecimalsFor(key, unit);
    bool signed = def?.signed ?? _smartSignedFor(key);

    // 1. Adaptação LTFT Lenta vs Correção Sonda (nunca duplicar Correção Sonda == STFT)
    if (key == 'lambda_trim' && latest.containsKey('ltft_idle')) {
      activeKey = 'ltft_idle';
      title = 'LTFT Lenta';
      unit = '%';
      decimals = 1;
      signed = true;
    } else if (key == 'ltft') {
      if (latest.containsKey('ltft_idle')) {
        title = 'LTFT Parcial';
      }
      signed = true;
    } else if (key == 'stft') {
      signed = true;
    }

    // 2. Adaptação MAP -> MAP / Boost em veículos realmente Turbo
    if (key == 'map' && hasTurboData) {
      title = 'MAP / Boost';
    }

    // 3. Adaptação Sonda 2 (Pós) para Turbo ou Mono-Sonda (Gol G5 -> Tempo Injeção)
    if (key == 'lambda2_v') {
      if (hasTurboData &&
          (!latest.containsKey('lambda2_v') || c.ecuMetadata.isTurbo) &&
          (latest.containsKey('boost_bar') || latest.containsKey('lambda_eq'))) {
        if (latest.containsKey('boost_bar')) {
          activeKey = 'boost_bar';
          title = 'Pressão Turbo';
          unit = 'bar';
          decimals = 2;
          signed = true;
        } else if (latest.containsKey('lambda_eq') && !latest.containsKey('lambda2_v')) {
          activeKey = 'lambda_eq';
          title = 'Lambda (λ)';
          unit = 'λ';
          decimals = 3;
          signed = false;
        }
      } else if (!latest.containsKey('lambda2_v')) {
        if (latest.containsKey('inj_ms')) {
          activeKey = 'inj_ms';
          title = 'Tempo Injeção';
          unit = 'ms';
          decimals = 2;
          signed = false;
        } else if (latest.containsKey('inj_pulse_width')) {
          activeKey = 'inj_pulse_width';
          title = 'Tempo Injeção';
          unit = 'ms';
          decimals = 2;
          signed = false;
        } else if (latest.containsKey('fuel_rate_lph')) {
          activeKey = 'fuel_rate_lph';
          title = 'Consumo Inst.';
          unit = 'L/h';
          decimals = 1;
          signed = false;
        }
      }
    }

    final val = latest[activeKey];
    final minVal = c.peakMin[activeKey];
    final maxVal = c.peakMax[activeKey];

    String fmt(double v) {
      final s = v.toStringAsFixed(decimals);
      return (signed && v >= 0) ? '+$s' : s;
    }

    final formattedValue = val != null ? fmt(val) : '--';
    final minFormatted = minVal != null ? fmt(minVal) : null;
    final maxFormatted = maxVal != null ? fmt(maxVal) : null;

    final (alertState, note) = _evaluateCardState(
      c,
      cardKey: key,
      activeKey: activeKey,
      value: val,
      hasTurboData: hasTurboData,
    );

    final settings = widget.settings;

    return ValueCard(
      channelKey: activeKey,
      title: title,
      unit: unit,
      formattedValue: formattedValue,
      alertState: alertState,
      note: note,
      minFormatted: minFormatted,
      maxFormatted: maxFormatted,
      compact: compact,
      editMode: _editCardsMode,
      onMovePrev: (_editCardsMode && index > 0 && settings != null)
          ? () => settings.moveCard(index, index - 1)
          : null,
      onMoveNext: (_editCardsMode && index < totalCount - 1 && settings != null)
          ? () => settings.moveCard(index, index + 1)
          : null,
      onChangeParameter: _editCardsMode
          ? () async {
              if (settings == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Personalização indisponível neste modo.')),
                );
                return;
              }
              final chosen = await CardCustomizationSheet.show(
                context,
                controller: c,
                currentCardKeys: activeKeys,
                title: 'Trocar Card "$title"',
              );
              if (chosen != null) {
                await settings.replaceCard(index, chosen);
              }
            }
          : null,
      onRemove: _editCardsMode
          ? () async {
              if (settings == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Personalização indisponível neste modo.')),
                );
                return;
              }
              final removed = await settings.removeCardAt(index);
              if (removed != null && context.mounted) {
                final messenger = ScaffoldMessenger.of(context);
                messenger.hideCurrentSnackBar();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Card "$title" removido.'),
                    action: SnackBarAction(
                      label: 'Desfazer',
                      onPressed: () => settings.insertCardAt(index, removed),
                    ),
                  ),
                );
              }
            }
          : null,
      onTap: () => ChannelDetailChartSheet.show(
        context,
        controller: c,
        channelKey: activeKey,
        onPinToCharts: widget.onOpenChannelChart == null
            ? null
            : () => widget.onOpenChannelChart!(activeKey),
        onRemoveFromDashboard: settings == null
            ? null
            : () async {
                final removed = await settings.removeCardAt(index);
                if (removed != null && context.mounted) {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.hideCurrentSnackBar();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Card "$title" removido.'),
                      action: SnackBarAction(
                        label: 'Desfazer',
                        onPressed: () => settings.insertCardAt(index, removed),
                      ),
                    ),
                  );
                }
              },
      ),
    );
  }

  (CardAlertState, String) _evaluateCardState(
    TelemetryController c, {
    required String cardKey,
    required String activeKey,
    required double? value,
    required bool hasTurboData,
  }) {
    if (value == null) {
      return (CardAlertState.stale, '');
    }

    if (!c.replayMode) {
      final maxAge = activeKey == 'battery'
          ? 40.0
          : (const {'ect', 'cht_temp', 'ltft', 'ltft_idle', 'speed', 'iat'}.contains(activeKey)
              ? 12.0
              : 3.5);
      final stamp = c.stamps[activeKey];
      if (stamp == null || (c.currentTimeSec - stamp) > maxAge) {
        final paused = c.decelMode &&
            const {'ect', 'cht_temp', 'ltft', 'stft', 'load', 'speed', 'iat', 'battery'}
                .contains(activeKey);
        return (CardAlertState.stale, paused ? 'pausado' : '');
      }
    }

    if (activeKey == 'boost_bar') {
      if (value > 1.40) return (CardAlertState.alarm, 'OVERBOOST');
      if (value > 0.05) return (CardAlertState.normal, 'PRESSÃO');
      return (CardAlertState.normal, 'VÁCUO');
    }

    if (activeKey == 'map' && hasTurboData) {
      final bVal = c.latest['boost_bar'] ??
          (value > 105.0 ? (value - (c.latest['baro'] ?? 101.325)) / 100.0 : null);
      if (bVal != null) {
        if (bVal > 1.40) return (CardAlertState.alarm, 'OVERBOOST');
        if (bVal > 0.05) {
          return (
            CardAlertState.normal,
            'BOOST ${bVal >= 0 ? "+" : ""}${bVal.toStringAsFixed(2)}b',
          );
        }
        return (CardAlertState.normal, 'VAC ${bVal.toStringAsFixed(2)}b');
      }
    }

    final isVagFlex = c.latest.containsKey('ltft_idle') &&
        !c.latest.containsKey('flex_ethanol_pct');

    if (activeKey == 'ltft' && isVagFlex) {
      if (value.abs() >= 24.0) {
        return (CardAlertState.alarm, value < 0 ? 'LIMITE RICA' : 'LIMITE POBRE');
      }
      if (value.abs() >= 22.5) {
        return (CardAlertState.warn, value < 0 ? 'perto batente -' : 'perto batente +');
      }
      if (value <= -13.0) {
        return (CardAlertState.normal, 'A/F Gasolina');
      }
      if (value >= 10.0) {
        return (CardAlertState.normal, 'A/F Etanol');
      }
      return (CardAlertState.normal, 'A/F Flex');
    } else if (activeKey == 'stft' ||
        activeKey == 'ltft' ||
        activeKey == 'ltft_idle' ||
        activeKey == 'lambda_trim') {
      final warnLim = activeKey == 'ltft_idle' ? 8.0 : 10.0;
      final alarmLim = activeKey == 'ltft_idle' ? 14.0 : 20.0;
      if (value.abs() > alarmLim) {
        return (CardAlertState.alarm, value < 0 ? 'RICA' : 'POBRE');
      }
      if (value.abs() > warnLim) {
        return (CardAlertState.warn, value < 0 ? 'corrigindo -' : 'corrigindo +');
      }
    } else if (activeKey == 'ect' || activeKey == 'cht_temp') {
      if (value >= 108.0) return (CardAlertState.alarm, 'SUPERAQUEC.');
      if (value < 70.0) return (CardAlertState.warn, 'frio');
    } else if (activeKey == 'battery' || activeKey == 'ecu_volt' || activeKey == 'obd_pin16_v') {
      if (value < 11.6 || value > 15.0) {
        return (CardAlertState.alarm, value < 11.6 ? 'baixa' : 'alta');
      }
      final rpm = c.latest['rpm'] ?? 0.0;
      if (rpm >= 500.0) {
        if (value < 12.0) return (CardAlertState.alarm, 'baixa');
        if (value < 13.0) return (CardAlertState.warn, 'sem carga?');
      } else {
        if (value < 12.1) return (CardAlertState.warn, 'fraca');
        return (CardAlertState.normal, 'repouso');
      }
    } else if (activeKey == 'advance') {
      final tpsCur = c.latest['tps'];
      final mapCur = c.latest['map'];
      final isDashpot = tpsCur != null &&
          tpsCur <= 6.5 &&
          mapCur != null &&
          mapCur <= 58.0;
      if (isDashpot) {
        if (value < -5.0) return (CardAlertState.normal, 'dashpot');
        return (CardAlertState.normal, '');
      }
      if (value < -8.0) return (CardAlertState.alarm, 'RETARDO ATDC');
      if (value < -5.0) return (CardAlertState.warn, 'retardado');
    } else if (activeKey == 'lambda_v') {
      return _lambda1State(c);
    } else if (activeKey == 'lambda2_v') {
      return _lambda2State(c);
    }

    return (CardAlertState.normal, '');
  }

  List<double> _valuesInWindow(SeriesBuffer buf, double tFrom, double tTo) {
    final slice = buf.window(tFrom);
    final out = <double>[];
    for (var i = 0; i < slice.times.length; i++) {
      if (slice.times[i] <= tTo) {
        out.add(slice.values[i]);
      } else {
        break;
      }
    }
    return out;
  }

  (CardAlertState, String) _lambda1State(TelemetryController c) {
    final rpm = c.latest['rpm'] ?? 0.0;
    final ect = c.latest['ect'] ?? c.latest['cht_temp'];
    if (rpm < 650.0 || c.detector.inDecel) {
      return (CardAlertState.normal, '');
    }
    if (ect != null && ect < 65.0) {
      return (CardAlertState.normal, 'malha aberta');
    }

    final lamEq = c.latest['lambda_eq'];
    if (lamEq != null) {
      if (lamEq > 1.50) return (CardAlertState.normal, 'cut-off');
      if (lamEq > 1.08) return (CardAlertState.warn, 'POBRE');
      if (lamEq < 0.90) {
        return (lamEq >= 0.80 ? CardAlertState.warn : CardAlertState.alarm, 'RICA');
      }
      if (lamEq >= 0.95 && lamEq <= 1.05) {
        return (CardAlertState.normal, 'ESTEQ');
      }
      return (CardAlertState.normal, 'λ ${lamEq.toStringAsFixed(2)}');
    }

    final buf = c.buffers['lambda_v'];
    if (buf == null) return (CardAlertState.normal, '');
    final refT = c.replayMode ? c.replayScrubTime : c.currentTimeSec;
    final vals = _valuesInWindow(buf, refT - 4.0, refT);
    if (vals.length < 4) return (CardAlertState.normal, '');
    final minV = vals.reduce(math.min);
    final maxV = vals.reduce(math.max);
    if ((maxV - minV) < 0.06) {
      final mean = vals.reduce((a, b) => a + b) / vals.length;
      final suffix = mean > 0.6 ? 'RICA' : (mean < 0.3 ? 'POBRE' : '');
      return (CardAlertState.alarm, 'TRAVADA $suffix'.trim());
    }
    return (CardAlertState.normal, '');
  }

  (CardAlertState, String) _lambda2State(TelemetryController c) {
    final rpm = c.latest['rpm'] ?? 0.0;
    final ect = c.latest['ect'] ?? c.latest['cht_temp'];
    final buf2 = c.buffers['lambda2_v'];
    if (buf2 == null || rpm < 650.0 || c.detector.inDecel) {
      return (CardAlertState.normal, '');
    }
    if (ect != null && ect < 65.0) {
      return (CardAlertState.normal, 'aquecendo');
    }
    final refT = c.replayMode ? c.replayScrubTime : c.currentTimeSec;
    final vals2 = _valuesInWindow(buf2, refT - 6.0, refT);
    if (vals2.length < 4) return (CardAlertState.normal, '');
    final ptp2 = vals2.reduce(math.max) - vals2.reduce(math.min);
    final m2 = vals2.reduce((a, b) => a + b) / vals2.length;

    final buf1 = c.buffers['lambda_v'];
    if (buf1 != null) {
      final vals1 = _valuesInWindow(buf1, refT - 6.0, refT);
      if (vals1.length >= 4) {
        final ptp1 = vals1.reduce(math.max) - vals1.reduce(math.min);
        if (ptp1 > 0.35 && ptp2 > 0.30) {
          return (CardAlertState.alarm, 'CATALISADOR?');
        }
      }
    }
    if (m2 < 0.15) return (CardAlertState.warn, 'POBRE/AR');
    return (CardAlertState.normal, 'CATAL. OK');
  }

  List<String> _extraChannelKeys(TelemetryController c) {
    final cardSet = (widget.settings?.dashboardCardKeys ?? cardChannelKeys).toSet();
    final keys = <String>{
      ...c.latest.keys.where((k) => !cardSet.contains(k)),
      ...c.knownChannels.keys.where((k) => !cardSet.contains(k)),
    }.toList();
    keys.sort((a, b) {
      // Prioriza Blocos 103.5 / 103.6 e canais ativos
      final aHas = c.latest.containsKey(a) ? 0 : 1;
      final bHas = c.latest.containsKey(b) ? 0 : 1;
      if (aHas != bHas) return aHas.compareTo(bHas);
      return a.compareTo(b);
    });
    return keys;
  }

  String _channelLabelForExtra(TelemetryController c, String key) {
    if (key.startsWith('g') && key.contains('_c')) {
      final parts = key.substring(1).split('_c');
      if (parts.length == 2) {
        final grp = int.tryParse(parts[0]);
        final cell = int.tryParse(parts[1]);
        if (grp != null && cell != null) {
          final known = vagKnownLabels[(grp, cell)];
          final grpStr = grp.toString().padLeft(3, '0');
          return known != null ? 'Bloco $grpStr.$cell · $known' : 'Bloco $grpStr.$cell';
        }
      }
    }
    return describeChannel(key, c.knownChannels).label;
  }

  Widget _buildExtraChannelsSection(TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final allExtras = _extraChannelKeys(c);
    final q = _extraFilter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? allExtras
        : allExtras.where((k) {
            final lbl = _channelLabelForExtra(c, k).toLowerCase();
            return k.toLowerCase().contains(q) || lbl.contains(q);
          }).toList();

    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: tokens.borderSubtle, width: tokens.cardBorderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _showExtraChannels = !_showExtraChannels),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.tune, color: tokens.accent, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Canais Extras, Analítica & Blocos VAG (${allExtras.length})',
                      style: TextStyle(
                        color: tokens.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    _showExtraChannels ? Icons.expand_less : Icons.expand_more,
                    color: tokens.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_showExtraChannels) ...[
            Divider(height: 1, color: tokens.borderSubtle),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _filterCtrl,
                    decoration: InputDecoration(
                      hintText: 'Filtrar canais ou blocos (ex: 103, boost, inj_ms, flex)...',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _extraFilter.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _filterCtrl.clear();
                                setState(() => _extraFilter = '');
                              },
                            )
                          : null,
                    ),
                    onChanged: (v) => setState(() => _extraFilter = v),
                  ),
                  const SizedBox(height: 8),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Nenhum canal extra descoberto ainda.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: tokens.muted, fontSize: 12),
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cols = constraints.maxWidth >= 700
                            ? 3
                            : (constraints.maxWidth >= 460 ? 2 : 1);
                        const gap = 6.0;
                        final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final k in filtered.take(80))
                              SizedBox(
                                width: itemW,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () => ChannelDetailChartSheet.show(
                                    context,
                                    controller: c,
                                    channelKey: k,
                                    onPinToCharts:
                                        widget.onOpenChannelChart == null
                                            ? null
                                            : () => widget.onOpenChannelChart!(k),
                                  ),
                                  child: _ExtraChannelTile(
                                    channelKey: k,
                                    label: _channelLabelForExtra(c, k),
                                    unit: describeChannel(k, c.knownChannels).unit,
                                    value: c.latest[k],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExtraChannelTile extends StatelessWidget {
  const _ExtraChannelTile({
    required this.channelKey,
    required this.label,
    required this.unit,
    required this.value,
  });

  final String channelKey;
  final String label;
  final String unit;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final color = MotorsportColors.colorForChannel(channelKey);
    final valStr = value == null ? '--' : value!.toStringAsFixed(2);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.plot,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  channelKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.stale,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            unit.isNotEmpty ? '$valStr $unit' : valStr,
            style: MotorsportTheme.tabularStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: value == null ? tokens.stale : color,
            ),
          ),
        ],
      ),
    );
  }
}
