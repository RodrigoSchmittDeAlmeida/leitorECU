import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/vehicle_profile.dart';
import '../../core/platform/background_service.dart';
import '../../core/transports/ble_transport.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

/// Modal de configuração de transporte (BLE, Wi-Fi TCP, Demo) e perfil veicular.
class ConnectionSheet extends StatefulWidget {
  const ConnectionSheet({
    super.key,
    required this.controller,
  });

  final TelemetryController controller;

  static Future<void> show(BuildContext context, TelemetryController controller) {
    final tokens = MotorsportTheme.tokensOf(context);
    final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;
    if (isTablet) {
      return showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
            child: ConnectionSheet(controller: controller),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
      ),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
        child: ConnectionSheet(controller: controller),
      ),
    );
  }

  @override
  State<ConnectionSheet> createState() => _ConnectionSheetState();
}

class _ConnectionSheetState extends State<ConnectionSheet> {
  late TransportKind _kind;
  late DemoProfile _demoProfile;
  late VehicleProfileId _vehicleProfile;
  late TextEditingController _ipCtrl;
  late TextEditingController _portCtrl;
  late TextEditingController _bleAddrCtrl;
  String? _bleName;

  bool _scanning = false;
  List<BleDeviceInfo> _bleDevices = const [];
  String? _scanNote;

  bool _ignoringBatteryOpt = true;
  bool _checkingBatteryOpt = false;
  late bool _keepScreenOn;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _kind = c.transportKind;
    _demoProfile = c.demoProfile;
    _vehicleProfile = c.vehicleProfile;
    _ipCtrl = TextEditingController(text: c.wifiHost);
    _portCtrl = TextEditingController(text: c.wifiPort.toString());
    _bleAddrCtrl = TextEditingController(text: c.bleAddress ?? '');
    _bleName = c.bleDeviceName;
    _keepScreenOn = c.keepScreenOn;
    _refreshBatteryOpt();
  }

  Future<void> _refreshBatteryOpt() async {
    final ignoring =
        await TelemetryBackgroundService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _ignoringBatteryOpt = ignoring;
      _checkingBatteryOpt = false;
    });
  }

  Future<void> _requestBatteryExemption() async {
    setState(() => _checkingBatteryOpt = true);
    await TelemetryBackgroundService.requestIgnoreBatteryOptimizations();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refreshBatteryOpt();
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _bleAddrCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanBle() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanNote = 'Escaneando adaptadores BLE (ex.: IOS-Vlink, Vgate)...';
    });
    final devices = await BleScanner.scan(timeout: const Duration(seconds: 4));
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _bleDevices = devices;
      _scanNote = devices.isEmpty
          ? 'Nenhum dispositivo encontrado. Verifique Bluetooth/Localização e ignição ligada.'
          : '${devices.length} dispositivo(s) encontrado(s).';
    });
  }

  Future<void> _connect() async {
    final port = int.tryParse(_portCtrl.text.trim()) ?? 35000;
    final host = _ipCtrl.text.trim().isEmpty ? '192.168.0.10' : _ipCtrl.text.trim();
    final bleAddr = _bleAddrCtrl.text.trim();

    if (_kind == TransportKind.ble && bleAddr.isEmpty) {
      setState(() {
        _scanNote = 'Selecione ou digite o endereço MAC/UUID do adaptador BLE.';
      });
      return;
    }

    widget.controller.setTransportConfig(
      kind: _kind,
      demo: _demoProfile,
      profile: _vehicleProfile,
      host: host,
      port: port,
      bleAddr: bleAddr.isEmpty ? null : bleAddr,
      bleName: _bleName,
    );

    if (mounted) {
      Navigator.of(context).pop();
    }
    await widget.controller.connect();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.cable, color: tokens.accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Conexão ELM327 & Veículo',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fechar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: tokens.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
        Divider(height: 1, color: tokens.borderSubtle),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<TransportKind>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: TransportKind.ble,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Bluetooth BLE', maxLines: 1),
                        ),
                        icon: Icon(Icons.bluetooth, size: 15),
                      ),
                      ButtonSegment(
                        value: TransportKind.tcpWifi,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Wi-Fi TCP', maxLines: 1),
                        ),
                        icon: Icon(Icons.wifi, size: 15),
                      ),
                      ButtonSegment(
                        value: TransportKind.demo,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Demo', maxLines: 1),
                        ),
                        icon: Icon(Icons.play_circle_outline, size: 15),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (sel) {
                      setState(() => _kind = sel.first);
                    },
                  ),
                ),
                const SizedBox(height: 14),
                if (_kind == TransportKind.ble) _buildBleSection(tokens),
                if (_kind == TransportKind.tcpWifi) _buildWifiSection(),
                if (_kind == TransportKind.demo) _buildDemoSection(tokens),
                const SizedBox(height: 14),
                Text(
                  'PERFIL VEICULAR',
                  style: TextStyle(
                    color: tokens.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<VehicleProfileId>(
                  initialValue: _vehicleProfile,
                  isExpanded: true,
                  dropdownColor: tokens.elevated,
                  items: const [
                    DropdownMenuItem(
                      value: VehicleProfileId.auto,
                      child: Text(
                        'Auto-Detecção Universal (Zero-Menu)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: VehicleProfileId.vwGol,
                      child: Text(
                        'VW Gol G5 / Fox (ME7.5.30 KWP2000)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: VehicleProfileId.fordKa,
                      child: Text(
                        'Ford Ka+ 1.5 Sigma (HS-CAN 500k)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: VehicleProfileId.generic,
                      child: Text(
                        'OBD2 Padrão / Genérico',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _vehicleProfile = v);
                  },
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: tokens.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _ignoringBatteryOpt
                          ? MotorsportColors.ok.withValues(alpha: 0.45)
                          : MotorsportColors.warning.withValues(alpha: 0.65),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _ignoringBatteryOpt
                                ? Icons.verified_user_outlined
                                : Icons.battery_alert_outlined,
                            size: 15,
                            color: _ignoringBatteryOpt
                                ? MotorsportColors.ok
                                : MotorsportColors.warning,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _ignoringBatteryOpt
                                  ? '2º Plano: Irrestrito ✓ (tela desligada ativa)'
                                  : '2º Plano: Otimizado pelo Android',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _ignoringBatteryOpt
                                    ? MotorsportColors.ok
                                    : MotorsportColors.warning,
                              ),
                            ),
                          ),
                          if (!_ignoringBatteryOpt)
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed:
                                  _checkingBatteryOpt ? null : _requestBatteryExemption,
                              child: Text(
                                _checkingBatteryOpt ? '...' : 'Liberar 2º Plano',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Manter tela acesa durante telemetria',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: tokens.text,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 26,
                            child: Switch.adaptive(
                              value: _keepScreenOn,
                              onChanged: (val) {
                                setState(() => _keepScreenOn = val);
                                widget.controller.setKeepScreenOn(val);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Builder(
          builder: (ctx) {
            final mq = MediaQuery.of(ctx);
            final bottomInset = math.max(
              12.0,
              math.max(mq.padding.bottom, mq.viewPadding.bottom),
            );
            return Padding(
              padding: EdgeInsets.only(
                bottom: math.max(mq.viewInsets.bottom, bottomInset),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Divider(height: 1, color: tokens.borderSubtle),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                            ),
                            child: const Text(
                              'Cancelar',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _connect,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              backgroundColor: const Color(0xFF073B29),
                              foregroundColor: const Color(0xFFA9FFD3),
                              side: const BorderSide(color: MotorsportColors.ok),
                            ),
                            icon: const Icon(Icons.power_settings_new, size: 18),
                            label: const Text(
                              'Conectar à ECU',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildBleSection(MotorsportVisualTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: MotorsportColors.warnBg,
            border: Border.all(color: MotorsportColors.warnBorder),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline, color: MotorsportColors.warning, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Requer permissão de Bluetooth e Localização no Android. Vgate iCar Pro aparece como "IOS-Vlink" ou "Android-Vlink".',
                  style: TextStyle(color: MotorsportColors.warning, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _bleAddrCtrl,
                decoration: const InputDecoration(
                  labelText: 'Endereço MAC / ID BLE',
                  hintText: 'Ex: AA:BB:CC:DD:EE:FF',
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _scanning ? null : _scanBle,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 46),
              ),
              icon: _scanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search, size: 18),
              label: Text(_scanning ? 'Buscando...' : 'Escanear'),
            ),
          ],
        ),
        if (_scanNote != null) ...[
          const SizedBox(height: 6),
          Text(
            _scanNote!,
            style: TextStyle(color: tokens.muted, fontSize: 11.5),
          ),
        ],
        if (_bleDevices.isNotEmpty) ...[
          const SizedBox(height: 8),
          Material(
            color: MotorsportColors.plot,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: tokens.borderSubtle),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _bleDevices.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: tokens.borderSubtle),
                itemBuilder: (ctx, i) {
                  final d = _bleDevices[i];
                  final selected = _bleAddrCtrl.text == d.id;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _bleAddrCtrl.text = d.id;
                        _bleName = d.name;
                      });
                    },
                    child: Container(
                      color: selected
                          ? tokens.accent.withValues(alpha: 0.12)
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.bluetooth_connected,
                            color: selected ? tokens.accent : tokens.muted,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: tokens.text,
                                  ),
                                ),
                                Text(
                                  '${d.id} · ${d.rssi} dBm',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: tokens.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check_circle, size: 16, color: tokens.accent),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildWifiSection() {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: _ipCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'IP do Adaptador Wi-Fi',
              hintText: '192.168.0.10',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _portCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Porta TCP',
              hintText: '35000',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDemoSection(MotorsportVisualTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'SIMULADOR DE MOTOR (DEMO)',
          style: TextStyle(
            color: tokens.muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<DemoProfile>(
          initialValue: _demoProfile,
          isExpanded: true,
          dropdownColor: tokens.elevated,
          items: const [
            DropdownMenuItem(
              value: DemoProfile.golMe75,
              child: Text(
                'Gol G5 ME7.5.30 (1.6 Flex Aspirado)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: DemoProfile.kaSigma,
              child: Text(
                'Ford Ka+ Sigma (HS-CAN Dupla Sonda + BCM/ABS)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: DemoProfile.turboTsi,
              child: Text(
                'Turbo TSI (EA888 MED17.5 Boost + Wideband)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _demoProfile = v);
          },
        ),
      ],
    );
  }
}
