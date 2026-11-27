import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analytics/math_channels.dart';
import '../../core/models/channel_def.dart';
import '../../core/models/vehicle_profile.dart';
import '../../core/settings/app_settings.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/flex_af_status_card.dart';
import '../widgets/uniform_action_button.dart';

/// Aba Funções: DTCs, Flex A/F, VAG KWP2000, Painel 0x17, Arrancada, Ford HS-CAN & Console.
class FunctionsScreen extends StatefulWidget {
  const FunctionsScreen({
    super.key,
    required this.controller,
    this.settings,
  });

  final TelemetryController controller;
  final AppSettingsController? settings;

  @override
  State<FunctionsScreen> createState() => _FunctionsScreenState();
}

class _FunctionsScreenState extends State<FunctionsScreen> {
  late TextEditingController _massCtrl;
  late TextEditingController _priceCtrl;
  final FocusNode _massFocus = FocusNode();
  final FocusNode _priceFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _massCtrl = TextEditingController(
      text: widget.controller.mathEngine.vehicleMassKg.toStringAsFixed(0),
    );
    _priceCtrl = TextEditingController(
      text: widget.controller.mathEngine.fuelPriceBrl.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _massCtrl.dispose();
    _priceCtrl.dispose();
    _massFocus.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  void _syncEngineInputs(TelemetryController c) {
    final massStr = c.mathEngine.vehicleMassKg.toStringAsFixed(0);
    if (!_massFocus.hasFocus && _massCtrl.text != massStr) {
      _massCtrl.text = massStr;
    }
    final priceStr = c.mathEngine.fuelPriceBrl.toStringAsFixed(2);
    if (!_priceFocus.hasFocus && _priceCtrl.text != priceStr) {
      _priceCtrl.text = priceStr;
    }
  }

  Future<void> _confirmClearDtcs(TelemetryController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar Códigos de Falha (DTC)?'),
        content: const Text(
          'Isso apagará todos os DTCs armazenados e zerará os monitores de prontidão.\n\n'
          'Execute com a ignição LIGADA e o motor DESLIGADO.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: MotorsportColors.alarmBg,
              foregroundColor: MotorsportColors.alarm,
              side: const BorderSide(color: MotorsportColors.alarm),
            ),
            child: const Text('Apagar DTCs'),
          ),
        ],
      ),
    );
    if (ok == true) {
      c.requestClearDtcs();
    }
  }

  Future<void> _confirmResetAdaptation(TelemetryController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Adaptação / Flex (Canal 00)'),
        content: const Text(
          'ATENÇÃO: Isso enviará o comando KWP2000 de Reset de Adaptação (Canal 00 / Basic Setting 000) '
          'para restaurar os ajustes de mistura (Bloco 032 LTFT e A/F na EEPROM).\n\n'
          'Nota: Em algumas calibrações Bosch ME7.5.30, a central rejeita o reset via ELM327 '
          'e exige cabo KKL / VCDS (Adaptação Canal 00).\n\n'
          'Requisitos obrigatórios:\n'
          '• Motor aquecido (> 80 °C)\n'
          '• Ignição LIGADA e motor PARADO\n'
          '• Após confirmar, desligue a chave por 60s antes da partida.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: MotorsportColors.alarmBg,
              foregroundColor: MotorsportColors.alarm,
              side: const BorderSide(color: MotorsportColors.alarm),
            ),
            child: const Text('Confirmar Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      c.requestResetAdaptation();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        _syncEngineInputs(c);
        final isTablet =
            MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;

        final showFlexCard = c.vehicleProfile != VehicleProfileId.fordKa ||
            c.latest.containsKey('ltft_idle') ||
            c.latest.containsKey('ltft');

        final cards = <Widget>[
          _buildDiagnosticsCard(context, c),
          if (showFlexCard) FlexAfStatusCard(controller: c),
          _buildVagAndPowerCard(context, c),
          _buildPerformanceCard(context, c),
          _buildFordModulesCard(context, c),
          _buildEventsConsoleCard(context, c),
        ];

        if (isTablet) {
          final lastIdx = cards.length - 1;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final colW = (constraints.maxWidth - gap) / 2;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < lastIdx; i++)
                      SizedBox(width: colW, child: cards[i]),
                    SizedBox(width: constraints.maxWidth, child: cards[lastIdx]),
                  ],
                );
              },
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) => cards[i],
        );
      },
    );
  }

  Widget _buildDiagnosticsCard(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final online = c.isConnected;
    return UniformSectionCard(
      title: 'Diagnóstico, DTCs & Emissões',
      icon: Icons.build_circle_outlined,
      accent: MotorsportColors.alarm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UniformButtonGrid(
            columns: 2,
            children: [
              UniformActionButton(
                label: 'Ler Falhas',
                icon: Icons.search,
                variant: UniformActionVariant.info,
                onTap: online ? c.requestReadDtcs : null,
              ),
              UniformActionButton(
                label: 'Limpar DTCs',
                icon: Icons.delete_sweep,
                variant: UniformActionVariant.danger,
                onTap: online ? () => _confirmClearDtcs(c) : null,
              ),
              UniformActionButton(
                label: 'I/M Readiness',
                icon: Icons.fact_check_outlined,
                variant: UniformActionVariant.neutral,
                onTap: online ? c.requestReadiness : null,
              ),
              UniformActionButton(
                label: 'Freeze Frame',
                icon: Icons.ac_unit,
                variant: UniformActionVariant.neutral,
                onTap: online ? c.requestFreezeFrame : null,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: c.dtcMilOn ? MotorsportColors.alarm : MotorsportColors.ok,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'MIL: ${c.dtcMilOn ? "ACESA" : "Apagada"} · ${c.dtcs.length} falha(s) listada(s)',
                  style: TextStyle(
                    color: c.dtcMilOn ? MotorsportColors.alarm : MotorsportColors.ok,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (c.dtcs.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final d in c.dtcs)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: tokens.plot,
                  border: Border.all(color: MotorsportColors.alarmBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.code,
                      style: MotorsportTheme.tabularStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: MotorsportColors.alarm,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        d.description,
                        style: TextStyle(fontSize: 11.5, color: tokens.text),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (c.readinessReport != null) ...[
            const SizedBox(height: 10),
            _buildReadinessSummary(tokens, c.readinessReport!),
          ],
          if (c.freezeFrameData != null) ...[
            const SizedBox(height: 10),
            _buildFreezeFrameSummary(tokens, c.freezeFrameData!),
          ],
        ],
      ),
    );
  }

  Widget _buildReadinessSummary(
    MotorsportVisualTokens tokens,
    ReadinessReport rep,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: tokens.plot,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'I/M Readiness: ${rep.readyCount}/${rep.supportedCount} prontos (DTCs: ${rep.dtcCount})',
            style: TextStyle(
              color: tokens.accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final m in rep.monitors.where((m) => m.supported))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: m.completed
                        ? const Color(0xFF173E28)
                        : const Color(0xFF4C3912),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${m.completed ? "✔" : "✖"} ${m.name}',
                    style: TextStyle(
                      color: m.completed
                          ? MotorsportColors.ok
                          : MotorsportColors.warning,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFreezeFrameSummary(
    MotorsportVisualTokens tokens,
    FreezeFrameData ff,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: tokens.plot,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Freeze Frame · DTC: ${ff.dtc}',
            style: const TextStyle(
              color: MotorsportColors.alarm,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final entry in ff.values.entries)
                () {
                  final desc = describeChannel(entry.key);
                  final unit = desc.unit.isNotEmpty ? ' ${desc.unit}' : '';
                  return Text(
                    '${desc.label}: ${entry.value.toStringAsFixed(1)}$unit',
                    style: MotorsportTheme.tabularStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  );
                }(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVagAndPowerCard(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final online = c.isConnected;
    final volt =
        c.latest['obd_pin16_v'] ?? c.latest['battery'] ?? c.latest['ecu_volt'];
    final rpm = c.latest['rpm'] ?? 0.0;
    final batEval = volt != null
        ? MathChannelsEngine.evaluateBatteryHealth(
            volt,
            rpm: rpm,
            minCrankVolt: c.mathEngine.minCrankVolt,
          )
        : null;
    final klinePaused = c.pollDelayMs < 0;

    return UniformSectionCard(
      title: 'VAG KWP2000, Painel 0x17 & Power Latch',
      icon: Icons.bolt,
      accent: MotorsportColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UniformButtonGrid(
            columns: 2,
            children: [
              UniformActionButton(
                label: 'Forçar VAG KWP',
                icon: Icons.sync,
                variant: UniformActionVariant.info,
                onTap: online ? c.requestForceVagKwp : null,
              ),
              UniformActionButton(
                label: c.clusterBusy ? 'Lendo Painel...' : 'Ler Tanque (0x17)',
                icon: Icons.local_gas_station_outlined,
                variant: UniformActionVariant.info,
                onTap: online && !c.clusterBusy ? c.requestReadCluster : null,
              ),
              UniformActionButton(
                label: 'Varrer Blocos',
                icon: Icons.radar,
                variant: UniformActionVariant.neutral,
                tooltip: 'Varrer Blocos 001..255',
                onTap: online ? c.requestScanAll : null,
              ),
              UniformActionButton(
                label: 'Reset Adaptação',
                icon: Icons.restart_alt,
                variant: UniformActionVariant.warn,
                onTap: online ? () => _confirmResetAdaptation(c) : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tokens.plot,
              border: Border.all(
                color: tokens.borderSubtle,
                width: tokens.cardBorderWidth,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.speed_outlined, color: tokens.accent, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Painel de Instrumentos (Módulo 0x17)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricChip(
                        'Tanque',
                        c.clusterFuelLiters != null
                            ? '${c.clusterFuelLiters!.toStringAsFixed(1)} L'
                            : '-- L',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _MetricChip(
                        'Boia',
                        c.clusterFuelOhms != null
                            ? '${c.clusterFuelOhms!.toStringAsFixed(0)} Ω'
                            : '-- Ω',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _MetricChip(
                        'Odômetro',
                        c.clusterOdometerKm != null
                            ? '${c.clusterOdometerKm!.toStringAsFixed(0)} km'
                            : '-- km',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tokens.plot,
              border: Border.all(
                color: c.isEcuOff ? MotorsportColors.alarm : tokens.borderSubtle,
                width: tokens.cardBorderWidth,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.battery_charging_full,
                      color: tokens.accent,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        volt != null
                            ? 'Tensão Pino 16 / ECU: ${volt.toStringAsFixed(2)} V'
                            : 'Tensão Pino 16 / ECU: -- V',
                        style: MotorsportTheme.tabularStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: tokens.accent,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  batEval != null
                      ? 'Saúde Elétrica: ${batEval.message}'
                      : 'Saúde Elétrica: aguardando leitura de tensão.',
                  style: TextStyle(
                    color: batEval != null && batEval.status.contains('fault')
                        ? MotorsportColors.alarm
                        : tokens.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  c.lastPowerLatchDurationSec != null
                      ? 'Último Power Latch: ${c.lastPowerLatchDurationSec!.toStringAsFixed(1)} s após desligar o motor'
                      : 'Último Power Latch: aguardando ciclo de desligamento (ECU OFF)',
                  style: TextStyle(
                    color: c.isEcuOff ? MotorsportColors.alarm : tokens.stale,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                UniformActionButton(
                  label: klinePaused ? 'Retomar Linha K' : 'Pausar Linha K',
                  icon: klinePaused ? Icons.play_arrow : Icons.volume_off,
                  variant: klinePaused
                      ? UniformActionVariant.warn
                      : UniformActionVariant.neutral,
                  active: klinePaused,
                  onTap: online
                      ? () {
                          c.pollDelayMs = klinePaused ? 0 : -1;
                          c.emitInfo(
                            c.pollDelayMs < 0
                                ? 'Linha K pausada (Keepalive ativo, sem ruído no som).'
                                : 'Linha K retomada em taxa máxima.',
                          );
                        }
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceCard(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final rec = c.perfTimer.record;
    final latest = c.latest;

    String fmtSec(double? v) => v == null ? '-- s' : '${v.toStringAsFixed(2)} s';

    final perfChips = [
      _MetricChip('0–60 km/h', fmtSec(rec.time0to60)),
      _MetricChip('0–100 km/h', fmtSec(rec.time0to100)),
      _MetricChip('80–120 km/h', fmtSec(rec.time80to120)),
      _MetricChip('100–200 km/h', fmtSec(rec.time100to200)),
      _MetricChip('201m (1/8)', fmtSec(rec.time201m)),
      _MetricChip('402m (1/4)', fmtSec(rec.time402m)),
      _MetricChip('100–0 Fren.', fmtSec(rec.braking100to0)),
      _MetricChip('G Máx', '${rec.maxG.toStringAsFixed(2)} G'),
      _MetricChip('V Máx', '${rec.maxSpeed.toStringAsFixed(1)} km/h'),
    ];

    final tripChips = [
      _MetricChip(
        'Combustível',
        '${(latest['trip_liters'] ?? c.mathEngine.tripLiters).toStringAsFixed(3)} L',
      ),
      _MetricChip(
        'Distância',
        '${(latest['trip_km'] ?? c.mathEngine.tripKm).toStringAsFixed(2)} km',
      ),
      _MetricChip(
        'Custo Viagem',
        'R\$ ${(latest['trip_cost_brl'] ?? 0.0).toStringAsFixed(2)}',
      ),
      _MetricChip(
        'Média',
        (latest['trip_avg_kml'] ?? 0.0) > 0
            ? '${latest['trip_avg_kml']!.toStringAsFixed(1)} km/l'
            : '-- km/l',
      ),
      _MetricChip(
        'Potência / Torque',
        '${(latest['power_hp'] ?? 0.0).toStringAsFixed(1)} cv · ${(latest['torque_kgfm'] ?? 0.0).toStringAsFixed(1)} kgfm',
      ),
    ];

    return UniformSectionCard(
      title: 'Cronômetro de Arrancada (Dragy) & Viagem',
      icon: Icons.timer_outlined,
      accent: MotorsportColors.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  c.lastPerfEvent ??
                      'Estado: ${c.perfTimer.state} — Aguardando largada',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MotorsportColors.ok,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: UniformActionButton(
                  label: 'Zerar',
                  icon: Icons.refresh,
                  height: 36,
                  variant: UniformActionVariant.neutral,
                  onTap: () {
                    c.perfTimer.reset();
                    c.mathEngine.resetTrip();
                    c.emitInfo('Cronômetro e integradores da viagem zerados.');
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 500 ? 3 : 2;
              const gap = 6.0;
              final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final chip in perfChips)
                    SizedBox(width: itemW, child: chip),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 500 ? 3 : 2;
              const gap = 6.0;
              final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < tripChips.length; i++)
                    SizedBox(
                      width: (i == tripChips.length - 1 && cols == 2)
                          ? constraints.maxWidth
                          : itemW,
                      child: tripChips[i],
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _massCtrl,
                  focusNode: _massFocus,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    label: Text(
                      'Massa (kg)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onChanged: (v) {
                    final parsed = double.tryParse(v.replaceAll(',', '.'));
                    if (parsed != null && parsed >= 400 && parsed <= 4000) {
                      c.mathEngine.vehicleMassKg = parsed;
                      widget.settings?.setEngineCalibration(vehicleMassKg: parsed);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  focusNode: _priceFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    label: Text(
                      r'Preço Comb. (R$/L)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onChanged: (v) {
                    final parsed = double.tryParse(v.replaceAll(',', '.'));
                    if (parsed != null && parsed > 0 && parsed < 50) {
                      c.mathEngine.fuelPriceBrl = parsed;
                      widget.settings?.setEngineCalibration(fuelPriceBrl: parsed);
                    }
                  },
                ),
              ),
            ],
          ),
          if (c.perfTimer.history.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'HISTÓRICO DE PUXADAS',
              style: TextStyle(
                color: tokens.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            for (final h in c.perfTimer.history.reversed.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '0-100: ${fmtSec(h.time0to100)} | 201m: ${fmtSec(h.time201m)} | 402m: ${fmtSec(h.time402m)} | Vmáx: ${h.maxSpeed.toStringAsFixed(1)} km/h',
                  style: MotorsportTheme.tabularStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildFordModulesCard(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    final l = c.latest;
    final hasFord = l.keys.any(
      (k) =>
          k.startsWith('door_') ||
          k.startsWith('wheel_speed_') ||
          k.startsWith('steering_') ||
          k == 'low_beam' ||
          k == 'odometer_km',
    );

    final statusSummary = c.ecuMetadata.canModules.isNotEmpty
        ? 'Módulos CAN: ${c.ecuMetadata.canModules.join(" · ")}'
        : (hasFord
            ? 'Telemetria multimodular ativa'
            : 'BCM · ABS 4 Rodas · EPAS · IPC');

    return UniformSectionCard(
      title: 'Módulos Ford HS-CAN (BCM · ABS · EPAS · IPC)',
      icon: Icons.directions_car_outlined,
      accent: tokens.accent,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey<bool>(hasFord),
          initiallyExpanded: hasFord,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 8),
          iconColor: tokens.accent,
          collapsedIconColor: tokens.muted,
          title: Text(
            statusSummary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasFord ? tokens.text : tokens.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          children: [
            UniformActionButton(
              label: 'Identificar Módulos',
              icon: Icons.lan_outlined,
              variant: UniformActionVariant.info,
              onTap: c.isConnected ? c.requestScanAll : null,
            ),
            const SizedBox(height: 10),
            if (!hasFord)
              Text(
                'Conecte em um Ford HS-CAN (ou Demo Ford Ka+ Sigma) para visualizar portas, faróis, velocidades das 4 rodas e EPAS.',
                style: TextStyle(color: tokens.stale, fontSize: 12),
              )
            else ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _StatusBadge(
                    'DE',
                    (l['door_fl'] ?? 0) > 0.5,
                    activeLabel: 'ABERTA',
                    idleLabel: 'Fechada',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'DD',
                    (l['door_fr'] ?? 0) > 0.5,
                    activeLabel: 'ABERTA',
                    idleLabel: 'Fechada',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'TE',
                    (l['door_rl'] ?? 0) > 0.5,
                    activeLabel: 'ABERTA',
                    idleLabel: 'Fechada',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'TD',
                    (l['door_rr'] ?? 0) > 0.5,
                    activeLabel: 'ABERTA',
                    idleLabel: 'Fechada',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'Mala',
                    (l['door_trunk'] ?? 0) > 0.5,
                    activeLabel: 'ABERTO',
                    idleLabel: 'Fechado',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'Capô',
                    (l['door_hood'] ?? 0) > 0.5,
                    activeLabel: 'ABERTO',
                    idleLabel: 'Fechado',
                    alarmOnActive: true,
                  ),
                  _StatusBadge(
                    'Farol Baixo',
                    (l['low_beam'] ?? 0) > 0.5,
                    activeLabel: 'ON',
                    idleLabel: 'OFF',
                  ),
                  _StatusBadge(
                    'Farol Alto',
                    (l['high_beam'] ?? 0) > 0.5,
                    activeLabel: 'ON',
                    idleLabel: 'OFF',
                  ),
                  _StatusBadge(
                    'Neblina',
                    (l['fog_lights'] ?? 0) > 0.5,
                    activeLabel: 'ON',
                    idleLabel: 'OFF',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth >= 500 ? 3 : 2;
                  const gap = 6.0;
                  final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
                  final fordChips = [
                    _MetricChip(
                      'Roda DE',
                      '${(l['wheel_speed_fl'] ?? 0).toStringAsFixed(1)} km/h',
                    ),
                    _MetricChip(
                      'Roda DD',
                      '${(l['wheel_speed_fr'] ?? 0).toStringAsFixed(1)} km/h',
                    ),
                    _MetricChip(
                      'Roda TE',
                      '${(l['wheel_speed_rl'] ?? 0).toStringAsFixed(1)} km/h',
                    ),
                    _MetricChip(
                      'Roda TD',
                      '${(l['wheel_speed_rr'] ?? 0).toStringAsFixed(1)} km/h',
                    ),
                    _MetricChip(
                      'Freio',
                      '${(l['brake_pressure'] ?? 0).toStringAsFixed(1)} bar',
                    ),
                    _MetricChip(
                      'Volante EPAS',
                      '${(l['steering_wheel_angle'] ?? 0).toStringAsFixed(1)}°',
                    ),
                    _MetricChip(
                      'Corrente EPAS',
                      '${(l['steering_motor_current'] ?? 0).toStringAsFixed(1)} A',
                    ),
                    if (l.containsKey('odometer_km'))
                      _MetricChip(
                        'Odômetro',
                        '${l['odometer_km']!.toStringAsFixed(0)} km',
                      ),
                  ];
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final chip in fordChips)
                        SizedBox(width: itemW, child: chip),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEventsConsoleCard(BuildContext context, TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    return UniformSectionCard(
      title:
          'Eventos (${c.events.length}) · Ajustes ELM327 · Console (${c.consoleLogs.length})',
      icon: Icons.terminal,
      accent: tokens.muted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              'Resposta rápida',
              style: TextStyle(
                color: tokens.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            value: c.fastReply,
            onChanged: (v) {
              c.fastReply = v;
              c.saveSettings();
              setState(() {});
            },
          ),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              'Console bruto',
              style: TextStyle(
                color: tokens.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            value: c.rawLog,
            onChanged: (v) {
              c.rawLog = v;
              setState(() {});
            },
          ),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              'Auto-Log ao conectar',
              style: TextStyle(
                color: tokens.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            value: c.autoRecord,
            onChanged: (v) {
              c.autoRecord = v;
              c.saveSettings();
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
          UniformButtonGrid(
            columns: 2,
            children: [
              UniformActionButton(
                label: 'Limpar Eventos',
                icon: Icons.notifications_off_outlined,
                variant: UniformActionVariant.neutral,
                onTap: c.clearEvents,
              ),
              UniformActionButton(
                label: 'Limpar Console',
                icon: Icons.clear_all,
                variant: UniformActionVariant.neutral,
                onTap: c.clearConsoleLogs,
              ),
            ],
          ),
          if (c.events.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _showExpandedLogSheet(
                context,
                title: 'Eventos (${c.events.length})',
                icon: Icons.warning_amber_rounded,
                lines: [
                  for (final ev in c.events.reversed)
                    (
                      '[t=${ev.timeSec.toStringAsFixed(1)}s] ${ev.message}',
                      ev.level == 'alarm'
                          ? MotorsportColors.alarm
                          : (ev.level == 'warn'
                              ? MotorsportColors.warning
                              : tokens.accent),
                    ),
                ],
                onClear: c.clearEvents,
              ),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: tokens.plot,
                  border: Border.all(
                    color: tokens.border,
                    width: tokens.cardBorderWidth,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          'EVENTOS (${c.events.length})',
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        Icon(Icons.open_in_full, size: 13, color: tokens.accent),
                        const SizedBox(width: 4),
                        Text(
                          'Toque para expandir',
                          style: TextStyle(
                            color: tokens.accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (final ev in c.events.reversed.take(6))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '[t=${ev.timeSec.toStringAsFixed(1)}s] ${ev.message}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: ev.level == 'alarm'
                                      ? MotorsportColors.alarm
                                      : (ev.level == 'warn'
                                          ? MotorsportColors.warning
                                          : tokens.accent),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (c.consoleLogs.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _showExpandedLogSheet(
                context,
                title: 'Console ELM327 / ECU (${c.consoleLogs.length})',
                icon: Icons.terminal,
                lines: [
                  for (final line in c.consoleLogs.reversed)
                    (
                      line,
                      line.contains('REJEITADO') || line.contains('!!')
                          ? MotorsportColors.warning
                          : (line.contains('ACEITO') || line.contains('✓')
                              ? MotorsportColors.ok
                              : tokens.text),
                    ),
                ],
                onClear: c.clearConsoleLogs,
              ),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: tokens.plot,
                  border: Border.all(
                    color: tokens.border,
                    width: tokens.cardBorderWidth,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          'CONSOLE (${c.consoleLogs.length})',
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        Icon(Icons.open_in_full, size: 13, color: tokens.accent),
                        const SizedBox(width: 4),
                        Text(
                          'Toque para expandir',
                          style: TextStyle(
                            color: tokens.accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (final line in c.consoleLogs.reversed.take(8))
                            Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                color: tokens.muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showExpandedLogSheet(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<(String text, Color color)> lines,
    required VoidCallback onClear,
  }) {
    final tokens = MotorsportTheme.tokensOf(context);
    final fullText = lines.map((e) => e.$1).join('\n');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.border),
      ),
      builder: (ctx) {
        final maxH = MediaQuery.sizeOf(ctx).height * 0.85;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: tokens.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tokens.text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copiar tudo',
                        icon: Icon(Icons.copy, size: 18, color: tokens.accent),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: fullText));
                          if (!ctx.mounted) return;
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Conteúdo copiado para a área de transferência.',
                              ),
                            ),
                          );
                        },
                      ),
                      TextButton(
                        onPressed: () {
                          onClear();
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Limpar'),
                      ),
                      IconButton(
                        tooltip: 'Fechar',
                        icon: Icon(Icons.close, size: 20, color: tokens.muted),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: tokens.borderSubtle),
                Expanded(
                  child: Container(
                    color: tokens.plot,
                    padding: const EdgeInsets.all(12),
                    child: ListView.separated(
                      itemCount: lines.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 8,
                        color: tokens.borderSubtle,
                      ),
                      itemBuilder: (_, idx) {
                        final item = lines[idx];
                        return SelectableText(
                          item.$1,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                            color: item.$2,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.plot,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: MotorsportTheme.tabularStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: tokens.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(
    this.name,
    this.active, {
    required this.activeLabel,
    required this.idleLabel,
    this.alarmOnActive = false,
  });

  final String name;
  final bool active;
  final String activeLabel;
  final String idleLabel;
  final bool alarmOnActive;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final color = active
        ? (alarmOnActive ? MotorsportColors.alarm : MotorsportColors.ok)
        : tokens.muted;
    final bg = active
        ? (alarmOnActive ? MotorsportColors.alarmBg : const Color(0xFF173E28))
        : tokens.plot;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(
          color: active ? color : tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$name: ${active ? activeLabel : idleLabel}',
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
