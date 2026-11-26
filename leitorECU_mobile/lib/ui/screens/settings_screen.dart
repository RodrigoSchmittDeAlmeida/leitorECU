import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/uniform_action_button.dart';

/// Tela de Configurações: Aparência, Veículo & Motor, Acessibilidade e Inteligência Artificial (LLM).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
  });

  final AppSettingsController settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<(double, String)> _fontQuickPresets = [
    (0.85, '85%'),
    (1.00, '100%'),
    (1.15, '115%'),
    (1.30, '130%'),
  ];

  late final TextEditingController _modelCtrl;
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _dispCtrl;
  late final TextEditingController _massCtrl;
  late final TextEditingController _injCtrl;
  late final TextEditingController _deadCtrl;
  late final TextEditingController _priceCtrl;

  final FocusNode _modelFocus = FocusNode();
  final FocusNode _baseUrlFocus = FocusNode();
  final FocusNode _dispFocus = FocusNode();
  final FocusNode _massFocus = FocusNode();
  final FocusNode _injFocus = FocusNode();
  final FocusNode _deadFocus = FocusNode();
  final FocusNode _priceFocus = FocusNode();

  late AiProviderKind _lastProvider;
  bool _obscureKey = true;
  bool _busyKeyAction = false;

  @override
  void initState() {
    super.initState();
    _lastProvider = widget.settings.aiProvider;
    _modelCtrl = TextEditingController(text: widget.settings.aiModel);
    _baseUrlCtrl = TextEditingController(text: widget.settings.aiCustomBaseUrl);
    _apiKeyCtrl = TextEditingController();
    _dispCtrl = TextEditingController(
      text: _formatDisplacement(widget.settings.engineDisplacementL),
    );
    _massCtrl = TextEditingController(
      text: widget.settings.vehicleMassKg.toStringAsFixed(0),
    );
    _injCtrl = TextEditingController(
      text: widget.settings.injectorCcMin.toStringAsFixed(0),
    );
    _deadCtrl = TextEditingController(
      text: widget.settings.injectorDeadTimeMs.toStringAsFixed(2),
    );
    _priceCtrl = TextEditingController(
      text: widget.settings.fuelPriceBrl.toStringAsFixed(2),
    );
    widget.settings.addListener(_syncControllersFromSettings);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_syncControllersFromSettings);
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _dispCtrl.dispose();
    _massCtrl.dispose();
    _injCtrl.dispose();
    _deadCtrl.dispose();
    _priceCtrl.dispose();
    _modelFocus.dispose();
    _baseUrlFocus.dispose();
    _dispFocus.dispose();
    _massFocus.dispose();
    _injFocus.dispose();
    _deadFocus.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  static String _formatDisplacement(double v) {
    if ((v * 10 - (v * 10).round()).abs() < 0.01) {
      return v.toStringAsFixed(1);
    }
    return v.toStringAsFixed(2);
  }

  void _syncEngineControllers({bool force = false}) {
    final s = widget.settings;
    final dispStr = _formatDisplacement(s.engineDisplacementL);
    if ((force || !_dispFocus.hasFocus) && _dispCtrl.text != dispStr) {
      _dispCtrl.text = dispStr;
    }
    final massStr = s.vehicleMassKg.toStringAsFixed(0);
    if ((force || !_massFocus.hasFocus) && _massCtrl.text != massStr) {
      _massCtrl.text = massStr;
    }
    final injStr = s.injectorCcMin.toStringAsFixed(0);
    if ((force || !_injFocus.hasFocus) && _injCtrl.text != injStr) {
      _injCtrl.text = injStr;
    }
    final deadStr = s.injectorDeadTimeMs.toStringAsFixed(2);
    if ((force || !_deadFocus.hasFocus) && _deadCtrl.text != deadStr) {
      _deadCtrl.text = deadStr;
    }
    final priceStr = s.fuelPriceBrl.toStringAsFixed(2);
    if ((force || !_priceFocus.hasFocus) && _priceCtrl.text != priceStr) {
      _priceCtrl.text = priceStr;
    }
  }

  void _syncControllersFromSettings() {
    if (!mounted) return;
    if (!_modelFocus.hasFocus && _modelCtrl.text != widget.settings.aiModel) {
      _modelCtrl.text = widget.settings.aiModel;
    }
    if (!_baseUrlFocus.hasFocus &&
        _baseUrlCtrl.text != widget.settings.aiCustomBaseUrl) {
      _baseUrlCtrl.text = widget.settings.aiCustomBaseUrl;
    }
    _lastProvider = widget.settings.aiProvider;
    _syncEngineControllers();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onProviderChanged(AiProviderKind? next) async {
    if (next == null) return;
    final currentModel = _modelCtrl.text.trim();
    if (currentModel.isEmpty || currentModel == _lastProvider.defaultModel) {
      _modelCtrl.text = next.defaultModel;
    }
    _lastProvider = next;
    await widget.settings.setAiConfig(
      provider: next,
      model: _modelCtrl.text,
      customBaseUrl:
          next == AiProviderKind.customOpenAi ? _baseUrlCtrl.text : null,
    );
  }

  Future<void> _commitAiTextFields() async {
    final s = widget.settings;
    await s.setAiConfig(
      provider: s.aiProvider,
      model: _modelCtrl.text,
      customBaseUrl:
          s.aiProvider == AiProviderKind.customOpenAi ? _baseUrlCtrl.text : null,
    );
  }

  Future<void> _handleSaveApiKey() async {
    final raw = _apiKeyCtrl.text.trim();
    if (raw.isEmpty) {
      _showSnack('Informe uma chave de API válida antes de salvar.');
      return;
    }
    setState(() => _busyKeyAction = true);
    final ok = await widget.settings.saveApiKey(raw);
    if (!mounted) return;
    setState(() => _busyKeyAction = false);
    if (ok) {
      _apiKeyCtrl.clear();
      _showSnack('Chave salva com criptografia (Keystore).');
    } else {
      _showSnack('Falha ao salvar a chave de API.');
    }
  }

  Future<void> _handleClearApiKey() async {
    setState(() => _busyKeyAction = true);
    await widget.settings.clearApiKey();
    if (!mounted) return;
    _apiKeyCtrl.clear();
    setState(() => _busyKeyAction = false);
    _showSnack('Chave de API removida.');
  }

  Future<void> _applyEngineCalibration() async {
    double? parseNum(String raw) =>
        double.tryParse(raw.trim().replaceAll(',', '.'));

    final disp = parseNum(_dispCtrl.text);
    final mass = parseNum(_massCtrl.text);
    final inj = parseNum(_injCtrl.text);
    final dead = parseNum(_deadCtrl.text);
    final price = parseNum(_priceCtrl.text);

    if (disp == null ||
        disp <= 0.0 ||
        mass == null ||
        mass <= 0.0 ||
        inj == null ||
        inj <= 0.0 ||
        dead == null ||
        dead < 0.0 ||
        price == null ||
        price < 0.0) {
      _showSnack('Verifique os valores numéricos antes de aplicar a calibração.');
      return;
    }

    FocusScope.of(context).unfocus();
    await widget.settings.setEngineCalibration(
      displacementL: disp,
      vehicleMassKg: mass,
      injectorCcMin: inj,
      injectorDeadTimeMs: dead,
      fuelPriceBrl: price,
    );
    _syncEngineControllers(force: true);
    _showSnack('Calibração do motor aplicada.');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;

    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final tokens = MotorsportTheme.tokensOf(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Configurações'),
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader(
                  icon: Icons.palette_outlined,
                  title: 'Aparência & Acessibilidade',
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildAppearanceSection(s, tokens),
                const SizedBox(height: 20),
                _SectionHeader(
                  icon: Icons.directions_car_outlined,
                  title: 'Veículo & Calibração do Motor',
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildVehicleEngineSection(s, tokens),
                const SizedBox(height: 20),
                _SectionHeader(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Inteligência Artificial (LLM)',
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildAiSection(s, tokens),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppearanceSection(
    AppSettingsController s,
    MotorsportVisualTokens tokens,
  ) {
    final scalePct = (s.fontScale * 100).round();

    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Tamanho da Fonte',
                    style: TextStyle(
                      color: tokens.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$scalePct%',
                  style: MotorsportTheme.tabularStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: tokens.accent,
                  ),
                ),
              ],
            ),
            Slider(
              value: s.fontScale,
              min: AppSettingsController.minFontScale,
              max: AppSettingsController.maxFontScale,
              divisions: 10,
              label: '$scalePct%',
              onChanged: (v) => s.setFontScale(v),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _fontQuickPresets.map((preset) {
                final (scale, label) = preset;
                final isSelected = (s.fontScale - scale).abs() < 0.02;
                return ChoiceChip(
                  label: Text(label),
                  selected: isSelected,
                  onSelected: (_) => s.setFontScale(scale),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Material(
              color: tokens.surfaceAlt,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: tokens.borderSubtle,
                  width: tokens.cardBorderWidth,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PRÉ-VISUALIZAÇÃO DE TELEMETRIA',
                      style: TextStyle(
                        color: tokens.muted,
                        fontSize: 10 * s.fontScale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'RPM 3.250 · Sonda 0,84 V · Avanço 18,5°',
                      style: MotorsportTheme.tabularStyle(
                        fontSize: 14 * s.fontScale,
                        fontWeight: FontWeight.w700,
                        color: tokens.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Divider(color: tokens.borderSubtle, height: 1),
            const SizedBox(height: 12),
            Material(
              color: tokens.surfaceAlt,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: tokens.borderSubtle,
                  width: tokens.cardBorderWidth,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => s.setHighContrast(!s.highContrast),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Alto Contraste',
                              style: TextStyle(
                                color: tokens.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Preto absoluto, bordas reforçadas e leitura máxima sob sol forte.',
                              style: TextStyle(
                                color: tokens.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Switch.adaptive(
                        value: s.highContrast,
                        onChanged: (v) => s.setHighContrast(v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Cor de Destaque',
              style: TextStyle(
                color: tokens.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: AccentPreset.values.map((preset) {
                final selected = s.accentPreset == preset;
                return ChoiceChip(
                  avatar: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: preset.primaryColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: tokens.text.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                  ),
                  label: Text(preset.label),
                  selected: selected,
                  onSelected: (_) => s.setAccentPreset(preset),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            UniformActionButton(
              label: 'Restaurar Aparência Padrão',
              icon: Icons.restore,
              variant: UniformActionVariant.neutral,
              onTap: () async {
                await s.resetAppearance();
                _showSnack('Aparência padrão restaurada.');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleEngineSection(
    AppSettingsController s,
    MotorsportVisualTokens tokens,
  ) {
    Widget buildField({
      required TextEditingController controller,
      required FocusNode focusNode,
      required String label,
      bool decimal = true,
    }) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          label: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Preset de Motor / Veículo',
              style: TextStyle(
                color: tokens.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: EnginePreset.values.map((preset) {
                final selected = s.enginePreset == preset;
                return ChoiceChip(
                  label: Text(
                    preset.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: selected,
                  onSelected: (_) async {
                    await s.selectEnginePreset(preset);
                    _syncEngineControllers(force: true);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 340;
                final dispField = buildField(
                  controller: _dispCtrl,
                  focusNode: _dispFocus,
                  label: 'Cilindrada (L)',
                );
                final massField = buildField(
                  controller: _massCtrl,
                  focusNode: _massFocus,
                  label: 'Massa (kg)',
                  decimal: false,
                );
                final injField = buildField(
                  controller: _injCtrl,
                  focusNode: _injFocus,
                  label: 'Bico (cc/min)',
                  decimal: false,
                );
                final deadField = buildField(
                  controller: _deadCtrl,
                  focusNode: _deadFocus,
                  label: 'Dead-time (ms)',
                );
                final priceField = buildField(
                  controller: _priceCtrl,
                  focusNode: _priceFocus,
                  label: r'Preço Comb. (R$/L)',
                );

                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      dispField,
                      const SizedBox(height: 10),
                      massField,
                      const SizedBox(height: 10),
                      injField,
                      const SizedBox(height: 10),
                      deadField,
                      const SizedBox(height: 10),
                      priceField,
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: dispField),
                        const SizedBox(width: 8),
                        Expanded(child: massField),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: injField),
                        const SizedBox(width: 8),
                        Expanded(child: deadField),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: priceField),
                        const SizedBox(width: 8),
                        const Expanded(child: SizedBox.shrink()),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            UniformActionButton(
              label: 'Aplicar Calibração do Motor',
              icon: Icons.check_circle_outline,
              variant: UniformActionVariant.primary,
              onTap: _applyEngineCalibration,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiSection(
    AppSettingsController s,
    MotorsportVisualTokens tokens,
  ) {
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<AiProviderKind>(
              key: ValueKey<AiProviderKind>(s.aiProvider),
              initialValue: s.aiProvider,
              isExpanded: true,
              dropdownColor: tokens.elevated,
              decoration: const InputDecoration(
                labelText: 'Provedor de IA',
              ),
              items: AiProviderKind.values
                  .map(
                    (provider) => DropdownMenuItem<AiProviderKind>(
                      value: provider,
                      child: Text(
                        provider.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _onProviderChanged,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelCtrl,
              focusNode: _modelFocus,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Modelo',
                hintText: s.aiProvider.defaultModel,
              ),
              onChanged: (_) => _commitAiTextFields(),
              onSubmitted: (_) => _commitAiTextFields(),
            ),
            if (s.aiProvider == AiProviderKind.customOpenAi) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlCtrl,
                focusNode: _baseUrlFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Base URL (Compatível OpenAI)',
                  hintText: 'https://api.openai.com/v1',
                ),
                onChanged: (_) => _commitAiTextFields(),
                onSubmitted: (_) => _commitAiTextFields(),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyCtrl,
              obscureText: _obscureKey,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Chave de API',
                hintText: s.hasApiKey
                    ? '•••••••••••••••• (salva com criptografia)'
                    : 'Cole sua chave de API aqui',
                suffixIcon: IconButton(
                  tooltip: _obscureKey ? 'Mostrar chave' : 'Ocultar chave',
                  icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            if (s.hasApiKey) ...[
              const SizedBox(height: 10),
              Material(
                color: MotorsportColors.ok.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: MotorsportColors.ok.withValues(alpha: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.verified_user_outlined,
                        color: MotorsportColors.ok,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Chave salva com criptografia (Keystore)',
                          style: TextStyle(
                            color: tokens.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            UniformButtonGrid(
              columns: 2,
              children: [
                UniformActionButton(
                  label: 'Salvar Chave',
                  icon: Icons.key_outlined,
                  variant: UniformActionVariant.primary,
                  onTap: _busyKeyAction ? null : _handleSaveApiKey,
                ),
                UniformActionButton(
                  label: 'Remover Chave',
                  icon: Icons.delete_outline,
                  variant: UniformActionVariant.danger,
                  onTap:
                      (!_busyKeyAction && s.hasApiKey) ? _handleClearApiKey : null,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Material(
              color: tokens.surfaceAlt,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: tokens.borderSubtle,
                  width: tokens.cardBorderWidth,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.privacy_tip_outlined,
                      size: 18,
                      color: tokens.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Privacidade: apenas métricas agregadas e resumos estatísticos do CSV são enviados ao provedor de IA quando você solicita uma análise. Sua chave permanece criptografada no aparelho.',
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.tokens,
  });

  final IconData icon;
  final String title;
  final MotorsportVisualTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: tokens.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: tokens.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}
