import 'package:material_ui/material_ui.dart';

import '../../core/models/channel_def.dart';
import '../../core/protocols/vag_formulas.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

/// Modal pesquisável para escolher qualquer canal/parâmetro disponível para o Painel.
class CardCustomizationSheet extends StatefulWidget {
  const CardCustomizationSheet({
    super.key,
    required this.controller,
    required this.currentCardKeys,
    this.title = 'Selecionar Parâmetro do Card',
  });

  final TelemetryController controller;
  final List<String> currentCardKeys;
  final String title;

  static Future<String?> show(
    BuildContext context, {
    required TelemetryController controller,
    required List<String> currentCardKeys,
    String title = 'Selecionar Parâmetro do Card',
  }) {
    final tokens = MotorsportTheme.tokensOf(context);
    final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;
    if (isTablet) {
      return showDialog<String>(
        context: context,
        builder: (ctx) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
            child: CardCustomizationSheet(
              controller: controller,
              currentCardKeys: currentCardKeys,
              title: title,
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
      ),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
        child: CardCustomizationSheet(
          controller: controller,
          currentCardKeys: currentCardKeys,
          title: title,
        ),
      ),
    );
  }

  @override
  State<CardCustomizationSheet> createState() => _CardCustomizationSheetState();
}

class _CardCustomizationSheetState extends State<CardCustomizationSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _onlyLive = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<_ChannelEntry> _buildEntries() {
    final c = widget.controller;
    final seen = <String>{};
    final out = <_ChannelEntry>[];

    void addKey(String key) {
      if (seen.contains(key)) return;
      seen.add(key);
      final desc = describeChannel(key, c.knownChannels);
      var label = desc.label;
      if (label == key && key.startsWith('g') && key.contains('_c')) {
        final parts = key.substring(1).split('_c');
        if (parts.length == 2) {
          final grp = int.tryParse(parts[0]);
          final cell = int.tryParse(parts[1]);
          if (grp != null && cell != null) {
            final known = vagKnownLabels[(grp, cell)];
            final grpStr = grp.toString().padLeft(3, '0');
            label = known != null ? 'Bloco $grpStr.$cell · $known' : 'Bloco $grpStr.$cell';
          }
        }
      }
      out.add(
        _ChannelEntry(
          key: key,
          label: label,
          unit: desc.unit,
          liveValue: c.latest[key],
          onDashboard: widget.currentCardKeys.contains(key),
        ),
      );
    }

    for (final k in coreChannels.keys) {
      addKey(k);
    }
    for (final k in c.knownChannels.keys) {
      addKey(k);
    }
    for (final k in c.latest.keys) {
      addKey(k);
    }
    for (final k in dynamicChannelInfo.keys) {
      addKey(k);
    }

    // Prioriza canais ao vivo, depois ordem original
    out.sort((a, b) {
      final aLive = a.liveValue != null ? 0 : 1;
      final bLive = b.liveValue != null ? 0 : 1;
      if (aLive != bLive) return aLive.compareTo(bLive);
      return 0;
    });

    return out;
  }

  String _formatLive(String key, String unit, double val) {
    final core = coreChannels[key];
    if (core != null) {
      final s = core.formatValue(val);
      return unit.isNotEmpty ? '$s $unit' : s;
    }
    final decimals = (unit == 'bar' || unit == 'ms' || unit == 'V') ? 2 : 1;
    final s = val.toStringAsFixed(decimals);
    return unit.isNotEmpty ? '$s $unit' : s;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final entries = _buildEntries();
    final q = _query.trim().toLowerCase();

    final filtered = entries.where((e) {
      if (_onlyLive && e.liveValue == null) return false;
      if (q.isEmpty) return true;
      return e.key.toLowerCase().contains(q) ||
          e.label.toLowerCase().contains(q) ||
          e.unit.toLowerCase().contains(q);
    }).toList();

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tokens.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.dashboard_customize_outlined, color: tokens.accent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tokens.text,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Fechar',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.close, color: tokens.muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.borderSubtle),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Buscar sensor (ex: rpm, boost, knock, lambda)...',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              tooltip: 'Limpar busca',
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            )
                          : null,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterChip(
                        selected: _onlyLive,
                        label: const Text('Somente com leitura ativa'),
                        labelStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                        onSelected: (v) => setState(() => _onlyLive = v),
                      ),
                      Text(
                        '${filtered.length} parâmetro(s)',
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.borderSubtle),
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Nenhum parâmetro encontrado para "$_query".',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: tokens.muted, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (ctx, i) {
                        final item = filtered[i];
                        final chColor = MotorsportColors.colorForChannel(item.key);
                        final liveStr = item.liveValue != null
                            ? _formatLive(item.key, item.unit, item.liveValue!)
                            : '--';

                        return Material(
                          color: tokens.surfaceAlt,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: item.onDashboard
                                  ? tokens.accent.withValues(alpha: 0.45)
                                  : tokens.borderSubtle,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => Navigator.of(context).pop(item.key),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: chColor,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                item.label,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: tokens.text,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            if (item.onDashboard) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: tokens.accent.withValues(alpha: 0.16),
                                                  borderRadius: BorderRadius.circular(4),
                                                  border: Border.all(
                                                    color: tokens.accent.withValues(alpha: 0.5),
                                                  ),
                                                ),
                                                child: Text(
                                                  'No Painel',
                                                  maxLines: 1,
                                                  style: TextStyle(
                                                    color: tokens.accent,
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          item.unit.isNotEmpty
                                              ? '${item.key} · ${item.unit}'
                                              : item.key,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: tokens.muted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    liveStr,
                                    style: MotorsportTheme.tabularStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: item.liveValue != null ? chColor : tokens.stale,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelEntry {
  const _ChannelEntry({
    required this.key,
    required this.label,
    required this.unit,
    required this.liveValue,
    required this.onDashboard,
  });

  final String key;
  final String label;
  final String unit;
  final double? liveValue;
  final bool onDashboard;
}
