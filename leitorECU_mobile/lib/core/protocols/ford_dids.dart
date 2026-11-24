/// Mapeamento de módulos e DIDs UDS Modo 22 Ford HS-CAN (Sigma 1.5 DOHC + EcoBoost).
library;

import 'dart:typed_data';

class FordModule {
  final String key;
  final String name;
  final String txId;
  final String rxId;
  final String desc;

  const FordModule(this.key, this.name, this.txId, this.rxId, this.desc);
}

const Map<String, FordModule> fordModules = {
  'pcm': FordModule('pcm', 'PCM', '7E0', '7E8', 'Módulo do Motor Sigma 1.5 16V Flex DOHC'),
  'bcm': FordModule('bcm', 'BCM', '726', '72E', 'Módulo de Carroceria e Conforto (GEM)'),
  'abs': FordModule('abs', 'ABS/ESC', '760', '768', 'Sistema de Freios ABS, ESC e HLA'),
  'ipc': FordModule('ipc', 'IPC', '720', '728', 'Painel de Instrumentos e Odômetro'),
  'pscm': FordModule('pscm', 'PSCM', '730', '738', 'Direção Elétrica Progressiva (EPAS)'),
  'rcm': FordModule('rcm', 'RCM', '737', '73F', 'Módulo de Airbags e Retenção'),
};

class FordDid {
  final String key;
  final String moduleKey;
  final String did;
  final String label;
  final String unit;
  final Map<String, double> Function(Uint8List data) decode;
  final bool fast;

  const FordDid(
    this.key,
    this.moduleKey,
    this.did,
    this.label,
    this.unit,
    this.decode, {
    this.fast = false,
  });
}

double _roundTo(double v, int decimals) {
  final factor = switch (decimals) {
    1 => 10.0,
    2 => 100.0,
    3 => 1000.0,
    _ => 1.0,
  };
  return (v * factor).roundToDouble() / factor;
}

int _signed16(int raw) => raw > 32767 ? raw - 65536 : raw;

Map<String, double> decBcmDoors(Uint8List d) {
  final b0 = d.isNotEmpty ? d[0] : 0;
  final b1 = d.length > 1 ? d[1] : 0;
  return {
    'door_fl': (b0 & 0x01) != 0 ? 1.0 : 0.0,
    'door_fr': (b0 & 0x02) != 0 ? 1.0 : 0.0,
    'door_rl': (b0 & 0x04) != 0 ? 1.0 : 0.0,
    'door_rr': (b0 & 0x08) != 0 ? 1.0 : 0.0,
    'door_trunk': (b0 & 0x10) != 0 ? 1.0 : 0.0,
    'door_hood': (b0 & 0x20) != 0 ? 1.0 : 0.0,
    'central_lock': (b1 & 0x01) != 0 ? 1.0 : 0.0,
  };
}

Map<String, double> decBcmLighting(Uint8List d) {
  final b0 = d.isNotEmpty ? d[0] : 0;
  final b1 = d.length > 1 ? d[1] : 0;
  return {
    'parking_lights': (b0 & 0x01) != 0 ? 1.0 : 0.0,
    'low_beam': (b0 & 0x02) != 0 ? 1.0 : 0.0,
    'high_beam': (b0 & 0x04) != 0 ? 1.0 : 0.0,
    'fog_lights': (b0 & 0x08) != 0 ? 1.0 : 0.0,
    'turn_left': (b1 & 0x01) != 0 ? 1.0 : 0.0,
    'turn_right': (b1 & 0x02) != 0 ? 1.0 : 0.0,
    'hazard_lights': (b1 & 0x04) != 0 ? 1.0 : 0.0,
  };
}

Map<String, double> decBcmAccessories(Uint8List d) {
  final b0 = d.isNotEmpty ? d[0] : 0;
  final b1 = d.length > 1 ? d[1] : 0;
  return {
    'wiper_status': (b0 & 0x07).toDouble(),
    'rear_defrost': (b0 & 0x08) != 0 ? 1.0 : 0.0,
    'ignition_pos': ((b1 >> 4) & 0x0F).toDouble(),
    'alarm_armed': (b1 & 0x01) != 0 ? 1.0 : 0.0,
  };
}

Map<String, double> decBcmVoltage(Uint8List d) {
  if (d.isEmpty) return const {};
  final val = d.length >= 2 ? ((d[0] << 8) | d[1]) / 100.0 : d[0] * 0.1;
  return {'bcm_battery_v': val, 'battery': val};
}

Map<String, double> decAbsWheels(Uint8List d) {
  if (d.length >= 8) {
    return {
      'wheel_speed_fl': ((d[0] << 8) | d[1]) * 0.01,
      'wheel_speed_fr': ((d[2] << 8) | d[3]) * 0.01,
      'wheel_speed_rl': ((d[4] << 8) | d[5]) * 0.01,
      'wheel_speed_rr': ((d[6] << 8) | d[7]) * 0.01,
    };
  }
  if (d.length >= 4) {
    return {
      'wheel_speed_fl': d[0].toDouble(),
      'wheel_speed_fr': d[1].toDouble(),
      'wheel_speed_rl': d[2].toDouble(),
      'wheel_speed_rr': d[3].toDouble(),
    };
  }
  return const {};
}

Map<String, double> decAbsDynamics(Uint8List d) {
  final res = <String, double>{};
  if (d.length >= 2) {
    res['brake_pressure'] = ((d[0] << 8) | d[1]) * 0.1;
  }
  if (d.length >= 3) {
    res['brake_pedal_sw'] = (d[2] & 0x01) != 0 ? 1.0 : 0.0;
    res['esc_active'] = (d[2] & 0x04) != 0 ? 1.0 : 0.0;
  }
  if (d.length >= 5) {
    res['steering_angle_abs'] = _signed16((d[3] << 8) | d[4]) * 0.1;
  }
  return res;
}

Map<String, double> decPcmCht(Uint8List d) {
  if (d.length >= 2) {
    return {'cht_temp': ((d[0] << 8) | d[1]) * 0.1 - 40.0};
  }
  if (d.length == 1) {
    return {'cht_temp': (d[0] - 40).toDouble()};
  }
  return const {};
}

Map<String, double> decPcmPedal(Uint8List d) =>
    d.isNotEmpty ? {'app_pedal_pct': d[0] * 100.0 / 255.0} : const {};

Map<String, double> decPcmFan(Uint8List d) =>
    d.isNotEmpty ? {'fan_duty_pct': d[0] * 100.0 / 255.0} : const {};

Map<String, double> decPcmInjection(Uint8List d) {
  if (d.length >= 2) {
    final pw = ((d[0] << 8) | d[1]) * 0.001;
    return {'inj_pulse_width': pw, 'inj_ms': pw};
  }
  return const {};
}

Map<String, double> decPcmAc(Uint8List d) {
  final res = <String, double>{};
  if (d.length >= 2) {
    res['ac_pressure_kpa'] = ((d[0] << 8) | d[1]).toDouble();
  }
  if (d.length >= 3) {
    res['ac_clutch'] = (d[2] & 0x01) != 0 ? 1.0 : 0.0;
  }
  return res;
}

Map<String, double> decPcmAcPress(Uint8List d) {
  if (d.length >= 2) {
    final val = ((d[0] << 8) | d[1]).toDouble();
    return {'ac_pressure_kpa': val > 20.0 ? val : val * 350.0};
  }
  if (d.length == 1) {
    return {'ac_pressure_kpa': d[0].toDouble() * 10.0};
  }
  return const {};
}

Map<String, double> decPcmAcClutch(Uint8List d) =>
    d.isNotEmpty ? {'ac_clutch': (d[0] & 0x01) != 0 ? 1.0 : 0.0} : const {};

Map<String, double> decPcmFlex(Uint8List d) {
  if (d.isEmpty) return const {};
  final val = d[0].toDouble();
  return {'flex_ethanol_pct': val, 'ethanol': val};
}

Map<String, double> decPcmCatTemp(Uint8List d) {
  if (d.length >= 2) {
    return {'cat_temp': (((d[0] << 8) | d[1]) / 10.0) - 40.0};
  }
  return const {};
}

Map<String, double> decPcmBaro(Uint8List d) =>
    d.isNotEmpty ? {'baro': d[0].toDouble()} : const {};

Map<String, double> decPcmBoostTarget(Uint8List d) {
  if (d.length >= 2) {
    final val = ((d[0] << 8) | d[1]).toDouble();
    final kpa = val > 400.0 ? val / 10.0 : val;
    if (kpa >= 20.0 && kpa <= 400.0) {
      final relBar = (kpa - 101.3) / 100.0;
      return {'boost_target_bar': _roundTo(relBar < 0 ? 0.0 : relBar, 3)};
    }
  }
  return const {};
}

Map<String, double> decPcmWastegate(Uint8List d) {
  final double wg;
  if (d.length >= 2) {
    final raw = (d[0] << 8) | d[1];
    wg = raw > 255 ? (raw * 100.0 / 65535.0) : raw.toDouble();
  } else if (d.length == 1) {
    wg = d[0] * 100.0 / 255.0;
  } else {
    return const {};
  }
  if (wg >= 0.0 && wg <= 100.0) {
    return {'wastegate_pct': _roundTo(wg, 1)};
  }
  return const {};
}

Map<String, double> decPcmCacTemp(Uint8List d) {
  final double val;
  if (d.length >= 2) {
    val = ((d[0] << 8) | d[1]) * 0.1 - 40.0;
  } else if (d.length == 1) {
    val = (d[0] - 40).toDouble();
  } else {
    return const {};
  }
  if (val >= -40.0 && val <= 200.0) {
    return {'cac_temp_c': _roundTo(val, 1)};
  }
  return const {};
}

Map<String, double> decPcmFuelRail(Uint8List d) {
  if (d.length >= 2) {
    final raw = ((d[0] << 8) | d[1]).toDouble();
    final bar = raw <= 300.0 ? raw : raw / 100.0;
    if (bar >= 0.0 && bar <= 350.0) {
      return {'fuel_rail_bar': _roundTo(bar, 1)};
    }
  }
  return const {};
}

Map<String, double> decPcmTurboInlet(Uint8List d) {
  if (d.length >= 2) {
    final val = ((d[0] << 8) | d[1]).toDouble();
    final kpa = val > 400.0 ? val / 10.0 : val;
    if (kpa >= 10.0 && kpa <= 400.0) {
      return {'turbo_inlet_kpa': _roundTo(kpa, 1)};
    }
  }
  return const {};
}

Map<String, double> decIpcOdometer(Uint8List d) {
  if (d.length >= 3) {
    final km = ((d[0] << 16) | (d[1] << 8) | d[2]).toDouble();
    return {'odometer_km': km};
  }
  return const {};
}

Map<String, double> decIpcDashboard(Uint8List d) {
  final res = <String, double>{};
  if (d.isNotEmpty) {
    res['fuel_level_pct'] = d[0] * 100.0 / 255.0;
  }
  if (d.length >= 2) {
    res['ext_temp'] = (d[1] - 40).toDouble();
  }
  if (d.length >= 3) {
    res['seatbelt_warning'] = (d[2] & 0x01) != 0 ? 1.0 : 0.0;
    res['parking_brake'] = (d[2] & 0x02) != 0 ? 1.0 : 0.0;
  }
  return res;
}

Map<String, double> decPscmSteering(Uint8List d) {
  final res = <String, double>{};
  if (d.length >= 2) {
    res['steering_wheel_angle'] = _signed16((d[0] << 8) | d[1]) * 0.1;
  }
  if (d.length >= 4) {
    res['steering_driver_torque'] = _signed16((d[2] << 8) | d[3]) * 0.01;
  }
  if (d.length >= 5) {
    res['steering_motor_current'] = d[4] * 0.5;
  }
  return res;
}

Map<String, double> decPscmAngle(Uint8List d) {
  if (d.length >= 2) {
    return {'steering_wheel_angle': _signed16((d[0] << 8) | d[1]) * 0.1};
  }
  return const {};
}

Map<String, double> decPscmTorque(Uint8List d) {
  if (d.length >= 2) {
    return {'steering_driver_torque': _signed16((d[0] << 8) | d[1]) * 0.01};
  }
  return const {};
}

final Map<String, FordDid> fordDids = {
  'bcm_doors': FordDid('bcm_doors', 'bcm', '22404C', 'Status Portas & Travas', '', decBcmDoors),
  'bcm_lighting': FordDid('bcm_lighting', 'bcm', '224050', 'Status de Iluminação', '', decBcmLighting),
  'bcm_accessories': FordDid('bcm_accessories', 'bcm', '224060', 'Limpadores & Ignição', '', decBcmAccessories),
  'bcm_voltage': FordDid('bcm_voltage', 'bcm', '224001', 'Tensão Bateria BCM', 'V', decBcmVoltage),
  'abs_wheels': FordDid('abs_wheels', 'abs', '222B00', 'Velocidade 4 Rodas', 'km/h', decAbsWheels, fast: true),
  'abs_dynamics': FordDid('abs_dynamics', 'abs', '222B01', 'Pressão Freio & SAS', 'bar', decAbsDynamics),
  'pcm_cht': FordDid('pcm_cht', 'pcm', '221624', 'Temp. Cabeça Cilindro (CHT)', '°C', decPcmCht),
  'pcm_pedal': FordDid('pcm_pedal', 'pcm', '22032B', 'Pedal Acelerador (APP)', '%', decPcmPedal),
  'pcm_fan': FordDid('pcm_fan', 'pcm', '220332', 'Eletroventilador Radiador', '%', decPcmFan),
  'pcm_injection': FordDid('pcm_injection', 'pcm', '221125', 'Tempo de Injeção', 'ms', decPcmInjection),
  'pcm_ac': FordDid('pcm_ac', 'pcm', '221101', 'Pressão A/C', 'kPa', decPcmAc),
  'pcm_flex': FordDid('pcm_flex', 'pcm', '221608', 'Etanol Flex no Tanque', '%', decPcmFlex),
  'pcm_cat_temp': FordDid('pcm_cat_temp', 'pcm', '221627', 'Temp. Catalisador', '°C', decPcmCatTemp),
  'pcm_baro': FordDid('pcm_baro', 'pcm', '220320', 'Pressão Barométrica', 'kPa', decPcmBaro),
  // EcoBoost Turbo / GDI
  'pcm_boost_target': FordDid('pcm_boost_target', 'pcm', '220462', 'Boost Desejado (EcoBoost)', 'bar', decPcmBoostTarget),
  'pcm_wastegate': FordDid('pcm_wastegate', 'pcm', '220333', 'Wastegate Duty Cycle (EcoBoost)', '%', decPcmWastegate),
  'pcm_cac_temp': FordDid('pcm_cac_temp', 'pcm', '2203A0', 'Temp. Intercooler (EcoBoost)', '°C', decPcmCacTemp),
  'pcm_fuel_rail': FordDid('pcm_fuel_rail', 'pcm', '2203E7', 'Pressão Flauta GDI (EcoBoost)', 'bar', decPcmFuelRail),
  'pcm_turbo_inlet': FordDid('pcm_turbo_inlet', 'pcm', '2204FE', 'Pressão Entrada Turbo/TIP (EcoBoost)', 'kPa', decPcmTurboInlet),
  // IPC & PSCM
  'ipc_odometer': FordDid('ipc_odometer', 'ipc', '22DD01', 'Odômetro Total', 'km', decIpcOdometer),
  'ipc_dashboard': FordDid('ipc_dashboard', 'ipc', '222416', 'Painel (Comb./Temp. Ext.)', '', decIpcDashboard),
  'pscm_steering': FordDid('pscm_steering', 'pscm', '223300', 'Direção Elétrica EPAS', '', decPscmSteering),
};

const Map<String, (String, String)> fordChannelsInfo = {
  'door_fl': ('Porta Diant. Esq. (Motorista)', '0/1'),
  'door_fr': ('Porta Diant. Dir. (Passageiro)', '0/1'),
  'door_rl': ('Porta Tras. Esq.', '0/1'),
  'door_rr': ('Porta Tras. Dir.', '0/1'),
  'door_trunk': ('Porta-Malas (Sedan)', '0/1'),
  'door_hood': ('Capô do Motor', '0/1'),
  'central_lock': ('Travas Elétricas (Trancado)', '0/1'),
  'low_beam': ('Farol Baixo', '0/1'),
  'high_beam': ('Farol Alto', '0/1'),
  'fog_lights': ('Faróis de Neblina', '0/1'),
  'parking_lights': ('Lanternas', '0/1'),
  'turn_left': ('Seta Esquerda', '0/1'),
  'turn_right': ('Seta Direita', '0/1'),
  'hazard_lights': ('Pisca-Alerta', '0/1'),
  'wiper_status': ('Limpador Para-brisa', 'modo'),
  'rear_defrost': ('Desembaçador Traseiro', '0/1'),
  'ignition_pos': ('Posição da Ignição', 'pos'),
  'alarm_armed': ('Alarme Perimétrico', '0/1'),
  'bcm_battery_v': ('Tensão Bateria (BCM)', 'V'),
  'wheel_speed_fl': ('Velocidade Roda Diant. Esq.', 'km/h'),
  'wheel_speed_fr': ('Velocidade Roda Diant. Dir.', 'km/h'),
  'wheel_speed_rl': ('Velocidade Roda Tras. Esq.', 'km/h'),
  'wheel_speed_rr': ('Velocidade Roda Tras. Dir.', 'km/h'),
  'brake_pressure': ('Pressão do Freio', 'bar'),
  'brake_pedal_sw': ('Interruptor Freio', '0/1'),
  'esc_active': ('Intervenção ESC/ABS', '0/1'),
  'steering_angle_abs': ('Ângulo Esterçamento (SAS)', '°'),
  'cht_temp': ('Temp. Cabeça Cilindro (CHT)', '°C'),
  'app_pedal_pct': ('Pedal Acelerador (APP)', '%'),
  'fan_duty_pct': ('Eletroventilador Radiador', '%'),
  'inj_pulse_width': ('Tempo de Injeção', 'ms'),
  'ac_pressure_kpa': ('Pressão Refrigerante A/C', 'kPa'),
  'ac_clutch': ('Embreagem Compressor A/C', '0/1'),
  'flex_ethanol_pct': ('Teor de Etanol Tanque', '%'),
  'cat_temp': ('Temp. Catalisador (UDS)', '°C'),
  'baro': ('Pressão Barométrica (UDS)', 'kPa'),
  'odometer_km': ('Odômetro Total', 'km'),
  'fuel_level_pct': ('Nível de Combustível', '%'),
  'ext_temp': ('Temperatura Externa', '°C'),
  'seatbelt_warning': ('Alerta Cinto Segurança', '0/1'),
  'parking_brake': ('Freio de Mão', '0/1'),
  'steering_wheel_angle': ('Ângulo Volante EPAS', '°'),
  'steering_driver_torque': ('Torque Aplicado Volante', 'Nm'),
  'steering_motor_current': ('Corrente Motor Direção', 'A'),
  'boost_target_bar': ('Pressão Turbo Alvo (EcoBoost)', 'bar'),
  'wastegate_pct': ('Wastegate Atuador (EcoBoost)', '%'),
  'cac_temp_c': ('Temp. Intercooler CAC (EcoBoost)', '°C'),
  'fuel_rail_bar': ('Pressão Flauta GDI (EcoBoost)', 'bar'),
  'turbo_inlet_kpa': ('Pressão Entrada Turbo / TIP', 'kPa'),
};
