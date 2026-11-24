/// Parser e descritor de códigos de falha (Modo 03 OBD-II e Serviço 18 VAG KWP2000).
library;

import '../models/vehicle_profile.dart';

const Map<String, String> dtcDescriptions = {
  'P0010': 'Atuador do comando de válvulas (VVT) - circuito',
  'P0011': 'Posição do comando de válvulas - avanço excessivo',
  'P0012': 'Posição do comando de válvulas - retardo excessivo',
  'P0100': 'Sensor de fluxo de ar (MAF) - falha de circuito',
  'P0101': 'Sensor MAF - faixa/desempenho',
  'P0102': 'Sensor MAF - sinal baixo',
  'P0103': 'Sensor MAF - sinal alto',
  'P0105': 'Sensor de pressão absoluta do coletor (MAP) - circuito',
  'P0106': 'Sensor MAP - faixa/desempenho',
  'P0107': 'Sensor MAP - sinal baixo',
  'P0108': 'Sensor MAP - sinal alto',
  'P0110': 'Sensor de temperatura do ar de admissão (IAT) - circuito',
  'P0111': 'Sensor IAT - faixa/desempenho',
  'P0112': 'Sensor IAT - sinal baixo',
  'P0113': 'Sensor IAT - sinal alto',
  'P0115': 'Sensor de temperatura do motor (ECT) - circuito',
  'P0116': 'Sensor ECT - faixa/desempenho',
  'P0117': 'Sensor ECT - sinal baixo',
  'P0118': 'Sensor ECT - sinal alto',
  'P0120': 'Sensor de posição da borboleta (TPS) - circuito',
  'P0121': 'Sensor TPS - faixa/desempenho',
  'P0122': 'Sensor TPS - sinal baixo',
  'P0123': 'Sensor TPS - sinal alto',
  'P0128': 'Válvula termostática - temperatura abaixo da faixa de operação',
  'P0130': 'Sonda lambda B1S1 (Pré-Cat) - falha de circuito',
  'P0131': 'Sonda lambda B1S1 - tensão baixa (mistura pobre)',
  'P0132': 'Sonda lambda B1S1 - tensão alta (mistura rica)',
  'P0133': 'Sonda lambda B1S1 - resposta lenta',
  'P0134': 'Sonda lambda B1S1 - sem atividade detectada',
  'P0135': 'Aquecedor da sonda lambda B1S1 - circuito defeituoso',
  'P0136': 'Sonda lambda B1S2 (Pós-Cat) - circuito',
  'P0137': 'Sonda lambda B1S2 - tensão baixa',
  'P0138': 'Sonda lambda B1S2 - tensão alta',
  'P0141': 'Aquecedor da sonda lambda B1S2 - circuito defeituoso',
  'P0170': 'Ajuste de combustível (Trim) - mau funcionamento',
  'P0171': 'Mistura excessivamente pobre (Banco 1)',
  'P0172': 'Mistura excessivamente rica (Banco 1)',
  'P0201': 'Injetor cilindro 1 - falha de circuito',
  'P0202': 'Injetor cilindro 2 - falha de circuito',
  'P0203': 'Injetor cilindro 3 - falha de circuito',
  'P0204': 'Injetor cilindro 4 - falha de circuito',
  'P0234': 'Sobrealimentação do turbo (Overboost)',
  'P0299': 'Pressão do turbo abaixo do especificado (Underboost)',
  'P0300': 'Falha de combustão aleatória / múltiplos cilindros (Misfire)',
  'P0301': 'Falha de combustão detectada - Cilindro 1',
  'P0302': 'Falha de combustão detectada - Cilindro 2',
  'P0303': 'Falha de combustão detectada - Cilindro 3',
  'P0304': 'Falha de combustão detectada - Cilindro 4',
  'P0320': 'Circuito de entrada de rotação do distribuidor / ignição',
  'P0322': 'Sensor de rotação (CKP / G28) - sem sinal',
  'P0325': 'Sensor de detonação (Knock Sensor) - circuito',
  'P0335': 'Sensor de rotação da árvore de manivelas (CKP) - circuito',
  'P0336': 'Sensor CKP - faixa/desempenho',
  'P0340': 'Sensor de fase do comando de válvulas (CMP) - circuito',
  'P0341': 'Sensor CMP - faixa/desempenho',
  'P0420': 'Eficiência do catalisador abaixo do limite (Banco 1)',
  'P0441': 'Sistema EVAP (cânister) - fluxo de purga incorreto',
  'P0442': 'Sistema EVAP - pequeno vazamento detectado',
  'P0443': 'Válvula de purga do cânister (EVAP) - falha de circuito',
  'P0455': 'Sistema EVAP - grande vazamento detectado',
  'P0500': 'Sensor de velocidade do veículo (VSS) - circuito',
  'P0505': 'Sistema de controle de marcha lenta - mau funcionamento',
  'P0506': 'Controle de marcha lenta - RPM inferior ao esperado',
  'P0507': 'Controle de marcha lenta - RPM superior ao esperado',
  'P0560': 'Tensão do sistema elétrico incorreta',
  'P0562': 'Tensão do sistema elétrico baixa',
  'P0563': 'Tensão do sistema elétrico alta',
  'P0601': 'Módulo de controle do motor (ECU) - erro de checksum de memória',
  'P0602': 'Módulo de controle do motor (ECU) - erro de programação',
  'P0606': 'Processador do módulo de controle (ECU) - falha interna',
  'P0638': 'Controle do atuador da borboleta - faixa/desempenho',
  'P0685': 'Relé principal de controle da ECU/PCM - circuito aberto / Power-Latch',
  'P0686': 'Relé principal de controle da ECU/PCM - circuito baixo',
  'P0687': 'Relé principal de controle da ECU/PCM - circuito alto',
  'P0689': 'Linha de monitoramento do relé da ECU - tensão baixa',
  'P0690': 'Linha de monitoramento do relé da ECU - tensão alta',
  'P2101': 'Motor do atuador da borboleta (TAC) - faixa/desempenho',
  'P2135': 'Correlação de tensão entre os sensores 1 e 2 da borboleta (TPS)',
  'P2138': 'Correlação de tensão entre os sensores 1 e 2 do pedal acelerador (APP)',
  'P0530': 'Sensor de pressão do refrigerante A/C - falha de circuito',
  'P0531': 'Sensor de pressão do A/C - faixa/desempenho',
  'P0532': 'Sensor de pressão do refrigerante A/C - sinal baixo',
  'P0533': 'Sensor de pressão do refrigerante A/C - sinal alto',
  'P0645': 'Relé da embreagem do compressor do ar condicionado - circuito',
  'P1000': 'Monitores de prontidão OBD-II incompletos',
  'P1260': 'Tentativa de partida impedida pelo imobilizador PATS',
  'P1288': 'Sensor de temperatura do cabeçote (CHT) - fora da faixa',
  'P1632': 'Falha no sistema Smart Charge Ford',
  'U0001': 'Barramento CAN de alta velocidade (HS-CAN) - falha de comunicação',
  'U0100': 'Perda de comunicação com o Módulo do Motor (PCM)',
  'U0121': 'Perda de comunicação com o Módulo ABS / ESC',
  'U0140': 'Perda de comunicação com o Módulo BCM',
  'U0155': 'Perda de comunicação com o Painel (IPC)',
  'C0031': 'Sensor de velocidade da roda dianteira esquerda - circuito',
  'C0034': 'Sensor de velocidade da roda dianteira direita - circuito',
  'C0040': 'Interruptor do pedal de freio A - circuito',
  'C0051': 'Sensor de ângulo do volante (SAS) - circuito',
  'B10A2': 'Entrada de impacto / status de colisão no BCM',
  'B1D00': 'Farol baixo esquerdo - circuito aberto ou em curto',
};

String decodeDtc(String code4) {
  final b = int.parse(code4[0], radix: 16);
  const systems = 'PCBU';
  return '${systems[b >> 2]}${b & 3}${code4.substring(1).toUpperCase()}';
}

String describeDtc(String code) {
  final cleanCode =
      code.contains(']') ? code.split(']').last.trim() : code.trim();
  final known = dtcDescriptions[cleanCode];
  if (known != null) return known;

  if (cleanCode.length >= 2) {
    final prefix = cleanCode.substring(0, 2).toUpperCase();
    if (prefix.startsWith('U')) {
      return 'Rede CAN / Barramento: Perda de comunicação ou dados inválidos';
    }
    if (prefix.startsWith('C')) {
      return 'Chassi / Freios ABS / Direção EPAS: Falha em sensor ou atuador';
    }
    if (prefix.startsWith('B')) {
      return 'Carroceria / BCM / Conforto: Falha elétrica, iluminação ou travas';
    }
    if (prefix == 'P1' || prefix == 'P2') {
      return 'Trem de Força / Injeção: Falha específica do fabricante';
    }
    if (prefix == 'P0') {
      return 'Trem de Força / Injeção: Falha padronizada de emissões/motor';
    }
  }
  return 'Descrição não cadastrada (consulte o manual)';
}

List<DtcItem> parseDtcsHex(String rawHex) {
  final codes = <DtcItem>[];
  final seen = <String>{};
  final clean = rawHex.replaceAll(' ', '').toUpperCase();
  final idx = clean.indexOf('43');
  final payload = idx != -1 ? clean.substring(idx + 2) : clean;

  for (var i = 0; i + 3 < payload.length; i += 4) {
    final c = payload.substring(i, i + 4);
    if (c != '0000') {
      try {
        final code = decodeDtc(c);
        if (seen.add(code)) {
          codes.add(DtcItem(code, describeDtc(code)));
        }
      } catch (_) {}
    }
  }
  return codes;
}

List<DtcItem> parseKwpDtcsHex(String rawHex) {
  final codes = <DtcItem>[];
  final seen = <String>{};
  final clean = rawHex.replaceAll(' ', '').toUpperCase();
  final idx = clean.indexOf('58');
  final payload = idx != -1 ? clean.substring(idx + 2) : clean;
  if (payload.length < 2) return codes;

  final nDtcs = int.tryParse(payload.substring(0, 2), radix: 16) ??
      ((payload.length - 2) ~/ 6);
  final data = payload.substring(2);
  for (var i = 0; i < nDtcs; i++) {
    final start = i * 6;
    if (start + 4 > data.length) break;
    final chunk = data.substring(start, start + 4);
    if (chunk != '0000') {
      try {
        final code = decodeDtc(chunk);
        if (seen.add(code)) {
          codes.add(DtcItem(code, describeDtc(code)));
        }
      } catch (_) {}
    }
  }
  return codes;
}

({bool milOn, int count}) parseMil(List<int> data) {
  if (data.isEmpty) return (milOn: false, count: 0);
  return (milOn: (data[0] & 0x80) != 0, count: data[0] & 0x7F);
}
