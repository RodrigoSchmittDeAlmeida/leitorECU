import 'package:leitorecu_mobile/core/models/vehicle_profile.dart';

/// Dicionário completo de descrições SAE J2012 / ISO 15031-6 e específicos Ford/VAG em português.
const Map<String, String> dtcDescriptions = {
  // Motor / Injeção (P0xxx genéricos)
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

  // Ar Condicionado (A/C)
  'P0530': 'Sensor de pressão do refrigerante A/C - falha de circuito',
  'P0531': 'Sensor de pressão do A/C - faixa/desempenho',
  'P0532': 'Sensor de pressão do refrigerante A/C - sinal baixo (possível falta de gás)',
  'P0533': 'Sensor de pressão do refrigerante A/C - sinal alto',
  'P0645': 'Relé da embreagem do compressor do ar condicionado - circuito',
  'P0646': 'Relé da embreagem do ar condicionado - sinal baixo / curto ao terra',
  'P0647': 'Relé da embreagem do ar condicionado - sinal alto / curto ao positivo',

  // Ford Específicos (P1xxx)
  'P1000': 'Monitores de prontidão OBD-II incompletos (ciclo de condução não finalizado)',
  'P1100': 'Sensor MAF - intermitente no teste de fluxo',
  'P1120': 'Sensor TPS - fora da faixa no teste de retorno',
  'P1260': 'Tentativa de partida impedida pelo imobilizador antifurto PATS',
  'P1288': 'Sensor de temperatura do cabeçote (CHT) - fora da faixa autoteste',
  'P1289': 'Sensor CHT - entrada alta',
  'P1290': 'Sensor CHT - entrada baixa',
  'P1460': 'Relé de corte do A/C em aceleração plena (WOT) - circuito',
  'P1632': 'Falha no sensor inteligente do alternador / sistema Smart Charge Ford',
  'P1633': 'Tensão da bateria permanentemente baixa na alimentação de memória da ECU (KAM)',
  'P1700': 'Transmissão - sistema de intertravamento da marcha à ré',

  // Rede de Comunicação CAN (U0xxx / U1xxx)
  'U0001': 'Barramento CAN de alta velocidade (HS-CAN) - falha de comunicação',
  'U0002': 'Desempenho do barramento CAN de alta velocidade',
  'U0073': 'Barramento CAN do módulo desligado (CAN Bus-Off)',
  'U0100': 'Perda de comunicação com o Módulo de Controle do Motor (PCM)',
  'U0101': 'Perda de comunicação com o Módulo da Transmissão (TCM)',
  'U0121': 'Perda de comunicação com o Módulo de Freios ABS / ESC',
  'U0129': 'Perda de comunicação com o Sistema de Controle de Freios',
  'U0140': 'Perda de comunicação com o Módulo de Carroceria e Conforto (BCM / GEM)',
  'U0155': 'Perda de comunicação com o Painel de Instrumentos (IPC)',
  'U0164': 'Perda de comunicação com o Módulo de Controle de Climatização / Ar Condicionado',
  'U0401': 'Dados inválidos recebidos do Módulo do Motor (PCM)',
  'U0415': 'Dados inválidos recebidos do Módulo de Freios ABS / ESC',
  'U0420': 'Dados inválidos recebidos da Direção Elétrica Progressiva (PSCM / EPAS)',
  'U0422': 'Dados inválidos recebidos do Módulo de Conforto (BCM)',
  'U0423': 'Dados inválidos recebidos do Painel de Instrumentos (IPC)',
  'U0428': 'Dados inválidos recebidos do Sensor de Ângulo do Volante (SAS)',

  // Chassi / Freios ABS / Direção (C0xxx / C1xxx)
  'C0031': 'Sensor de velocidade da roda dianteira esquerda - circuito',
  'C0032': 'Sensor de velocidade da roda dianteira esquerda - faixa/desempenho',
  'C0034': 'Sensor de velocidade da roda dianteira direita - circuito',
  'C0035': 'Sensor de velocidade da roda dianteira direita - faixa/desempenho',
  'C0037': 'Sensor de velocidade da roda traseira esquerda - circuito',
  'C0038': 'Sensor de velocidade da roda traseira esquerda - faixa/desempenho',
  'C003A': 'Sensor de velocidade da roda traseira direita - circuito',
  'C003B': 'Sensor de velocidade da roda traseira direita - faixa/desempenho',
  'C0040': 'Interruptor do pedal de freio \'A\' - circuito',
  'C0041': 'Interruptor do pedal de freio \'A\' - desempenho',
  'C0051': 'Sensor de posição/ângulo do volante (SAS) - circuito',
  'C0061': 'Sensor de aceleração lateral - circuito',
  'C0062': 'Sensor de aceleração longitudinal - circuito',
  'C0063': 'Sensor de taxa de guinada (Yaw Rate) - circuito',
  'C1000': 'Interruptor do freio de estacionamento (freio de mão)',
  'C1099': 'Motor da Direção Elétrica (EPAS) - circuito/falha mecânica',
  'C109A': 'Módulo da Direção Elétrica (PSCM) - mau funcionamento interno',
  'C1145': 'Sensor de velocidade da roda dianteira direita - falha de entrada',
  'C1155': 'Sensor de velocidade da roda dianteira esquerda - falha de entrada',
  'C1165': 'Sensor de velocidade da roda traseira direita - falha de entrada',
  'C1175': 'Sensor de velocidade da roda traseira esquerda - falha de entrada',

  // Carroceria / Conforto / BCM (B0xxx / B1xxx)
  'B10A2': 'Entrada de impacto do módulo de airbag / status de colisão no BCM',
  'B10EA': 'Interruptor do aquecedor / ventilação do ventilador interno',
  'B1131': 'Módulo do motor do limpador de para-brisa - sem resposta',
  'B1202': 'Sensor de nível de combustível do tanque - circuito aberto',
  'B1A84': 'Dados de configuração do veículo inválidos ou não programados',
  'B1B70': 'Atuador da portinhola de recirculação do ar condicionado - falha de circuito',
  'B1D00': 'Farol baixo esquerdo - circuito aberto ou em curto',
  'B1D01': 'Farol baixo direito - circuito aberto ou em curto',
  'B1D02': 'Farol alto esquerdo - circuito aberto ou em curto',
  'B1D03': 'Farol alto direito - circuito aberto ou em curto',
};

/// Decodifica 4 caracteres hexadecimais SAE J2012 (ex: `0133` -> `P0133`).
String decodeDtc(String code4) {
  final clean = code4.trim().toUpperCase();
  if (clean.length != 4) return clean;
  final b = int.tryParse(clean[0], radix: 16);
  if (b == null) return clean;
  const systems = 'PCBU';
  return '${systems[(b >> 2) & 0x03]}${b & 0x03}${clean.substring(1)}';
}

/// Retorna descrição em português para um código DTC (com suporte a prefixo `[MÓDULO]`).
String describeDtc(String code) {
  final cleanCode = code.contains(']')
      ? code.split(']').last.trim().toUpperCase()
      : code.trim().toUpperCase();

  final exact = dtcDescriptions[cleanCode];
  if (exact != null) return exact;

  if (cleanCode.length >= 2) {
    final prefix = cleanCode.substring(0, 2);
    if (prefix.startsWith('U')) {
      return 'Rede CAN / Barramento: Perda de comunicação ou dados inválidos entre módulos';
    }
    if (prefix.startsWith('C')) {
      return 'Chassi / Freios ABS / Direção Elétrica EPAS: Falha em sensor ou atuador';
    }
    if (prefix.startsWith('B')) {
      return 'Carroceria / BCM / Conforto: Falha em circuito elétrico, iluminação ou travas';
    }
    if (prefix == 'P1' || prefix == 'P2') {
      return 'Trem de Força / Injeção: Falha específica do fabricante';
    }
    if (prefix == 'P0') {
      return 'Trem de Força / Injeção: Falha padronizada de emissões/motor (ISO/SAE)';
    }
  }

  return 'Descrição não cadastrada (consulte o manual)';
}

/// Decodifica códigos de falha do Modo 03 (OBD-II) ou Serviço 18 (VAG KWP2000).
List<DtcItem> parseDtcsFromLines(List<String> dataLines) {
  final cleanLines =
      dataLines.map((l) => l.replaceAll(' ', '').toUpperCase()).toList();
  final joined = cleanLines.join();
  if (joined.startsWith('58') && joined.length >= 4) {
    return parseKwpDtcsHex(joined);
  }
  final seen = <String>{};
  final items = <DtcItem>[];
  for (final s in cleanLines) {
    final idx = s.indexOf('43');
    if (idx == -1 || idx.isOdd) continue;
    final payload = s.substring(idx + 2);
    for (var i = 0; i <= payload.length - 4; i += 4) {
      final c = payload.substring(i, i + 4);
      if (c != '0000') {
        final code = decodeDtc(c);
        if (seen.add(code)) {
          items.add(DtcItem(code, describeDtc(code)));
        }
      }
    }
  }
  return items;
}

/// Decodifica string hexadecimal no formato Modo 03 (`43 ...`).
List<DtcItem> parseDtcsHex(String rawHex) {
  final clean = rawHex.replaceAll(' ', '').toUpperCase();
  final idx = clean.indexOf('43');
  final payload = idx != -1 ? clean.substring(idx + 2) : clean;
  final seen = <String>{};
  final items = <DtcItem>[];
  for (var i = 0; i <= payload.length - 4; i += 4) {
    final c = payload.substring(i, i + 4);
    if (c != '0000') {
      final code = decodeDtc(c);
      if (seen.add(code)) {
        items.add(DtcItem(code, describeDtc(code)));
      }
    }
  }
  return items;
}

/// Decodifica string hexadecimal no formato VAG KWP2000 Serviço 18 (`58 <qtd> <dtc2B><status1B>...`).
List<DtcItem> parseKwpDtcsHex(String rawHex) {
  final clean = rawHex.replaceAll(' ', '').toUpperCase();
  final idx = clean.indexOf('58');
  final payload = idx != -1 ? clean.substring(idx + 2) : clean;
  final seen = <String>{};
  final items = <DtcItem>[];
  if (payload.length >= 2) {
    final nDtcs =
        int.tryParse(payload.substring(0, 2), radix: 16) ??
        ((payload.length - 2) ~/ 6);
    final data = payload.substring(2);
    for (var i = 0; i < nDtcs; i++) {
      final start = i * 6;
      if (start + 4 > data.length) break;
      final chunk = data.substring(start, start + 4);
      if (chunk != '0000') {
        final code = decodeDtc(chunk);
        if (seen.add(code)) {
          items.add(DtcItem(code, describeDtc(code)));
        }
      }
    }
  }
  return items;
}

/// Decodifica PID 0101 byte A: bit 7 = MIL acesa, bits 0..6 = quantidade de DTCs.
({bool milOn, int dtcCount}) parseMil(List<int> data) {
  if (data.isEmpty) return (milOn: false, dtcCount: 0);
  return (milOn: (data[0] & 0x80) != 0, dtcCount: data[0] & 0x7F);
}
