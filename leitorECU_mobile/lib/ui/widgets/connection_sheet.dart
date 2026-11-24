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
    final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;
    if (isTablet) {
      return showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
            child: ConnectionSheet(controller: controller),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MotorsportColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        side: BorderSide(color: MotorsportColors.border),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
          child: ConnectionSheet(controller: controller),
        ),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.cable, color: MotorsportColors.info, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Conexão ELM327 & Veículo',
                  style: TextStyle(
                    color: MotorsportColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: MotorsportColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<TransportKind>(
            segments: const [
              ButtonSegment(
                value: TransportKind.ble,
                label: Text('Bluetooth BLE'),
                icon: Icon(Icons.bluetooth, size: 16),
              ),
              ButtonSegment(
                value: TransportKind.tcpWifi,
                label: Text('Wi-Fi TCP'),
                icon: Icon(Icons.wifi, size: 16),
              ),
              ButtonSegment(
                value: TransportKind.demo,
                label: Text('Demo'),
                icon: Icon(Icons.play_circle_outline, size: 16),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (sel) {
              setState(() => _kind = sel.first);
            },
          ),
          const SizedBox(height: 16),
          if (_kind == TransportKind.ble) _buildBleSection(),
          if (_kind == TransportKind.tcpWifi) _buildWifiSection(),
          if (_kind == TransportKind.demo) _buildDemoSection(),
          const SizedBox(height: 16),
          const Text(
            'PERFIL VEICULAR',
            style: TextStyle(
              color: MotorsportColors.muted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<VehicleProfileId>(
            initialValue: _vehicleProfile,
            isExpanded: true,
            dropdownColor: MotorsportColors.elevated,
            items: const [
              DropdownMenuItem(
                value: VehicleProfileId.auto,
                child: Text('Auto-Detecção Universal (Zero-Menu)', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: VehicleProfileId.vwGol,
                child: Text('VW Gol G5 / Fox (ME7.5.30 KWP2000)', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: VehicleProfileId.fordKa,
                child: Text('Ford Ka+ 1.5 Sigma (HS-CAN 500k)', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: VehicleProfileId.generic,
                child: Text('OBD2 Padrão / Genérico', overflow: TextOverflow.ellipsis),
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
              color: MotorsportColors.surfaceAlt,
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
                    const Expanded(
                      child: Text(
                        'Manter tela acesa durante telemetria',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: MotorsportColors.text,
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF073B29),
                    foregroundColor: const Color(0xFFA9FFD3),
                    side: const BorderSide(color: MotorsportColors.ok),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  label: const Text('Conectar à ECU'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: MotorsportColors.warnBg,
            border: Border.all(color: MotorsportColors.warnBorder),
            borderRadius: BorderRadius.circular(4),
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
            style: const TextStyle(color: MotorsportColors.muted, fontSize: 11.5),
          ),
        ],
        if (_bleDevices.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              color: MotorsportColors.plot,
              border: Border.all(color: MotorsportColors.borderSubtle),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _bleDevices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final d = _bleDevices[i];
                final selected = _bleAddrCtrl.text == d.id;
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedTileColor: MotorsportColors.info.withValues(alpha: 0.12),
                  leading: Icon(
                    Icons.bluetooth_connected,
                    color: selected ? MotorsportColors.info : MotorsportColors.muted,
                    size: 18,
                  ),
                  title: Text(d.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  subtitle: Text('${d.id} · ${d.rssi} dBm', style: const TextStyle(fontSize: 11)),
                  onTap: () {
                    setState(() {
                      _bleAddrCtrl.text = d.id;
                      _bleName = d.name;
                    });
                  },
                );
              },
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

  Widget _buildDemoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'SIMULADOR DE MOTOR (DEMO)',
          style: TextStyle(
            color: MotorsportColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<DemoProfile>(
          initialValue: _demoProfile,
          isExpanded: true,
          dropdownColor: MotorsportColors.elevated,
          items: const [
            DropdownMenuItem(
              value: DemoProfile.golMe75,
              child: Text('Gol G5 ME7.5.30 (1.6 Flex Aspirado)'),
            ),
            DropdownMenuItem(
              value: DemoProfile.kaSigma,
              child: Text('Ford Ka+ Sigma (HS-CAN Dupla Sonda + BCM/ABS)'),
            ),
            DropdownMenuItem(
              value: DemoProfile.turboTsi,
              child: Text('Turbo TSI (EA888 MED17.5 Boost + Wideband)'),
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
