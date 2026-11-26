import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel_def.dart';
import '../platform/secure_storage.dart';

/// Paleta de cores de destaque selecionável para o tema Motorsport.
enum AccentPreset {
  cyan('Ciano Motorsport', Color(0xFF00D2FF)),
  emerald('Esmeralda', Color(0xFF00E676)),
  amber('Âmbar Pista', Color(0xFFFFB300)),
  crimson('Rubro Sport', Color(0xFFFF3D71)),
  violet('Violeta', Color(0xFFB86BFF));

  const AccentPreset(this.label, this.primaryColor);

  final String label;
  final Color primaryColor;
}

/// Provedores de IA suportados para análise de telemetria e logs CSV.
enum AiProviderKind {
  gemini(
    'Google Gemini',
    'gemini-2.5-flash',
    'https://generativelanguage.googleapis.com',
  ),
  openai(
    'OpenAI',
    'gpt-4o-mini',
    'https://api.openai.com/v1',
  ),
  customOpenAi(
    'Compatível OpenAI',
    'gpt-4o-mini',
    'https://api.openai.com/v1',
  );

  const AiProviderKind(
    this.label,
    this.defaultModel,
    this.defaultBaseUrl,
  );

  final String label;
  final String defaultModel;
  final String defaultBaseUrl;
}

/// Presets de calibração de motor/veículo para cálculos derivados.
enum EnginePreset {
  gol16Flex(
    'VW Gol 1.6 EA111 Flex',
    displacementL: 1.6,
    massKg: 1050.0,
    injectorCcMin: 275.0,
    deadTimeMs: 0.85,
    fuelPriceBrl: 5.89,
  ),
  gol10Flex(
    'VW Gol 1.0 EA111 Flex',
    displacementL: 1.0,
    massKg: 980.0,
    injectorCcMin: 190.0,
    deadTimeMs: 0.85,
    fuelPriceBrl: 5.89,
  ),
  fordKa15Sigma(
    'Ford Ka+ 1.5 Sigma Flex',
    displacementL: 1.5,
    massKg: 1048.0,
    injectorCcMin: 240.0,
    deadTimeMs: 0.80,
    fuelPriceBrl: 5.89,
  ),
  turbo20Gdi(
    'Turbo / GDI 2.0',
    displacementL: 2.0,
    massKg: 1350.0,
    injectorCcMin: 440.0,
    deadTimeMs: 0.75,
    fuelPriceBrl: 6.29,
  ),
  custom(
    'Personalizado',
    displacementL: 1.6,
    massKg: 1050.0,
    injectorCcMin: 275.0,
    deadTimeMs: 0.85,
    fuelPriceBrl: 5.89,
  );

  const EnginePreset(
    this.label, {
    required this.displacementL,
    required this.massKg,
    required this.injectorCcMin,
    required this.deadTimeMs,
    required this.fuelPriceBrl,
  });

  final String label;
  final double displacementL;
  final double massKg;
  final double injectorCcMin;
  final double deadTimeMs;
  final double fuelPriceBrl;
}

/// Controlador persistente de preferências de aparência, acessibilidade,
/// cards do dashboard, calibração de motor e configuração de provedor de IA.
class AppSettingsController extends ChangeNotifier {
  AppSettingsController({SecureKeyStorage? secureStorage})
      : _secureStorage = secureStorage ?? SecureKeyStorage();

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.35;

  static const String _prefFontScale = 'app_font_scale';
  static const String _prefHighContrast = 'app_high_contrast';
  static const String _prefAccentPreset = 'app_accent_preset';
  static const String _prefDashboardCards = 'app_dashboard_cards';
  static const String _prefAiProvider = 'app_ai_provider';
  static const String _prefAiModel = 'app_ai_model';
  static const String _prefAiCustomBaseUrl = 'app_ai_custom_base_url';
  static const String _prefEnginePreset = 'app_engine_preset';
  static const String _prefEngineDisplacement = 'app_engine_displacement_l';
  static const String _prefVehicleMass = 'app_vehicle_mass_kg';
  static const String _prefInjectorCcMin = 'app_injector_cc_min';
  static const String _prefInjectorDeadTime = 'app_injector_dead_time_ms';
  static const String _prefFuelPrice = 'app_fuel_price_brl';
  static const String _secureAiApiKey = 'ai_api_key';

  final SecureKeyStorage _secureStorage;

  double _fontScale = 1.0;
  bool _highContrast = false;
  AccentPreset _accentPreset = AccentPreset.cyan;
  List<String> _dashboardCardKeys = List<String>.from(cardChannelKeys);
  AiProviderKind _aiProvider = AiProviderKind.gemini;
  String _aiModel = 'gemini-2.5-flash';
  String _aiCustomBaseUrl = 'https://api.openai.com/v1';
  bool _hasApiKey = false;
  EnginePreset _enginePreset = EnginePreset.gol16Flex;
  double _engineDisplacementL = 1.6;
  double _vehicleMassKg = 1050.0;
  double _injectorCcMin = 275.0;
  double _injectorDeadTimeMs = 0.85;
  double _fuelPriceBrl = 5.89;

  double get fontScale => _fontScale;
  bool get highContrast => _highContrast;
  AccentPreset get accentPreset => _accentPreset;
  List<String> get dashboardCardKeys => List<String>.unmodifiable(_dashboardCardKeys);
  AiProviderKind get aiProvider => _aiProvider;
  String get aiModel => _aiModel;
  String get aiCustomBaseUrl => _aiCustomBaseUrl;
  bool get hasApiKey => _hasApiKey;
  EnginePreset get enginePreset => _enginePreset;
  double get engineDisplacementL => _engineDisplacementL;
  double get vehicleMassKg => _vehicleMassKg;
  double get injectorCcMin => _injectorCcMin;
  double get injectorDeadTimeMs => _injectorDeadTimeMs;
  double get fuelPriceBrl => _fuelPriceBrl;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedScale = prefs.getDouble(_prefFontScale);
      if (savedScale != null && savedScale.isFinite) {
        _fontScale = savedScale.clamp(minFontScale, maxFontScale).toDouble();
      }

      _highContrast = prefs.getBool(_prefHighContrast) ?? false;

      _accentPreset = _enumByName(
        AccentPreset.values,
        prefs.getString(_prefAccentPreset),
        AccentPreset.cyan,
      );

      final savedCards = prefs.getStringList(_prefDashboardCards);
      if (savedCards != null) {
        final sanitized = _sanitizeCardKeys(savedCards);
        if (sanitized.isNotEmpty) {
          _dashboardCardKeys = sanitized;
        }
      }

      _aiProvider = _enumByName(
        AiProviderKind.values,
        prefs.getString(_prefAiProvider),
        AiProviderKind.gemini,
      );

      final savedModel = prefs.getString(_prefAiModel)?.trim();
      _aiModel = (savedModel != null && savedModel.isNotEmpty)
          ? savedModel
          : _aiProvider.defaultModel;

      final savedBaseUrl = prefs.getString(_prefAiCustomBaseUrl)?.trim();
      _aiCustomBaseUrl = (savedBaseUrl != null && savedBaseUrl.isNotEmpty)
          ? savedBaseUrl
          : 'https://api.openai.com/v1';

      _enginePreset = _enumByName(
        EnginePreset.values,
        prefs.getString(_prefEnginePreset),
        EnginePreset.gol16Flex,
      );

      final savedDisp = prefs.getDouble(_prefEngineDisplacement);
      _engineDisplacementL = (savedDisp != null && savedDisp.isFinite && savedDisp > 0.0)
          ? savedDisp
          : _enginePreset.displacementL;

      final savedMass = prefs.getDouble(_prefVehicleMass);
      _vehicleMassKg = (savedMass != null && savedMass.isFinite && savedMass > 0.0)
          ? savedMass
          : _enginePreset.massKg;

      final savedInjector = prefs.getDouble(_prefInjectorCcMin);
      _injectorCcMin = (savedInjector != null && savedInjector.isFinite && savedInjector > 0.0)
          ? savedInjector
          : _enginePreset.injectorCcMin;

      final savedDeadTime = prefs.getDouble(_prefInjectorDeadTime);
      _injectorDeadTimeMs = (savedDeadTime != null && savedDeadTime.isFinite && savedDeadTime >= 0.0)
          ? savedDeadTime
          : _enginePreset.deadTimeMs;

      final savedFuelPrice = prefs.getDouble(_prefFuelPrice);
      _fuelPriceBrl = (savedFuelPrice != null && savedFuelPrice.isFinite && savedFuelPrice >= 0.0)
          ? savedFuelPrice
          : _enginePreset.fuelPriceBrl;
    } catch (_) {
      // Fallback seguro caso SharedPreferences não esteja disponível
    }

    try {
      _hasApiKey = await _secureStorage.hasKey(_secureAiApiKey);
    } catch (_) {
      _hasApiKey = false;
    }

    notifyListeners();
  }

  Future<void> setFontScale(double v) async {
    final next = v.isFinite
        ? v.clamp(minFontScale, maxFontScale).toDouble()
        : 1.0;
    if ((next - _fontScale).abs() < 0.0001) return;
    _fontScale = next;
    notifyListeners();
    await _savePref((p) => p.setDouble(_prefFontScale, _fontScale));
  }

  Future<void> setHighContrast(bool v) async {
    if (_highContrast == v) return;
    _highContrast = v;
    notifyListeners();
    await _savePref((p) => p.setBool(_prefHighContrast, _highContrast));
  }

  Future<void> setAccentPreset(AccentPreset p) async {
    if (_accentPreset == p) return;
    _accentPreset = p;
    notifyListeners();
    await _savePref((prefs) => prefs.setString(_prefAccentPreset, p.name));
  }

  Future<void> resetAppearance() async {
    _fontScale = 1.0;
    _highContrast = false;
    _accentPreset = AccentPreset.cyan;
    notifyListeners();
    await _savePref((p) async {
      await p.setDouble(_prefFontScale, _fontScale);
      await p.setBool(_prefHighContrast, _highContrast);
      await p.setString(_prefAccentPreset, _accentPreset.name);
    });
  }

  Future<void> setDashboardCards(List<String> keys) async {
    final sanitized = _sanitizeCardKeys(keys);
    _dashboardCardKeys = sanitized.isNotEmpty
        ? sanitized
        : List<String>.from(cardChannelKeys);
    notifyListeners();
    await _persistCards();
  }

  Future<void> replaceCard(int index, String newKey) async {
    final clean = newKey.trim();
    if (clean.isEmpty) return;
    if (index < 0 || index >= _dashboardCardKeys.length) return;
    _dashboardCardKeys[index] = clean;
    notifyListeners();
    await _persistCards();
  }

  Future<String?> removeCardAt(int index) async {
    if (index < 0 || index >= _dashboardCardKeys.length) return null;
    if (_dashboardCardKeys.length <= 1) return null;
    final removed = _dashboardCardKeys.removeAt(index);
    notifyListeners();
    await _persistCards();
    return removed;
  }

  Future<void> insertCardAt(int index, String key) async {
    final clean = key.trim();
    if (clean.isEmpty) return;
    final targetIndex = index.clamp(0, _dashboardCardKeys.length);
    _dashboardCardKeys.insert(targetIndex, clean);
    notifyListeners();
    await _persistCards();
  }

  Future<void> addCard(String key) async {
    final clean = key.trim();
    if (clean.isEmpty) return;
    if (_dashboardCardKeys.contains(clean)) return;
    _dashboardCardKeys.add(clean);
    notifyListeners();
    await _persistCards();
  }

  Future<void> moveCard(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _dashboardCardKeys.length) return;
    final clampedTarget = newIndex.clamp(0, _dashboardCardKeys.length - 1);
    if (oldIndex == clampedTarget) return;
    final item = _dashboardCardKeys.removeAt(oldIndex);
    _dashboardCardKeys.insert(clampedTarget, item);
    notifyListeners();
    await _persistCards();
  }

  Future<void> resetDashboardCards() async {
    _dashboardCardKeys = List<String>.from(cardChannelKeys);
    notifyListeners();
    await _persistCards();
  }

  Future<void> setAiConfig({
    required AiProviderKind provider,
    required String model,
    String? customBaseUrl,
  }) async {
    _aiProvider = provider;
    final trimmedModel = model.trim();
    _aiModel = trimmedModel.isNotEmpty ? trimmedModel : provider.defaultModel;

    if (customBaseUrl != null) {
      final trimmedUrl = customBaseUrl.trim();
      _aiCustomBaseUrl = trimmedUrl.isNotEmpty
          ? trimmedUrl
          : provider.defaultBaseUrl;
    }

    notifyListeners();
    await _savePref((p) async {
      await p.setString(_prefAiProvider, _aiProvider.name);
      await p.setString(_prefAiModel, _aiModel);
      await p.setString(_prefAiCustomBaseUrl, _aiCustomBaseUrl);
    });
  }

  Future<bool> saveApiKey(String rawKey) async {
    final clean = rawKey.trim();
    if (clean.isEmpty) return false;
    final ok = await _secureStorage.write(_secureAiApiKey, clean);
    if (ok) {
      _hasApiKey = true;
      notifyListeners();
    }
    return ok;
  }

  Future<String?> readApiKey() {
    return _secureStorage.read(_secureAiApiKey);
  }

  Future<void> clearApiKey() async {
    await _secureStorage.delete(_secureAiApiKey);
    _hasApiKey = false;
    notifyListeners();
  }

  Future<void> selectEnginePreset(EnginePreset preset) async {
    _enginePreset = preset;
    if (preset != EnginePreset.custom) {
      _engineDisplacementL = preset.displacementL;
      _vehicleMassKg = preset.massKg;
      _injectorCcMin = preset.injectorCcMin;
      _injectorDeadTimeMs = preset.deadTimeMs;
      _fuelPriceBrl = preset.fuelPriceBrl;
    }
    notifyListeners();
    await _persistEngineCalibration();
  }

  Future<void> setEngineCalibration({
    double? displacementL,
    double? vehicleMassKg,
    double? injectorCcMin,
    double? injectorDeadTimeMs,
    double? fuelPriceBrl,
  }) async {
    if (displacementL != null && displacementL.isFinite && displacementL > 0.0) {
      _engineDisplacementL = displacementL;
    }
    if (vehicleMassKg != null && vehicleMassKg.isFinite && vehicleMassKg > 0.0) {
      _vehicleMassKg = vehicleMassKg;
    }
    if (injectorCcMin != null && injectorCcMin.isFinite && injectorCcMin > 0.0) {
      _injectorCcMin = injectorCcMin;
    }
    if (injectorDeadTimeMs != null &&
        injectorDeadTimeMs.isFinite &&
        injectorDeadTimeMs >= 0.0) {
      _injectorDeadTimeMs = injectorDeadTimeMs;
    }
    if (fuelPriceBrl != null && fuelPriceBrl.isFinite && fuelPriceBrl >= 0.0) {
      _fuelPriceBrl = fuelPriceBrl;
    }

    final matchesCurrentPreset = _enginePreset != EnginePreset.custom &&
        (_engineDisplacementL - _enginePreset.displacementL).abs() < 1e-6 &&
        (_vehicleMassKg - _enginePreset.massKg).abs() < 1e-6 &&
        (_injectorCcMin - _enginePreset.injectorCcMin).abs() < 1e-6 &&
        (_injectorDeadTimeMs - _enginePreset.deadTimeMs).abs() < 1e-6;
    if (!matchesCurrentPreset) {
      _enginePreset = EnginePreset.custom;
    }

    notifyListeners();
    await _persistEngineCalibration();
  }

  Future<void> _persistEngineCalibration() {
    return _savePref((p) async {
      await p.setString(_prefEnginePreset, _enginePreset.name);
      await p.setDouble(_prefEngineDisplacement, _engineDisplacementL);
      await p.setDouble(_prefVehicleMass, _vehicleMassKg);
      await p.setDouble(_prefInjectorCcMin, _injectorCcMin);
      await p.setDouble(_prefInjectorDeadTime, _injectorDeadTimeMs);
      await p.setDouble(_prefFuelPrice, _fuelPriceBrl);
    });
  }

  Future<void> _persistCards() {
    return _savePref((p) => p.setStringList(_prefDashboardCards, _dashboardCardKeys));
  }

  Future<void> _savePref(Future<void> Function(SharedPreferences prefs) fn) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await fn(prefs);
    } catch (_) {
      // Ignora falhas de persistência em ambientes sem plugin
    }
  }

  static List<String> _sanitizeCardKeys(List<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final entry in raw) {
      final clean = entry.trim();
      if (clean.isNotEmpty && seen.add(clean)) {
        out.add(clean);
      }
    }
    return out;
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    String? name,
    T fallback,
  ) {
    if (name == null || name.isEmpty) return fallback;
    for (final item in values) {
      if (item.name == name) return item;
    }
    return fallback;
  }

  @override
  String toString() =>
      'AppSettingsController(fontScale: $_fontScale, highContrast: $_highContrast, '
      'accent: ${_accentPreset.name}, cards: ${_dashboardCardKeys.length}, '
      'enginePreset: ${_enginePreset.name}, dispL: $_engineDisplacementL, '
      'aiProvider: ${_aiProvider.name}, aiModel: $_aiModel, hasApiKey: $_hasApiKey)';
}
