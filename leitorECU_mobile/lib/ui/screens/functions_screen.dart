import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analytics/math_channels.dart';
import '../../core/models/channel_def.dart';
import '../../core/models/vehicle_profile.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

/// Aba Funções: DTCs, I/M Readiness, Freeze Frame, VAG Reset, Ford Módulos, Arrancada & Power Latch.
class FunctionsScreen extends StatefulWidget {
  const FunctionsScreen({
    super.key,
    required this.controller,
  });

  final TelemetryController controller;

  @override
  State<FunctionsScreen> createState() => _FunctionsScreenState();
}

class _FunctionsScreenState extends State<FunctionsScreen> {
  late TextEditingController _massCtrl;
  late TextEditingController _priceCtrl;

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
    super.dispose();
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
          'ATENÇÃO: Isso enviará o comando de Reset de Adaptação (Canal 00 / Basic Setting 000) '
          'para a central Bosch ME7.5.30, zerando os blocos 032 (LTFT) e 103 (Flex).\n\n'
          'Requisitos obrigatórios:\n'
          '• Motor aquecido (> 80 °C)\n'
          '• Ignição LIGADA e motor PARADO\n'
          '• Após confirmar, aguarde e desligue a chave por 60s antes da partida.',
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
        final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;

        final cards = <Widget>[
          _buildDiagnosticsCard(c),
          _buildVagAndPowerCard(c),
          _buildPerformanceCard(c),
          _buildFordModulesCard(c),
          _buildEventsConsoleCard(c),
        ];

        if (isTablet) {
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
                    SizedBox(width: colW, child: cards[0]),
                    SizedBox(width: colW, child: cards[1]),
                    SizedBox(width: colW, child: cards[2]),
                    SizedBox(width: colW, child: cards[3]),
                    SizedBox(width: constraints.maxWidth, child: cards[4]),
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

  Widget _buildDiagnosticsCard(TelemetryController c) {
    final online = c.isConnected;
    return _SectionCard(
      title: 'Diagnóstico, DTCs & Emissões',
      icon: Icons.build_circle_outlined,
      accent: MotorsportColors.alarm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: online ? c.requestReadDtcs : null,
                icon: const Icon(Icons.search, size: 16),
                label: const Text('Ler Falhas'),
              ),
              ElevatedButton.icon(
                onPressed: online ? () => _confirmClearDtcs(c) : null,
                style: ElevatedButton.styleFrom(
                  foregroundColor: MotorsportColors.alarm,
                ),
                icon: const Icon(Icons.delete_sweep, size: 16),
                label: const Text('Limpar DTCs'),
              ),
              OutlinedButton.icon(
                onPressed: online ? c.requestReadiness : null,
                icon: const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('I/M Readiness'),
              ),
              OutlinedButton.icon(
                onPressed: online ? c.requestFreezeFrame : null,
                icon: const Icon(Icons.ac_unit, size: 16),
                label: const Text('Freeze Frame'),
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
                  color: MotorsportColors.plot,
                  border: Border.all(color: MotorsportColors.alarmBorder),
                  borderRadius: BorderRadius.circular(3),
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
                        style: const TextStyle(fontSize: 11.5, color: MotorsportColors.text),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (c.readinessReport != null) ...[
            const SizedBox(height: 10),
            _buildReadinessSummary(c.readinessReport!),
          ],
          if (c.freezeFrameData != null) ...[
            const SizedBox(height: 10),
            _buildFreezeFrameSummary(c.freezeFrameData!),
          ],
        ],
      ),
    );
  }

  Widget _buildReadinessSummary(ReadinessReport rep) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: MotorsportColors.plot,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'I/M Readiness: ${rep.readyCount}/${rep.supportedCount} prontos (DTCs: ${rep.dtcCount})',
            style: const TextStyle(
              color: MotorsportColors.info,
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
                    color: m.completed ? const Color(0xFF173E28) : const Color(0xFF4C3912),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${m.completed ? "✔" : "✖"} ${m.name}',
                    style: TextStyle(
                      color: m.completed ? MotorsportColors.ok : MotorsportColors.warning,
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

  Widget _buildFreezeFrameSummary(FreezeFrameData ff) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: MotorsportColors.plot,
        border: Border.all(color: MotorsportColors.borderSubtle),
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
                      color: MotorsportColors.text,
                    ),
                  );
                }(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVagAndPowerCard(TelemetryController c) {
    final online = c.isConnected;
    final volt = c.latest['obd_pin16_v'] ?? c.latest['battery'] ?? c.latest['ecu_volt'];
    final rpm = c.latest['rpm'] ?? 0.0;
    final batEval = volt != null
        ? MathChannelsEngine.evaluateBatteryHealth(
            volt,
            rpm: rpm,
            minCrankVolt: c.mathEngine.minCrankVolt,
          )
        : null;
    final klinePaused = c.pollDelayMs < 0;

    return _SectionCard(
      title: 'VAG KWP2000 & Monitor Elétrico / Power Latch',
      icon: Icons.bolt,
      accent: MotorsportColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: online ? c.requestForceVagKwp : null,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('Forçar VAG KWP'),
              ),
              OutlinedButton.icon(
                onPressed: online ? c.requestScanAll : null,
                icon: const Icon(Icons.radar, size: 16),
                label: const Text('Varrer Blocos 001..255'),
              ),
              ElevatedButton.icon(
                onPressed: online ? () => _confirmResetAdaptation(c) : null,
                style: ElevatedButton.styleFrom(
                  foregroundColor: MotorsportColors.warning,
                  side: const BorderSide(color: MotorsportColors.warnBorder),
                ),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('Reset Adaptação'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: MotorsportColors.plot,
              border: Border.all(
                color: c.isEcuOff ? MotorsportColors.alarm : MotorsportColors.borderSubtle,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.battery_charging_full, color: MotorsportColors.info, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        volt != null
                            ? 'Tensão Pino 16 / ECU: ${volt.toStringAsFixed(2)} V'
                            : 'Tensão Pino 16 / ECU: -- V',
                        style: MotorsportTheme.tabularStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: MotorsportColors.info,
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: online
                          ? () {
                              c.pollDelayMs = klinePaused ? 0 : -1;
                              c.emitInfo(
                                c.pollDelayMs < 0
                                    ? 'Linha K pausada (Keepalive ativo, sem ruído no som).'
                                    : 'Linha K retomada em taxa máxima.',
                              );
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: klinePaused ? const Color(0xFF493512) : MotorsportColors.elevated,
                        foregroundColor: klinePaused ? MotorsportColors.warning : MotorsportColors.text,
                      ),
                      icon: Icon(klinePaused ? Icons.play_arrow : Icons.volume_off, size: 16),
                      label: Text(klinePaused ? 'Retomar Linha K' : 'Pausar Linha K'),
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
                        : MotorsportColors.muted,
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
                    color: c.isEcuOff ? MotorsportColors.alarm : MotorsportColors.stale,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceCard(TelemetryController c) {
    final rec = c.perfTimer.record;
    final latest = c.latest;

    String fmtSec(double? v) => v == null ? '-- s' : '${v.toStringAsFixed(2)} s';

    return _SectionCard(
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
                  c.lastPerfEvent ?? 'Estado: ${c.perfTimer.state} — Aguardando largada',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MotorsportColors.ok,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  c.perfTimer.reset();
                  c.mathEngine.resetTrip();
                  c.emitInfo('Cronômetro e integradores da viagem zerados.');
                },
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Zerar'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricChip('0–60 km/h', fmtSec(rec.time0to60)),
              _MetricChip('0–100 km/h', fmtSec(rec.time0to100)),
              _MetricChip('80–120 km/h', fmtSec(rec.time80to120)),
              _MetricChip('100–200 km/h', fmtSec(rec.time100to200)),
              _MetricChip('201m (1/8)', fmtSec(rec.time201m)),
              _MetricChip('402m (1/4)', fmtSec(rec.time402m)),
              _MetricChip('100–0 Fren.', fmtSec(rec.braking100to0)),
              _MetricChip('G Máx', '${rec.maxG.toStringAsFixed(2)} G'),
              _MetricChip('V Máx', '${rec.maxSpeed.toStringAsFixed(1)} km/h'),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _massCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Massa (kg)'),
                  onChanged: (v) {
                    final parsed = double.tryParse(v);
                    if (parsed != null && parsed >= 400 && parsed <= 4000) {
                      c.mathEngine.vehicleMassKg = parsed;
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: r'Preço Comb. (R$/L)'),
                  onChanged: (v) {
                    final parsed = double.tryParse(v.replaceAll(',', '.'));
                    if (parsed != null && parsed > 0 && parsed < 50) {
                      c.mathEngine.fuelPriceBrl = parsed;
                    }
                  },
                ),
              ),
            ],
          ),
          if (c.perfTimer.history.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'HISTÓRICO DE PUXADAS',
              style: TextStyle(
                color: MotorsportColors.muted,
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
                    color: MotorsportColors.text,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildFordModulesCard(TelemetryController c) {
    final l = c.latest;
    final hasFord = l.keys.any(
      (k) =>
          k.startsWith('door_') ||
          k.startsWith('wheel_speed_') ||
          k.startsWith('steering_') ||
          k == 'low_beam' ||
          k == 'odometer_km',
    );

    return _SectionCard(
      title: 'Módulos Ford HS-CAN (BCM · ABS 4 Rodas · EPAS · IPC)',
      icon: Icons.directions_car_outlined,
      accent: MotorsportColors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: c.isConnected ? c.requestScanAll : null,
                icon: const Icon(Icons.lan_outlined, size: 16),
                label: const Text('Identificar Módulos'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  c.ecuMetadata.canModules.isNotEmpty
                      ? 'Módulos CAN: ${c.ecuMetadata.canModules.join(" · ")}'
                      : (hasFord ? 'Telemetria multimodular ativa' : 'Aguardando leitura HS-CAN'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: MotorsportColors.muted, fontSize: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!hasFord)
            const Text(
              'Conecte em um Ford HS-CAN (ou Demo Ford Ka+ Sigma) para visualizar portas, faróis, velocidades das 4 rodas e EPAS.',
              style: TextStyle(color: MotorsportColors.stale, fontSize: 12),
            )
          else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StatusBadge('DE', (l['door_fl'] ?? 0) > 0.5, activeLabel: 'ABERTA', idleLabel: 'Fechada', alarmOnActive: true),
                _StatusBadge('DD', (l['door_fr'] ?? 0) > 0.5, activeLabel: 'ABERTA', idleLabel: 'Fechada', alarmOnActive: true),
                _StatusBadge('TE', (l['door_rl'] ?? 0) > 0.5, activeLabel: 'ABERTA', idleLabel: 'Fechada', alarmOnActive: true),
                _StatusBadge('TD', (l['door_rr'] ?? 0) > 0.5, activeLabel: 'ABERTA', idleLabel: 'Fechada', alarmOnActive: true),
                _StatusBadge('Mala', (l['door_trunk'] ?? 0) > 0.5, activeLabel: 'ABERTO', idleLabel: 'Fechado', alarmOnActive: true),
                _StatusBadge('Capô', (l['door_hood'] ?? 0) > 0.5, activeLabel: 'ABERTO', idleLabel: 'Fechado', alarmOnActive: true),
                _StatusBadge('Farol Baixo', (l['low_beam'] ?? 0) > 0.5, activeLabel: 'ON', idleLabel: 'OFF'),
                _StatusBadge('Farol Alto', (l['high_beam'] ?? 0) > 0.5, activeLabel: 'ON', idleLabel: 'OFF'),
                _StatusBadge('Neblina', (l['fog_lights'] ?? 0) > 0.5, activeLabel: 'ON', idleLabel: 'OFF'),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip('Roda DE', '${(l['wheel_speed_fl'] ?? 0).toStringAsFixed(1)} km/h'),
                _MetricChip('Roda DD', '${(l['wheel_speed_fr'] ?? 0).toStringAsFixed(1)} km/h'),
                _MetricChip('Roda TE', '${(l['wheel_speed_rl'] ?? 0).toStringAsFixed(1)} km/h'),
                _MetricChip('Roda TD', '${(l['wheel_speed_rr'] ?? 0).toStringAsFixed(1)} km/h'),
                _MetricChip('Freio', '${(l['brake_pressure'] ?? 0).toStringAsFixed(1)} bar'),
                _MetricChip('Volante EPAS', '${(l['steering_wheel_angle'] ?? 0).toStringAsFixed(1)}°'),
                _MetricChip('Corrente EPAS', '${(l['steering_motor_current'] ?? 0).toStringAsFixed(1)} A'),
                if (l.containsKey('odometer_km'))
                  _MetricChip('Odômetro', '${l['odometer_km']!.toStringAsFixed(0)} km'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEventsConsoleCard(TelemetryController c) {
    return _SectionCard(
      title: 'Eventos (${c.events.length}) · Ajustes ELM327 · Console (${c.consoleLogs.length})',
      icon: Icons.terminal,
      accent: MotorsportColors.muted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: c.fastReply,
                    onChanged: (v) {
                      c.fastReply = v;
                      c.saveSettings();
                      setState(() {});
                    },
                  ),
                  const Text('Resposta rápida', style: TextStyle(fontSize: 12)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: c.rawLog,
                    onChanged: (v) {
                      c.rawLog = v;
                      setState(() {});
                    },
                  ),
                  const Text('Console bruto', style: TextStyle(fontSize: 12)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: c.autoRecord,
                    onChanged: (v) {
                      c.autoRecord = v;
                      c.saveSettings();
                      setState(() {});
                    },
                  ),
                  const Text('Auto-Log ao conectar', style: TextStyle(fontSize: 12)),
                ],
              ),
              OutlinedButton(
                onPressed: c.clearEvents,
                child: const Text('Limpar Eventos'),
              ),
              OutlinedButton(
                onPressed: c.clearConsoleLogs,
                child: const Text('Limpar Console'),
              ),
            ],
          ),
          if (c.events.isNotEmpty) ...[
            const SizedBox(height: 8),
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
                              : MotorsportColors.info),
                    ),
                ],
                onClear: c.clearEvents,
              ),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: MotorsportColors.plot,
                  border: Border.all(color: MotorsportColors.border),
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
                          style: const TextStyle(
                            color: MotorsportColors.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.open_in_full, size: 13, color: MotorsportColors.info),
                        const SizedBox(width: 4),
                        const Text(
                          'Toque para expandir',
                          style: TextStyle(
                            color: MotorsportColors.info,
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
                                          : MotorsportColors.info),
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
                              : MotorsportColors.text),
                    ),
                ],
                onClear: c.clearConsoleLogs,
              ),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: MotorsportColors.plot,
                  border: Border.all(color: MotorsportColors.border),
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
                          style: const TextStyle(
                            color: MotorsportColors.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.open_in_full, size: 13, color: MotorsportColors.info),
                        const SizedBox(width: 4),
                        const Text(
                          'Toque para expandir',
                          style: TextStyle(
                            color: MotorsportColors.info,
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
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                color: MotorsportColors.muted,
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
    final fullText = lines.map((e) => e.$1).join('\n');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: MotorsportColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: MotorsportColors.border),
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
                      Icon(icon, size: 18, color: MotorsportColors.info),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MotorsportColors.text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copiar tudo',
                        icon: const Icon(Icons.copy, size: 18, color: MotorsportColors.info),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: fullText));
                          if (!ctx.mounted) return;
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Conteúdo copiado para a área de transferência.')),
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
                        icon: const Icon(Icons.close, size: 20, color: MotorsportColors.muted),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: MotorsportColors.borderSubtle),
                Expanded(
                  child: Container(
                    color: MotorsportColors.plot,
                    padding: const EdgeInsets.all(12),
                    child: ListView.separated(
                      itemCount: lines.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 8,
                        color: MotorsportColors.borderSubtle,
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.accent,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MotorsportColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: MotorsportColors.plot,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: MotorsportColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: MotorsportTheme.tabularStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: MotorsportColors.text,
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
    final color = active
        ? (alarmOnActive ? MotorsportColors.alarm : MotorsportColors.ok)
        : MotorsportColors.muted;
    final bg = active
        ? (alarmOnActive ? MotorsportColors.alarmBg : const Color(0xFF173E28))
        : MotorsportColors.plot;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: active ? color : MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(3),
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
