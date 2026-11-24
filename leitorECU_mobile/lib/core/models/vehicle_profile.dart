/// Modelos de perfil veicular, transporte, ECU, DTC, Readiness e Freeze Frame.
library;

enum VehicleProfileId { auto, vwGol, fordKa, generic }

String profileDisplayName(VehicleProfileId id) => switch (id) {
      VehicleProfileId.auto => 'Auto-Detecção Universal (CAN / KWP2000 / OBD2)',
      VehicleProfileId.vwGol => 'VW Gol G5 1.6 Flex (Bosch ME7.5.30 / KWP2000)',
      VehicleProfileId.fordKa => 'Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN / Conforto BCM)',
      VehicleProfileId.generic => 'OBD2 Padrão / Automático',
    };

enum TransportKind { ble, tcpWifi, demo }

enum DemoProfile { golMe75, kaSigma, turboTsi }

String demoProfileLabel(DemoProfile profile) => switch (profile) {
      DemoProfile.golMe75 => 'VW Gol G5 1.6 Flex (ME7.5.30 Aspirado)',
      DemoProfile.kaSigma => 'Ford Ka+ 1.5 Sigma (HS-CAN Multimodular)',
      DemoProfile.turboTsi => 'VW/Audi EA888 TSI (MED17.5 Turbo GDI)',
    };

class EcuMetadata {
  final String rawId;
  final String vin;
  final String manufacturer;
  final String ecuName;
  final String busProtocol;
  final bool isTurbo;
  final String ecuFamily;
  final String engine;
  final List<String> canModules;

  const EcuMetadata({
    this.rawId = '',
    this.vin = '',
    this.manufacturer = '',
    this.ecuName = 'ECU OBD-II',
    this.busProtocol = 'OBD-II',
    this.isTurbo = false,
    this.ecuFamily = 'OBD-II Universal',
    this.engine = 'Genérico Universal',
    this.canModules = const [],
  });
}

class DtcItem {
  final String code;
  final String description;

  const DtcItem(this.code, this.description);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DtcItem &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          description == other.description;

  @override
  int get hashCode => Object.hash(code, description);

  @override
  String toString() => 'DtcItem($code: $description)';
}

class ReadinessItem {
  final String name;
  final bool supported;
  final bool completed;

  const ReadinessItem({
    required this.name,
    required this.supported,
    required this.completed,
  });
}

class ReadinessReport {
  final bool milOn;
  final bool isCompression;
  final int dtcCount;
  final int readyCount;
  final int supportedCount;
  final List<ReadinessItem> monitors;

  const ReadinessReport({
    required this.milOn,
    required this.isCompression,
    required this.dtcCount,
    required this.readyCount,
    required this.supportedCount,
    required this.monitors,
  });
}

class FreezeFrameData {
  final String dtc;
  final Map<String, double> values;

  const FreezeFrameData({
    required this.dtc,
    required this.values,
  });
}
