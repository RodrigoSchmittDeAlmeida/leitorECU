/// Motor de Auto-Fingerprinting Universal em Cascata (UniversalAutoDiscovery).
library;

import '../elm327/elm327_client.dart';
import '../models/vehicle_profile.dart';
import '../transports/mock_transport.dart';
import 'ecu_fingerprints.dart';
import 'ford_hscan_strategy.dart';
import 'generic_obd_strategy.dart';
import 'vag_kwp_strategy.dart';
import 'vehicle_strategy.dart';

String _hexToAscii(ElmResponse resp) {
  final cleaned = resp.raw
      .replaceAll(' ', '')
      .replaceAll('\r', '')
      .replaceAll('\n', '')
      .trim();
  final buf = StringBuffer();
  for (var i = 0; i + 1 < cleaned.length; i += 2) {
    final val = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
    if (val != null && val >= 32 && val <= 126) {
      buf.writeCharCode(val);
    }
  }
  return buf.toString().trim();
}

class UniversalAutoDiscovery {
  static Future<(VehicleStrategy strategy, EcuMetadata metadata)> discover(
    Elm327Client elm,
    StrategyContext ctx,
  ) async {
    ctx.emitStatus(
      'connecting',
      'Auto-Discovery: Identificando barramento e central...',
    );

    final transport = elm.transport;

    // Modo Demo / MockTransport: ativa diretamente o perfil do simulador preservando isTurbo
    if (transport is MockTransport || transport.name == 'Demo') {
      final DemoProfile profile = transport is MockTransport
          ? transport.engine.profile
          : DemoProfile.golMe75;
      final isTurbo = transport is MockTransport && transport.engine.isTurbo;

      if (profile == DemoProfile.kaSigma) {
        ctx.emitLog(
          'Modo Demo / Simulador ativo (Ford Ka+ 1.5 Sigma HS-CAN): inicializando módulos...',
        );
        final stratFord = FordHsCanStrategy();
        await stratFord.initialize(elm, ctx);
        final meta = identifyEcu(
          rawId: 'EMS2211',
          vin: '9BFZZZ54ZG8123456',
          protocolName: 'Ford HS-CAN 500k (Demo)',
          canModulesFound: const ['BCM', 'ABS', 'IPC', 'PSCM'],
        );
        return (stratFord, meta);
      }

      final rawId = isTurbo
          ? '5G0906259 MED17.5 EA888 TSI'
          : '032906032AJ ME7.5.30';
      ctx.emitLog(
        'Modo Demo / Simulador ativo (${isTurbo ? "Turbo" : "Aspirado"}): inicializando central simulada...',
      );
      final stratVag = VagKwpStrategy();
      if (await stratVag.initialize(elm, ctx)) {
        final meta = identifyEcu(
          rawId: rawId,
          vin: isTurbo ? 'WVWZZZAUZHP123456' : '9BWCA05X9CP000000',
          protocolName: 'VAG KWP2000 (Demo)',
        );
        return (stratVag, meta);
      }
      final stratGen = GenericObdStrategy();
      await stratGen.initialize(elm, ctx);
      final meta = identifyEcu(
        rawId: isTurbo ? rawId : 'SIMULADOR',
        protocolName: 'OBD-II Universal (Demo)',
      );
      return (stratGen, meta);
    }

    // ======================================================================
    // ESTÁGIO 1: Barramento CAN (500k - ATSP6)
    // ======================================================================
    ctx.emitStatus(
      'connecting',
      'Auto-Discovery: Sondando barramento CAN 500 kbps (ATSP6)...',
    );
    ctx.emitLog('>> Auto-Discovery: Testando ISO 15765-4 CAN 11-bit 500k (ATSP6)...');
    try {
      await elm.command('ATSP6', timeout: const Duration(milliseconds: 600));
      await elm.command('ATCRA 7E8', timeout: const Duration(milliseconds: 400));
      final rCan = await elm.command(
        '0100',
        timeout: const Duration(milliseconds: 1200),
      );
      if (rCan.contains('41 00') || rCan.contains('4100')) {
        ctx.emitLog('<< Resposta CAN 500k recebida no cabeçalho 7E8!');
        final vinResp = await elm.command(
          '0902',
          timeout: const Duration(milliseconds: 1800),
        );
        final vin = (vinResp.contains('49 02') || vinResp.contains('4902'))
            ? _hexToAscii(vinResp)
            : '';

        final udsPn = await elm.command(
          '22F187',
          timeout: const Duration(milliseconds: 1200),
        );
        final pnStr = (udsPn.contains('62 F1 87') || udsPn.contains('62F187'))
            ? _hexToAscii(udsPn)
            : '';

        final canModules = <String>[];

        // BCM Conforto (TX 726, RX 72E)
        await elm.command('ATSH 726', timeout: const Duration(milliseconds: 400));
        await elm.command('ATCRA 72E', timeout: const Duration(milliseconds: 400));
        final rBcm = await elm.command(
          '224001',
          timeout: const Duration(milliseconds: 600),
        );
        if (rBcm.contains('62 40 01') ||
            rBcm.contains('624001') ||
            rBcm.contains('7F 22') ||
            rBcm.contains('7F22')) {
          canModules.add('BCM');
        } else if (!rBcm.raw.contains('NO DATA') && !rBcm.raw.contains('ERROR')) {
          final rBcmAlt = await elm.command(
            '22404C',
            timeout: const Duration(milliseconds: 600),
          );
          if (rBcmAlt.contains('62 40 4C') ||
              rBcmAlt.contains('62404C') ||
              rBcmAlt.contains('7F 22') ||
              rBcmAlt.contains('7F22')) {
            canModules.add('BCM');
          }
        }

        // ABS / ESC (TX 760, RX 768)
        await elm.command('ATSH 760', timeout: const Duration(milliseconds: 400));
        await elm.command('ATCRA 768', timeout: const Duration(milliseconds: 400));
        final rAbs = await elm.command(
          '222B00',
          timeout: const Duration(milliseconds: 600),
        );
        if (rAbs.contains('62 2B 00') ||
            rAbs.contains('622B00') ||
            rAbs.contains('7F 22') ||
            rAbs.contains('7F22')) {
          canModules.add('ABS');
        }

        // IPC Painel (TX 720, RX 728)
        await elm.command('ATSH 720', timeout: const Duration(milliseconds: 400));
        await elm.command('ATCRA 728', timeout: const Duration(milliseconds: 400));
        final rIpc = await elm.command(
          '22DD01',
          timeout: const Duration(milliseconds: 600),
        );
        if (rIpc.contains('62 DD 01') ||
            rIpc.contains('62DD01') ||
            rIpc.contains('7F 22') ||
            rIpc.contains('7F22')) {
          canModules.add('IPC');
        }

        // PSCM Direção Elétrica (TX 730, RX 738)
        await elm.command('ATSH 730', timeout: const Duration(milliseconds: 400));
        await elm.command('ATCRA 738', timeout: const Duration(milliseconds: 400));
        final rPscm = await elm.command(
          '223300',
          timeout: const Duration(milliseconds: 600),
        );
        if (rPscm.contains('62 33 00') ||
            rPscm.contains('623300') ||
            rPscm.contains('7F 22') ||
            rPscm.contains('7F22')) {
          canModules.add('PSCM');
        }

        await elm.command('ATSH 7E0', timeout: const Duration(milliseconds: 400));
        await elm.command('ATCRA', timeout: const Duration(milliseconds: 400));

        final meta = identifyEcu(
          rawId: pnStr.isNotEmpty ? pnStr : 'CAN PCM',
          vin: vin,
          protocolName:
              canModules.isNotEmpty ? 'Ford HS-CAN 500k' : 'CAN 500k',
          canModulesFound: canModules,
        );
        if (canModules.isNotEmpty) {
          ctx.emitLog(
            'Rede multimodular CAN identificada com ${canModules.length} módulos secundários (${canModules.join(", ")})!',
          );
          final strategyFord = FordHsCanStrategy();
          await strategyFord.initialize(elm, ctx);
          return (strategyFord, meta);
        } else {
          ctx.emitLog('Central CAN mono-módulo identificada. Ativando OBD-II rápido.');
          final strategyGen = GenericObdStrategy();
          await strategyGen.initialize(elm, ctx);
          return (strategyGen, meta);
        }
      }
    } catch (e) {
      ctx.emitLog('CAN probe falhou: $e');
    }

    // ======================================================================
    // ESTÁGIO 2: Linha K Fast Init VAG KWP2000 (ATSP5)
    // ======================================================================
    ctx.emitStatus(
      'connecting',
      'Auto-Discovery: Sondando Linha K VAG KWP2000 (Fast Init)...',
    );
    ctx.emitLog('>> Auto-Discovery: Testando VAG KWP2000 Fast Init (ATSP5 + ATSH 81 10 F1)...');
    try {
      await elm.command('ATSP5', timeout: const Duration(milliseconds: 800));
      await elm.command('ATSH 81 10 F1', timeout: const Duration(milliseconds: 500));
      final rKwp = await elm.command('1089', timeout: const Duration(seconds: 2));
      if (rKwp.contains('50') || rKwp.contains('5A') || rKwp.contains('OK')) {
        ctx.emitLog('<< Sessão KWP2000 aberta com sucesso!');
        final rId = await elm.command('1A9B', timeout: const Duration(seconds: 2));
        final rawAscii = (rId.contains('5A 9B') || rId.contains('5A9B'))
            ? _hexToAscii(rId)
            : '';
        final strategyVag = VagKwpStrategy();
        await strategyVag.initialize(elm, ctx);
        final meta = identifyEcu(
          rawId: rawAscii.isNotEmpty ? rawAscii : 'ME7.5.30',
          protocolName: 'VAG KWP2000',
        );
        return (strategyVag, meta);
      }
    } catch (e) {
      ctx.emitLog('KWP2000 fast init probe falhou: $e');
    }

    // ======================================================================
    // ESTÁGIO 3: Linha K 5-Baud Init (ATSP4)
    // ======================================================================
    ctx.emitStatus(
      'connecting',
      'Auto-Discovery: Sondando Linha K 5-Baud (KWP2000 / KW1281)...',
    );
    ctx.emitLog('>> Auto-Discovery: Testando 5-Baud Init (ATSP4 + ATIIA 01)...');
    try {
      await elm.command('ATSP4', timeout: const Duration(milliseconds: 800));
      await elm.command('ATIIA 01', timeout: const Duration(milliseconds: 500));
      final rInit = await elm.command('1089', timeout: const Duration(seconds: 3));
      final rKw = await elm.command('ATKW', timeout: const Duration(milliseconds: 1200));
      if (rKw.contains('01 8A') || rKw.contains('8A')) {
        ctx.emitLog(
          '<< KeyBytes 01 8A detectados (VAG KW1281 / Bosch MP9.0): adaptadores ELM327 BLE/Wi-Fi não suportam byte-echo KW1281 nativo.',
        );
      }
      if (rInit.contains('50') || rInit.contains('5A') || rInit.ok) {
        final rId = await elm.command('1A9B', timeout: const Duration(seconds: 2));
        final rawAscii = (rId.contains('5A 9B') || rId.contains('5A9B'))
            ? _hexToAscii(rId)
            : '';
        final strategyVag = VagKwpStrategy();
        await strategyVag.initialize(elm, ctx);
        final meta = identifyEcu(
          rawId: rawAscii.isNotEmpty ? rawAscii : 'VAG KWP',
          protocolName: 'VAG KWP2000',
        );
        return (strategyVag, meta);
      }
    } catch (e) {
      ctx.emitLog('5-baud probe falhou: $e');
    }

    // ======================================================================
    // ESTÁGIO 4: Fallback Universal OBD-II (ATSP0)
    // ======================================================================
    ctx.emitStatus(
      'connecting',
      'Auto-Discovery: Acionando Fallback Universal OBD-II (ATSP0)...',
    );
    ctx.emitLog('>> Auto-Discovery: Executando busca automática de protocolo OBD-II (ATSP0)...');
    await elm.command('ATSP0', timeout: const Duration(milliseconds: 800));
    await elm.command('0100', timeout: const Duration(milliseconds: 2500));

    final vinResp = await elm.command('0902', timeout: const Duration(seconds: 2));
    final vin = (vinResp.contains('49 02') || vinResp.contains('4902'))
        ? _hexToAscii(vinResp)
        : '';

    final strategyGen = GenericObdStrategy();
    await strategyGen.initialize(elm, ctx);
    final meta = identifyEcu(
      rawId: 'OBD2 Universal',
      vin: vin,
      protocolName: 'OBD-II Universal',
    );
    return (strategyGen, meta);
  }
}
