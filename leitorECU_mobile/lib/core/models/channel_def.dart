/// Definição dos canais canônicos de telemetria, cards e rótulos dinâmicos.
library;

class ChannelDef {
  final String key;
  final String label;
  final String unit;
  final bool isCard;
  final int decimals;
  final bool signed;

  const ChannelDef(
    this.key,
    this.label,
    this.unit, {
    this.isCard = false,
    this.decimals = 1,
    this.signed = false,
  });

  String formatValue(double v) => signed
      ? '${v >= 0 ? "+" : ""}${v.toStringAsFixed(decimals)}'
      : v.toStringAsFixed(decimals);
}

const List<String> cardChannelKeys = [
  'rpm',
  'map',
  'advance',
  'tps',
  'load',
  'speed',
  'battery',
  'lambda_v',
  'lambda2_v',
  'lambda_trim',
  'stft',
  'ltft',
  'ect',
  'iat',
];

const Map<String, ChannelDef> coreChannels = {
  // Linha 1 de Cards (Ar, Giro, Carga e Elétrica - 7 cards)
  'rpm': ChannelDef('rpm', 'RPM', 'rpm', isCard: true, decimals: 0),
  'map': ChannelDef('map', 'MAP', 'kPa', isCard: true, decimals: 0),
  'advance': ChannelDef('advance', 'Avanço', '°', isCard: true, decimals: 1),
  'tps': ChannelDef('tps', 'Borboleta (TPS)', '%', isCard: true, decimals: 1),
  'load': ChannelDef('load', 'Carga Calculada', '%', isCard: true, decimals: 1),
  'speed': ChannelDef('speed', 'Velocidade', 'km/h', isCard: true, decimals: 0),
  'battery': ChannelDef('battery', 'Bateria', 'V', isCard: true, decimals: 1),

  // Linha 2 de Cards (Sondas 1 e 2, Mistura e Temperaturas - 7 cards)
  'lambda_v': ChannelDef('lambda_v', 'Sonda 1 (Pré)', 'V', isCard: true, decimals: 3),
  'lambda2_v': ChannelDef('lambda2_v', 'Sonda 2 (Pós)', 'V', isCard: true, decimals: 3),
  'lambda_trim': ChannelDef('lambda_trim', 'Correção Sonda', '%', isCard: true, decimals: 1),
  'stft': ChannelDef('stft', 'STFT', '%', isCard: true, decimals: 1),
  'ltft': ChannelDef('ltft', 'LTFT', '%', isCard: true, decimals: 1),
  'ect': ChannelDef('ect', 'Temp. Motor (ECT)', '°C', isCard: true, decimals: 0),
  'iat': ChannelDef('iat', 'Temp. Ar (IAT)', '°C', isCard: true, decimals: 0),

  // Canais adicionais reportados pela ECU e analítica
  'lambda2_trim': ChannelDef('lambda2_trim', 'Correção Sonda 2', '%', decimals: 1),
  'fuel_sys1': ChannelDef('fuel_sys1', 'Status Malha Comb. 1 (0103)', 'cod', decimals: 0),
  'fuel_sys2': ChannelDef('fuel_sys2', 'Status Malha Comb. 2 (0103)', 'cod', decimals: 0),
  'cat_temp': ChannelDef('cat_temp', 'Temp. Catalisador (013C)', '°C', decimals: 0),
  'cht_temp': ChannelDef('cht_temp', 'Temp. Cabeçote (CHT)', '°C', decimals: 0),
  'ecu_volt': ChannelDef('ecu_volt', 'Tensão Interna ECU', 'V', decimals: 2),
  'obd_pin16_v': ChannelDef('obd_pin16_v', 'Tensão Pino 16 OBD (ATRV)', 'V', decimals: 2),
  'baro': ChannelDef('baro', 'Pressão Barométrica (0133)', 'kPa', decimals: 0),
  'fuel_rate': ChannelDef('fuel_rate', 'Consumo Instantâneo (015E)', 'L/h', decimals: 1),
  'fuel_rate_lph': ChannelDef('fuel_rate_lph', 'Consumo Instantâneo', 'L/h', decimals: 2),
  'fuel_econ_kml': ChannelDef('fuel_econ_kml', 'Economia Combustível', 'km/l', decimals: 1),
  'volumetric_eff': ChannelDef('volumetric_eff', 'Eficiência Volumétrica', '%', decimals: 1),
  'mil_on': ChannelDef('mil_on', 'Luz Injeção (0101)', '0/1', decimals: 0),
  'dtc_count': ChannelDef('dtc_count', 'Qtd. DTCs (0101)', 'un', decimals: 0),
  'o2_mask': ChannelDef('o2_mask', 'Máscara Sondas (0113)', 'bit', decimals: 0),
  'obd_std': ChannelDef('obd_std', 'Padrão OBD (011C)', 'id', decimals: 0),
  'dist_mil': ChannelDef('dist_mil', 'Dist. c/ MIL (0121)', 'km', decimals: 0),
  'fuel_type': ChannelDef('fuel_type', 'Tipo Combustível (0151)', 'id', decimals: 0),
  'inj_ms': ChannelDef('inj_ms', 'Tempo de Injeção', 'ms', decimals: 2),
  'flex_ethanol_pct': ChannelDef('flex_ethanol_pct', 'Teor de Etanol Flex', '%', decimals: 1),
  'app_pedal_pct': ChannelDef('app_pedal_pct', 'Pedal Acelerador (APP)', '%', decimals: 1),
  'power_hp': ChannelDef('power_hp', 'Potência Estimada', 'cv', decimals: 1),
  'torque_kgfm': ChannelDef('torque_kgfm', 'Torque Estimado', 'kgfm', decimals: 1),
  'lambda_error_pct': ChannelDef('lambda_error_pct', 'Desvio Mistura Lambda', '%', decimals: 1, signed: true),
  'trip_liters': ChannelDef('trip_liters', 'Combustível Viagem', 'L', decimals: 3),
  'trip_cost_brl': ChannelDef('trip_cost_brl', 'Custo Viagem', 'R\$', decimals: 2),
  'trip_avg_kml': ChannelDef('trip_avg_kml', 'Consumo Médio Viagem', 'km/l', decimals: 1),
  'trip_km': ChannelDef('trip_km', 'Distância Viagem', 'km', decimals: 2),
  'ltft_idle': ChannelDef('ltft_idle', 'LTFT Lenta (032.1)', '%', decimals: 1),
  'battery_charging': ChannelDef('battery_charging', 'Alternador Carregando', '0/1', decimals: 0),

  // Telemetria Turbo / Injeção Direta GDI / Wideband
  'boost_bar': ChannelDef('boost_bar', 'Pressão de Turbo', 'bar', decimals: 2),
  'boost_psi': ChannelDef('boost_psi', 'Pressão de Turbo (PSI)', 'psi', decimals: 1),
  'boost_target_bar': ChannelDef('boost_target_bar', 'Pressão Turbo Alvo', 'bar', decimals: 2),
  'wastegate_pct': ChannelDef('wastegate_pct', 'Wastegate / N75', '%', decimals: 1),
  'fuel_rail_bar': ChannelDef('fuel_rail_bar', 'Pressão Flauta GDI', 'bar', decimals: 1),
  'cac_temp_c': ChannelDef('cac_temp_c', 'Temp. Intercooler (CAC)', '°C', decimals: 0),
  'turbo_inlet_kpa': ChannelDef('turbo_inlet_kpa', 'Pressão Entrada Turbo', 'kPa', decimals: 0),
  'oil_press_bar': ChannelDef('oil_press_bar', 'Pressão do Óleo', 'bar', decimals: 1),
  'lambda_eq': ChannelDef('lambda_eq', 'Fator Lambda (Wideband)', 'λ', decimals: 3),
  'knock_retard_max': ChannelDef('knock_retard_max', 'Retardo Detonação Máx', '°KW', decimals: 1),
};

const Map<String, ChannelDef> extraChannels = {
  'cluster_fuel_liters': ChannelDef('cluster_fuel_liters', 'Tanque (Painel)', 'L', decimals: 1),
  'cluster_fuel_ohms': ChannelDef('cluster_fuel_ohms', 'Sensor Nível (Boia)', 'Ω', decimals: 0),
};

const Map<String, (String, String)> dynamicChannelInfo = {
  'stft_b2': ('STFT Banco 2', '%'),
  'ltft_b2': ('LTFT Banco 2', '%'),
  'fuel_press': ('Pressão Combustível', 'kPa'),
  'maf': ('MAF', 'g/s'),
  'run_time': ('Tempo Motor Ligado', 's'),
  'evap_purge': ('Purga Cânister', '%'),
  'fuel_level': ('Nível Combustível', '%'),
  'warmups': ('Aquecimentos desde Limpeza', 'un'),
  'dist_clr': ('Distância desde Limpeza', 'km'),
  'baro': ('Pressão Barométrica', 'kPa'),
  'cat_temp': ('Temp. Catalisador B1S1', '°C'),
  'cht_temp': ('Temp. Cabeçote (CHT)', '°C'),
  'ecu_volt': ('Tensão Interna ECU', 'V'),
  'obd_pin16_v': ('Tensão Pino 16 OBD (ATRV)', 'V'),
  'abs_load': ('Carga Absoluta', '%'),
  'cmd_lambda': ('Lambda Comandado', 'λ'),
  'rel_tps': ('Borboleta Relativa', '%'),
  'ambient': ('Temp. Ambiente', '°C'),
  'tps_b': ('Borboleta B', '%'),
  'pedal_d': ('Pedal D', '%'),
  'pedal_e': ('Pedal E', '%'),
  'cmd_throttle': ('Atuador Borboleta', '%'),
  'time_mil': ('Tempo c/ MIL', 'min'),
  'time_clr': ('Tempo desde Limpeza', 'min'),
  'ethanol': ('% Etanol', '%'),
  'flex_ethanol_pct': ('Teor de Etanol Flex', '%'),
  'app_pedal_pct': ('Pedal Acelerador (APP)', '%'),
  'oil_temp': ('Temp. Óleo', '°C'),
  'fuel_rate': ('Consumo', 'l/h'),
  'knock_ret_c1': ('Retardo Detonação Cil. 1', '°KW'),
  'knock_ret_c2': ('Retardo Detonação Cil. 2', '°KW'),
  'knock_ret_c3': ('Retardo Detonação Cil. 3', '°KW'),
  'knock_ret_c4': ('Retardo Detonação Cil. 4', '°KW'),
  'knock_v_c1': ('Tensão Sensor Detonação Cil. 1', 'V'),
  'knock_v_c2': ('Tensão Sensor Detonação Cil. 2', 'V'),
  'knock_v_c3': ('Tensão Sensor Detonação Cil. 3', 'V'),
  'knock_v_c4': ('Tensão Sensor Detonação Cil. 4', 'V'),
  'tps_track1': ('Pista 1 Borboleta EPC', '%'),
  'tps_track2': ('Pista 2 Borboleta EPC', '%'),
  'app_track2': ('Pista 2 Pedal Acelerador', '%'),
  'ltft_idle': ('LTFT Lenta (032.1)', '%'),
  'battery_charging': ('Alternador Carregando', '0/1'),
  'boost_bar': ('Pressão de Turbo', 'bar'),
  'boost_psi': ('Pressão de Turbo (PSI)', 'psi'),
  'boost_target_bar': ('Pressão Turbo Alvo', 'bar'),
  'boost_target_abs_kpa': ('Pressão Turbo Alvo Absoluta', 'kPa'),
  'boost_abs_kpa': ('Pressão Turbo Absoluta', 'kPa'),
  'wastegate_pct': ('Wastegate / N75', '%'),
  'fuel_rail_bar': ('Pressão Flauta GDI', 'bar'),
  'cac_temp_c': ('Temp. Intercooler (CAC)', '°C'),
  'turbo_inlet_kpa': ('Pressão Entrada Turbo', 'kPa'),
  'oil_press_bar': ('Pressão do Óleo', 'bar'),
  'lambda_eq': ('Fator Lambda (Wideband)', 'λ'),
  'knock_retard_max': ('Retardo Detonação Máx', '°KW'),
  'inj_pulse_width': ('Tempo de Injeção', 'ms'),
  'accel_g': ('Aceleração Longitudinal', 'G'),
  'trip_fuel_liters': ('Combustível Viagem', 'L'),
  'cluster_fuel_liters': ('Tanque (Painel)', 'L'),
  'cluster_fuel_ohms': ('Sensor Nível (Boia)', 'Ω'),
};

({String label, String unit}) describeChannel(
  String key, [
  Map<String, (String, String)> extra = const {},
]) {
  final core = coreChannels[key];
  if (core != null) {
    return (label: core.label, unit: core.unit);
  }
  final ext = extra[key];
  if (ext != null) {
    return (label: ext.$1, unit: ext.$2);
  }
  final extDef = extraChannels[key];
  if (extDef != null) {
    return (label: extDef.label, unit: extDef.unit);
  }
  final dyn = dynamicChannelInfo[key];
  if (dyn != null) {
    return (label: dyn.$1, unit: dyn.$2);
  }
  return (label: key, unit: '');
}
