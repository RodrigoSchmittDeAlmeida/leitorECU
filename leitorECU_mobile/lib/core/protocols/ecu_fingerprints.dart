/// Decodificador Universal de Identificação de ECU, VIN e Part Number (Fingerprinting).
library;

import '../models/vehicle_profile.dart';

const Map<String, String> wmiDatabase = {
  '9BW': 'Volkswagen do Brasil',
  '9BF': 'Ford Brasil',
  '9BG': 'General Motors do Brasil (Chevrolet)',
  '9BD': 'Fiat Automóveis Brasil',
  '9BR': 'Toyota do Brasil',
  '93H': 'Honda Automóveis do Brasil',
  '93Y': 'Renault do Brasil',
  '935': 'Citroën do Brasil',
  '936': 'Peugeot do Brasil',
  '9BH': 'Hyundai Motor Brasil',
  '9BM': 'Mercedes-Benz Brasil',
  '9BS': 'Scania Brasil',
  '9BV': 'Volvo do Brasil',
  'WVW': 'Volkswagen (Alemanha)',
  'WAU': 'Audi (Alemanha)',
  'WBA': 'BMW (Alemanha)',
  'WDB': 'Mercedes-Benz (Alemanha)',
  'WP0': 'Porsche (Alemanha)',
  '1FA': 'Ford Motor Company (EUA)',
  '1FD': 'Ford Motor Company (EUA)',
  '1FM': 'Ford Motor Company (EUA)',
  '1GC': 'Chevrolet / General Motors (EUA)',
  '1G1': 'Chevrolet (EUA)',
  '2G1': 'Chevrolet (Canadá)',
  '3VW': 'Volkswagen de México',
  '8AW': 'Volkswagen Argentina',
  '8AF': 'Ford Argentina',
  '8AG': 'General Motors Argentina',
  '8AD': 'Fiat Argentina',
  '8AP': 'Peugeot Argentina',
};

const List<(String pattern, String name)> partNumberDatabase = [
  ('032906032AJ', 'VW Gol/Voyage G5 1.6 Flex — Bosch ME7.5.30'),
  ('032906032', 'VW EA111 1.6 Flex — Bosch ME7.5.30'),
  ('030906034', 'VW EA111 1.0 Flex — Bosch ME7.5.20 / ME7.5.30'),
  ('030906032', 'VW EA111 1.0 Gasolina — Bosch ME7.5.10'),
  ('036906034', 'VW EA111 1.4/1.6 — Bosch ME7.5.10'),
  ('06A906032', 'VW EA113 1.8T 20V / 2.0 — Bosch ME7.5'),
  ('237906021', 'VW Kombi 1.6 Ar Injetada — Bosch Motronic MP9.0'),
  ('026906021', 'VW Gol/Parati AP 1.6/1.8 — Bosch Motronic MP9.0'),
  ('027906021', 'VW Santana/Quantum AP 2.0 — Bosch Motronic MP9.0'),
  ('048906021', 'VW Polo Classic 1.8 — Bosch Motronic MP9.0'),
  ('IAW 4GV', 'VW EA111 1.0/1.6 Flex — Magneti Marelli IAW 4GV'),
  ('4GV', 'VW/Fiat Magneti Marelli IAW 4GV'),
  ('IAW 4AVP', 'VW AP 1.6/1.8 Total Flex — Magneti Marelli IAW 4AVP'),
  ('4AVP', 'VW AP Total Flex — Magneti Marelli 4AVP'),
  ('IAW 4BV', 'VW Fox/Polo 1.0/1.6 — Magneti Marelli 4BV'),
  ('IAW 1AVP', 'VW Gol/Parati AP Mi — Magneti Marelli 1AVP'),
  ('1AVP', 'VW AP Mi — Magneti Marelli 1AVP'),
  ('IAW 1AVB', 'VW Gol AP Mi — Magneti Marelli 1AVB'),
  ('EMS2211', 'Ford Ka/Fiesta 1.5 Sigma 16V Flex — Continental EMS2211'),
  ('EMS2204', 'Ford Focus/EcoSport 1.6/2.0 Sigma Flex — Continental EMS2204'),
  ('EMS2212', 'Ford Ka 1.0 Ti-VCT 3 Cilindros — Continental EMS2212'),
  ('FOMOCO', 'Ford Motor Company (PCM UDS)'),
  ('06K907425', 'VW/Audi EA888 Gen3 2.0 TSI — Continental Simos 18 (Turbo)'),
  ('06J906026', 'VW Jetta/Passat/Tiguan 2.0 TSI — Bosch MED17.5 (Turbo)'),
  ('5G0906259', 'VW/Audi EA888 TSI — Bosch MED17.5 (Turbo)'),
  ('03F906070', 'VW 1.2/1.4 TSI — Continental Simos 10/12 (Turbo)'),
  ('04E906027', 'VW Up!/Polo/Golf 1.0 TSI EA211 — Bosch ME17.5.24 (Turbo)'),
  ('04E906023', 'VW EA211 1.4 TSI — Bosch MED17.5.25 / ME17.5.20 (Turbo)'),
  ('SIMOS18', 'VW/Audi EA888 Gen3 2.0 TSI — Simos 18 (Turbo)'),
  ('SIMOS 18', 'VW/Audi EA888 Gen3 2.0 TSI — Simos 18 (Turbo)'),
  ('SIMOS12', 'VW EA211 1.0/1.4 TSI — Simos 12 (Turbo)'),
  ('SIMOS 12', 'VW EA211 1.0/1.4 TSI — Simos 12 (Turbo)'),
  ('MED17', 'Bosch Motronic MED17 Direct Injection (Turbo)'),
  ('ME17.5.24', 'VW 1.0 TSI Total Flex EA211 — Bosch ME17.5.24 (Turbo)'),
  ('ME17.5.20', 'VW 1.4 TSI EA211 — Bosch ME17.5.20 (Turbo)'),
  ('EMS24', 'Ford 1.0/1.5/2.0 EcoBoost — Continental EMS24xx (Turbo)'),
  ('EMS25', 'Ford 1.5/2.0 EcoBoost — Continental EMS25xx (Turbo)'),
  ('ECOBOOST', 'Ford EcoBoost Direct Injection (Turbo)'),
  ('MED17.0', 'Ford Focus/Fusion 2.0 EcoBoost — Bosch MED17 (Turbo)'),
  ('MG1CS032', 'Fiat/Jeep GSE Turbo T270 1.3 / T200 1.0 — Bosch MG1CS032 (Turbo)'),
  ('10GF', 'Fiat/Jeep GSE Turbo T200/T270 — Magneti Marelli 10GF (Turbo)'),
  ('T-JET', 'Fiat 1.4 16V T-Jet — Bosch ME7.9.10 (Turbo)'),
  ('ME7.9.10', 'Fiat Punto/Bravo/Linea 1.4 16V T-Jet — Bosch ME7.9.10 (Turbo)'),
  ('ME17.3.0', 'Fiat 1.4 MultiAir / T-Jet — Bosch ME17.3.0 (Turbo)'),
  ('DELCO E98', 'GM 2.8 CTDI Turbo Diesel — Delco E98 (Turbo)'),
  ('DELCO E84', 'GM Onix/Tracker 1.0/1.2 Turbo Flex — Delco E84 (Turbo)'),
  ('E84', 'GM Onix/Tracker 1.0/1.2 Turbo Flex — Delco E84 (Turbo)'),
  ('E98', 'GM 2.8 CTDI Turbo Diesel — Delco E98 (Turbo)'),
  ('CSS PRIME', 'GM Onix/Tracker 1.0/1.2 Turbo Flex — CSS Prime (Turbo)'),
];

const List<String> _turboKeywords = [
  'TURBO',
  'TSI',
  'TFSI',
  'T-JET',
  'TJET',
  'ECOBOOST',
  'MED17',
  'SIMOS 18',
  'SIMOS18',
  'SIMOS 12',
  'SIMOS12',
  'ME17.5.24',
  'ME17.5.20',
  'MG1CS032',
  '10GF',
  'ME7.9.10',
  'ME17.3.0',
  'E84',
  'E98',
  'EMS24',
  'EMS25',
  '06K907425',
  '06J906026',
  '5G0906259',
  '04E906027',
  '04E906023',
  'CSS PRIME',
];

String? decodeWmi(String vin) {
  if (vin.length < 3) return null;
  return wmiDatabase[vin.substring(0, 3).toUpperCase()];
}

String? decodeEcuPartNumber(String rawId) {
  if (rawId.isEmpty) return null;
  final cleaned = rawId
      .toUpperCase()
      .replaceAll(' ', '')
      .replaceAll('-', '')
      .replaceAll('.', '');
  for (final (pattern, name) in partNumberDatabase) {
    final patClean = pattern
        .toUpperCase()
        .replaceAll(' ', '')
        .replaceAll('-', '')
        .replaceAll('.', '');
    if (cleaned.contains(patClean)) {
      return name;
    }
  }
  return null;
}

EcuMetadata identifyEcu({
  String rawId = '',
  String vin = '',
  String protocolName = '',
  List<String> canModulesFound = const [],
}) {
  final manufacturer = decodeWmi(vin);
  final partMatch = decodeEcuPartNumber(rawId);

  final rawUpper = rawId.toUpperCase();
  final isMp90 = rawId.contains('237906021') ||
      rawUpper.contains('MP9.0') ||
      protocolName.contains('KW1281');
  final isMe75 = rawUpper.contains('ME7.5') ||
      rawId.contains('032906032') ||
      rawId.contains('030906032');
  final isFordCan = rawUpper.contains('EMS22') ||
      rawUpper.contains('FOMOCO') ||
      canModulesFound.isNotEmpty;

  final String displayTitle;
  if (partMatch != null) {
    displayTitle = partMatch;
  } else if (manufacturer != null && rawId.trim().isNotEmpty) {
    displayTitle = '$manufacturer — ${rawId.trim()}';
  } else if (manufacturer != null) {
    displayTitle = '$manufacturer (${protocolName.isNotEmpty ? protocolName : "OBD-II"})';
  } else if (rawId.trim().isNotEmpty) {
    displayTitle = 'ECU ${rawId.trim()} (${protocolName.isNotEmpty ? protocolName : "OBD-II"})';
  } else {
    displayTitle = 'ECU Universal (${protocolName.isNotEmpty ? protocolName : "OBD-II"})';
  }

  final titleUpper = displayTitle.toUpperCase();
  final isTurbo = _turboKeywords.any(
    (k) => rawUpper.contains(k) || titleUpper.contains(k),
  );

  final String ecuFamily;
  final String engine;
  if (isMp90) {
    ecuFamily = 'Bosch Motronic MP9.0';
    engine = 'VW Boxer 1.6 Ar / AP 1.6-1.8 Mi';
  } else if (isMe75) {
    ecuFamily = 'Bosch Motronic ME7.5.30';
    engine = 'VW EA111 1.0/1.6 8V Total Flex';
  } else if (rawUpper.contains('SIMOS') || titleUpper.contains('SIMOS')) {
    ecuFamily = 'Continental Simos (VAG Turbo)';
    engine = 'VW/Audi EA888 / EA211 TSI Turbo';
  } else if (rawUpper.contains('MED17') || titleUpper.contains('MED17')) {
    ecuFamily = 'Bosch Motronic MED17 (Turbo GDI)';
    engine = 'VAG / Ford Direct Injection Turbo';
  } else if (rawUpper.contains('ME17.5') || titleUpper.contains('ME17.5')) {
    ecuFamily = 'Bosch Motronic ME17.5 TSI (Turbo)';
    engine = 'VW EA211 1.0/1.4 TSI Total Flex';
  } else if (rawUpper.contains('ECOBOOST') ||
      rawUpper.contains('EMS24') ||
      rawUpper.contains('EMS25')) {
    ecuFamily = 'Continental EMS / EcoBoost';
    engine = 'Ford EcoBoost Turbo GDI';
  } else if (rawUpper.contains('MG1CS032') ||
      rawUpper.contains('10GF') ||
      rawUpper.contains('T-JET') ||
      rawUpper.contains('ME7.9.10')) {
    ecuFamily = 'Bosch MG1 / Marelli 10GF (Fiat GSE Turbo)';
    engine = 'Fiat GSE T200/T270 / T-Jet Turbo';
  } else if (rawUpper.contains('E84') ||
      rawUpper.contains('E98') ||
      rawUpper.contains('CSS PRIME')) {
    ecuFamily = 'Delco (GM CSS Prime Turbo)';
    engine = 'GM Ecotec / CSS Prime 1.0/1.2 Turbo Flex';
  } else if (isFordCan) {
    ecuFamily = 'Continental EMS (Ford HS-CAN)';
    engine = 'Ford Sigma 1.5 DOHC 16V Flex';
  } else if (rawId.contains('4GV')) {
    ecuFamily = 'Magneti Marelli IAW 4GV';
    engine = 'VW EA111 1.0/1.6 8V Total Flex';
  } else {
    ecuFamily = 'OBD-II Universal';
    engine = 'Genérico Universal';
  }

  return EcuMetadata(
    rawId: rawId.trim(),
    vin: vin.trim(),
    manufacturer: manufacturer ?? 'Fabricante não identificado',
    ecuName: displayTitle,
    busProtocol: protocolName.isNotEmpty ? protocolName : 'OBD-II',
    isTurbo: isTurbo,
    ecuFamily: ecuFamily,
    engine: engine,
    canModules: List<String>.unmodifiable(canModulesFound),
  );
}
