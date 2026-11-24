import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/channel_def.dart';
import '../../core/protocols/vag_formulas.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/channel_detail_chart_sheet.dart';
import '../widgets/connection_sheet.dart';
import '../widgets/value_card.dart';

/// Aba Painel: foco exclusivo nos cards numéricos motorsport e canais extras.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.controller,
    this.onOpenChannelChart,
  });

  final TelemetryController controller;
  final ValueChanged<String>? onOpenChannelChart;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _showExtraChannels = false;
  String _extraFilter = '';
  final TextEditingController _filterCtrl = TextEditingController();

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;

        return SingleChildScrollView(
          padding: EdgeInsets.all(isTablet ? 12 : 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.replayMode) ...[
                _buildReplayBanner(c),
                const SizedBox(height: 8),
              ],
              _buildActionBar(context, c),
              const SizedBox(height: 8),
              _buildStatusRibbon(c),
              const SizedBox(height: 10),
              _buildCardsGrid(c),
              const SizedBox(height: 12),
              _buildExtraChannelsSection(c),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReplayBanner(TelemetryController c) {
    final ds = c.replayDataset;
    final minT = ds?.minTime ?? 0.0;
    final maxT = ds != null && ds.maxTime > minT ? ds.maxTime : minT + 1.0;
    final val = c.replayScrubTime.clamp(minT, maxT);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0E2530),
        border: Border.all(color: MotorsportColors.info),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.replay, color: MotorsportColors.info, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'MODO REPLAY: ${c.replayFileName ?? "CSV"}  ·  t = ${val.toStringAsFixed(2)}s / ${maxT.toStringAsFixed(1)}s',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotorsportTheme.tabularStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: MotorsportColors.info,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: c.exitReplayMode,
                style: OutlinedButton.styleFrom(
                  foregroundColor: MotorsportColors.alarm,
                  side: const BorderSide(color: MotorsportColors.alarm),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                icon: const Icon(Icons.close, size: 15),
                label: const Text('Sair do Replay'),
              ),
            ],
          ),
          Slider(
            value: val,
            min: minT,
            max: maxT,
            activeColor: MotorsportColors.info,
            inactiveColor: MotorsportColors.border,
            onChanged: c.scrubReplay,
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, TelemetryController c) {
    final connectedOrBusy = c.isConnected || c.connectionState == ConnectionStateKind.connecting;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: connectedOrBusy
              ? c.disconnect
              : () => ConnectionSheet.show(context, c),
          style: ElevatedButton.styleFrom(
            backgroundColor: connectedOrBusy
                ? const Color(0xFF511D2B)
                : const Color(0xFF073B29),
            foregroundColor: connectedOrBusy
                ? const Color(0xFFFFD6E0)
                : const Color(0xFFA9FFD3),
            side: BorderSide(
              color: connectedOrBusy ? MotorsportColors.alarm : MotorsportColors.ok,
            ),
          ),
          icon: Icon(
            connectedOrBusy ? Icons.link_off : Icons.power_settings_new,
            size: 16,
          ),
          label: Text(connectedOrBusy ? 'Desconectar' : 'Conectar'),
        ),
        ElevatedButton.icon(
          onPressed: c.toggleRecording,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.isRecording
                ? const Color(0xFF531426)
                : MotorsportColors.elevated,
            foregroundColor: c.isRecording
                ? const Color(0xFFFFD6E0)
                : MotorsportColors.text,
            side: BorderSide(
              color: c.isRecording ? MotorsportColors.alarm : MotorsportColors.border,
            ),
          ),
          icon: Icon(
            c.isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
            size: 16,
            color: c.isRecording ? MotorsportColors.alarm : MotorsportColors.alarm,
          ),
          label: Text(
            c.isRecording ? 'Parar (${c.recordingRows})' : '● Gravar Log',
          ),
        ),
        OutlinedButton.icon(
          onPressed: c.clearPeaks,
          icon: const Icon(Icons.bolt, size: 16),
          label: const Text('Limpar Picos'),
        ),
        FilterChip(
          selected: c.decelMode,
          label: const Text('Desaceleração'),
          labelStyle: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: c.decelMode ? const Color(0xFFFFE2A1) : MotorsportColors.text,
          ),
          selectedColor: const Color(0xFF493512),
          checkmarkColor: MotorsportColors.warning,
          side: BorderSide(
            color: c.decelMode ? MotorsportColors.warning : MotorsportColors.border,
          ),
          onSelected: (v) {
            c.decelMode = v;
            c.emitInfo(
              v
                  ? 'Modo Prioridade de Desaceleração ATIVADO'
                  : 'Modo Prioridade de Desaceleração desativado',
            );
          },
        ),
        FilterChip(
          selected: _showExtraChannels,
          label: Text('Canais Extras (${_extraChannelKeys(c).length})'),
          labelStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
          selectedColor: MotorsportColors.info.withValues(alpha: 0.18),
          checkmarkColor: MotorsportColors.info,
          side: BorderSide(
            color: _showExtraChannels ? MotorsportColors.info : MotorsportColors.border,
          ),
          onSelected: (v) => setState(() => _showExtraChannels = v),
        ),
      ],
    );
  }

  Widget _buildStatusRibbon(TelemetryController c) {
    final lastEv = c.events.isNotEmpty ? c.events.last : null;
    final String badgeText;
    final Color badgeColor;
    final String messageText;

    if (c.isEcuOff) {
      badgeText = '● ECU OFF';
      badgeColor = MotorsportColors.alarm;
      messageText = c.statusMessage;
    } else if (lastEv != null) {
      badgeText = switch (lastEv.level) {
        'alarm' => '● ALARME',
        'warn' => '▲ ATENÇÃO',
        _ => '● INFO',
      };
      badgeColor = switch (lastEv.level) {
        'alarm' => MotorsportColors.alarm,
        'warn' => MotorsportColors.warning,
        _ => MotorsportColors.info,
      };
      messageText = lastEv.message;
    } else {
      badgeText = c.isConnected ? '● ECU' : '● INFO';
      badgeColor = c.isConnected ? MotorsportColors.ok : MotorsportColors.info;
      messageText = c.ecuMetadata.ecuName.isNotEmpty && c.isConnected
          ? '${c.ecuMetadata.ecuName} — ${c.statusMessage}'
          : c.statusMessage;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: MotorsportColors.surfaceAlt,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Text(
            badgeText,
            style: TextStyle(
              color: badgeColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              messageText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MotorsportColors.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardsGrid(TelemetryController c) {
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

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final key in cardChannelKeys)
              SizedBox(
                width: cardWidth,
                child: _buildAdaptedCard(c, key, compact: compact),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAdaptedCard(
    TelemetryController c,
    String key, {
    required bool compact,
  }) {
    final latest = c.latest;
    final hasTurboData = c.ecuMetadata.isTurbo ||
        (latest['map'] ?? 0.0) > 105.0 ||
        latest.containsKey('boost_target_bar') ||
        latest.containsKey('wastegate_pct') ||
        latest.containsKey('fuel_rail_bar') ||
        latest.containsKey('turbo_inlet_kpa');

    final def = coreChannels[key]!;
    String activeKey = key;
    String title = def.label;
    String unit = def.unit;
    int decimals = def.decimals;
    bool signed = def.signed;

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
      onTap: () => ChannelDetailChartSheet.show(
        context,
        controller: c,
        channelKey: activeKey,
        onPinToCharts: widget.onOpenChannelChart == null
            ? null
            : () => widget.onOpenChannelChart!(activeKey),
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
          : (const {'ect', 'ltft', 'ltft_idle', 'speed', 'iat'}.contains(activeKey)
              ? 12.0
              : 3.5);
      final stamp = c.stamps[activeKey];
      if (stamp == null || (c.currentTimeSec - stamp) > maxAge) {
        final paused = c.decelMode &&
            const {'ect', 'ltft', 'stft', 'load', 'speed', 'iat', 'battery'}.contains(activeKey);
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
        if (bVal > 0.05) return (CardAlertState.normal, 'BOOST ${bVal >= 0 ? "+" : ""}${bVal.toStringAsFixed(2)}b');
        return (CardAlertState.normal, 'VAC ${bVal.toStringAsFixed(2)}b');
      }
    }

    if (activeKey == 'stft' ||
        activeKey == 'ltft' ||
        activeKey == 'ltft_idle' ||
        activeKey == 'lambda_trim') {
      if (value.abs() > 20.0) {
        return (CardAlertState.alarm, value < 0 ? 'RICA' : 'POBRE');
      }
      if (value.abs() > 10.0) {
        return (CardAlertState.warn, value < 0 ? 'corrigindo -' : 'corrigindo +');
      }
    } else if (activeKey == 'ect') {
      if (value >= 108.0) return (CardAlertState.alarm, 'SUPERAQUEC.');
      if (value < 70.0) return (CardAlertState.warn, 'frio');
    } else if (activeKey == 'battery') {
      if (value < 12.0 || value > 15.0) {
        return (CardAlertState.alarm, value < 12.0 ? 'baixa' : 'alta');
      }
      if (value < 13.0) return (CardAlertState.warn, 'sem carga?');
    } else if (activeKey == 'advance' && value < -5.0) {
      return (CardAlertState.warn, 'retardado');
    } else if (activeKey == 'lambda_v') {
      return _lambda1State(c);
    } else if (activeKey == 'lambda2_v') {
      return _lambda2State(c);
    }

    return (CardAlertState.normal, '');
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
    final win = buf.window(c.currentTimeSec - 4.0);
    if (win.values.length < 4) return (CardAlertState.normal, '');
    final minV = win.values.reduce(math.min);
    final maxV = win.values.reduce(math.max);
    if ((maxV - minV) < 0.06) {
      final mean = win.values.reduce((a, b) => a + b) / win.values.length;
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
    final win2 = buf2.window(c.currentTimeSec - 6.0);
    if (win2.values.length < 4) return (CardAlertState.normal, '');
    final ptp2 = win2.values.reduce(math.max) - win2.values.reduce(math.min);
    final m2 = win2.values.reduce((a, b) => a + b) / win2.values.length;

    final buf1 = c.buffers['lambda_v'];
    if (buf1 != null) {
      final win1 = buf1.window(c.currentTimeSec - 6.0);
      if (win1.values.length >= 4) {
        final ptp1 = win1.values.reduce(math.max) - win1.values.reduce(math.min);
        if (ptp1 > 0.35 && ptp2 > 0.30) {
          return (CardAlertState.alarm, 'CATALISADOR?');
        }
      }
    }
    if (m2 < 0.15) return (CardAlertState.warn, 'POBRE/AR');
    return (CardAlertState.normal, 'CATAL. OK');
  }

  List<String> _extraChannelKeys(TelemetryController c) {
    final cardSet = cardChannelKeys.toSet();
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
    final allExtras = _extraChannelKeys(c);
    final q = _extraFilter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? allExtras
        : allExtras.where((k) {
            final lbl = _channelLabelForExtra(c, k).toLowerCase();
            return k.toLowerCase().contains(q) || lbl.contains(q);
          }).toList();

    return Container(
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _showExtraChannels = !_showExtraChannels),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: MotorsportColors.info, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Canais Extras, Analítica & Blocos VAG (${allExtras.length})',
                      style: const TextStyle(
                        color: MotorsportColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    _showExtraChannels ? Icons.expand_less : Icons.expand_more,
                    color: MotorsportColors.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_showExtraChannels) ...[
            const Divider(height: 1),
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
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Nenhum canal extra descoberto ainda.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: MotorsportColors.muted, fontSize: 12),
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cols = constraints.maxWidth >= 700 ? 3 : (constraints.maxWidth >= 460 ? 2 : 1);
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
                                  borderRadius: BorderRadius.circular(3),
                                  onTap: () => ChannelDetailChartSheet.show(
                                    context,
                                    controller: c,
                                    channelKey: k,
                                    onPinToCharts:
                                        widget.onOpenChannelChart == null
                                            ? null
                                            : () =>
                                                widget.onOpenChannelChart!(k),
                                  ),
                                  child: _ExtraChannelTile(
                                    channelKey: k,
                                    label: _channelLabelForExtra(c, k),
                                    unit: describeChannel(k, c.knownChannels)
                                        .unit,
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
    final color = MotorsportColors.colorForChannel(channelKey);
    final valStr = value == null ? '--' : value!.toStringAsFixed(2);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: MotorsportColors.plot,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(3),
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
                  style: const TextStyle(
                    color: MotorsportColors.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  channelKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MotorsportColors.stale,
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
              color: value == null ? MotorsportColors.stale : color,
            ),
          ),
        ],
      ),
    );
  }
}
