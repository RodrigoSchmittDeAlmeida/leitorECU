/// Interfaces base e fábrica de estratégias veiculares (SOLID: OCP, LSP, DIP).
library;

import '../elm327/elm327_client.dart';
import '../models/vehicle_profile.dart';
import 'ford_hscan_strategy.dart';
import 'generic_obd_strategy.dart';
import 'vag_kwp_strategy.dart';

abstract class StrategyContext {
  bool get isRunning;
  bool get readExtras;
  bool get backgroundScanEnabled;

  void emitSample(Map<String, double> values);
  void emitStatus(String state, String message);
  void emitLog(String message);
  void emitInfo(String message);
  void emitChannels(Map<String, (String, String)> channels);
  void emitDtcs(bool milOn, int count, List<DtcItem> dtcs);
  void emitProtocolMode(String modeName, {bool isFallback = false});
  Future<void> reinitBus() async {}
}

abstract class VehicleStrategy {
  String get profileId;
  String get displayName;

  Future<bool> initialize(Elm327Client elm, StrategyContext ctx);

  Future<int> pollCycle(
    Elm327Client elm,
    StrategyContext ctx,
    int cycle, {
    bool decelMode = false,
  });

  Future<void> readDtcs(Elm327Client elm, StrategyContext ctx);
  Future<void> clearDtcs(Elm327Client elm, StrategyContext ctx);

  Future<void> resetAdaptation(Elm327Client elm, StrategyContext ctx) =>
      clearDtcs(elm, ctx);

  Future<void> scanAll(Elm327Client elm, StrategyContext ctx) async {
    ctx.emitLog('Varredura avançada não aplicável a este perfil.');
  }

  Map<String, (String, String)> getChannelsInfo() => const {};
}

VehicleStrategy createVehicleStrategy(VehicleProfileId id) => switch (id) {
      VehicleProfileId.vwGol => VagKwpStrategy(),
      VehicleProfileId.fordKa => FordHsCanStrategy(),
      VehicleProfileId.generic || VehicleProfileId.auto => GenericObdStrategy(),
    };
