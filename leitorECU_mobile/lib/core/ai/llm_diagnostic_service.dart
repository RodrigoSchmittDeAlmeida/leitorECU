import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../analytics/log_analyzer.dart';
import '../models/channel_def.dart';
import '../settings/app_settings.dart';

/// Resposta HTTP simplificada retornada pelo transporte de IA.
class LlmHttpResponse {
  final int statusCode;
  final String body;

  const LlmHttpResponse(this.statusCode, this.body);
}

/// Assinatura injetável para transporte HTTP (permite testes determinísticos sem rede).
typedef LlmHttpTransport = Future<LlmHttpResponse> Function({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  required Duration timeout,
});

/// Parecer diagnóstico retornado pelo serviço de IA.
class LlmDiagnosticResult {
  final String analysisMarkdown;
  final String providerLabel;
  final String model;
  final DateTime generatedAt;

  const LlmDiagnosticResult({
    required this.analysisMarkdown,
    required this.providerLabel,
    required this.model,
    required this.generatedAt,
  });
}

/// Exceção amigável em português lançada pelo [LlmDiagnosticService].
class LlmDiagnosticException implements Exception {
  final String userMessage;

  const LlmDiagnosticException(this.userMessage);

  @override
  String toString() => 'LlmDiagnosticException: $userMessage';
}

/// Cliente multi-provedor (Gemini / OpenAI / Custom OpenAI-compatível) usando apenas `dart:io`.
class LlmDiagnosticService {
  final LlmHttpTransport? transport;
  final Duration timeout;

  const LlmDiagnosticService({
    this.transport,
    this.timeout = const Duration(seconds: 45),
  });

  static const String _systemPrompt =
      'Você é um engenheiro especialista em diagnóstico automotivo, injeção eletrônica '
      '(OBD-II, VAG KWP2000 Bosch ME7.5.30, Ford HS-CAN UDS Sigma) e telemetria de motores. '
      'Analise exclusivamente os dados fornecidos com rigor técnico, citando evidências numéricas '
      'concretas e evitando suposições sem respaldo nas medições. Responda sempre em Português do Brasil '
      'em Markdown claro e objetivo.';

  /// Constrói o prompt estruturado em português para análise de um único log CSV.
  String buildSingleLogPrompt(LogAnalysisReport report) {
    final buf = StringBuffer()
      ..writeln('Analise o log de telemetria automotiva abaixo e emita um parecer técnico.')
      ..writeln()
      ..writeln('## Metadados da Sessão')
      ..writeln('- Arquivo: ${report.fileName}')
      ..writeln('- Amostras: ${report.sampleCount}')
      ..writeln('- Duração total: ${report.durationSec.toStringAsFixed(1)} s')
      ..writeln('- Taxa média de amostragem: ${report.avgSampleRateHz.toStringAsFixed(1)} Hz')
      ..writeln('- Distância integrada: ${report.distanceKm.toStringAsFixed(2)} km')
      ..writeln('- Pausas de standby (>5s) ignoradas: ${report.standbyGapCount}')
      ..writeln(
        '- Regimes: Movimento ${report.movingPct.toStringAsFixed(1)}% | '
        'Marcha Lenta ${report.idlePct.toStringAsFixed(1)}% | '
        'Cut-Off ${report.cutoffPct.toStringAsFixed(1)}%',
      )
      ..writeln('- Motor Turbo/GDI detectado: ${report.isTurboDetected ? 'Sim' : 'Não'}')
      ..writeln()
      ..writeln('## Estatísticas por Canal')
      ..writeln(
        '| Canal | Unid. | Média | Mediana (P50) | Moda (Freq%) | Mín | Máx | P5 | P95 | Desvio Padrão | N |',
      )
      ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');

    for (final s in report.channelStats) {
      final dec = _decimalsFor(s.key);
      final unit = s.unit.isEmpty ? '-' : s.unit;
      buf.writeln(
        '| ${s.label} (`${s.key}`) | $unit | '
        '${s.mean.toStringAsFixed(dec)} | '
        '${s.median.toStringAsFixed(dec)} | '
        '${s.mode.toStringAsFixed(dec)} (${s.modeFrequencyPct.toStringAsFixed(0)}%) | '
        '${s.min.toStringAsFixed(dec)} | '
        '${s.max.toStringAsFixed(dec)} | '
        '${s.p5.toStringAsFixed(dec)} | '
        '${s.p95.toStringAsFixed(dec)} | '
        '${s.stdDev.toStringAsFixed(dec)} | '
        '${s.count} |',
      );
    }

    buf
      ..writeln()
      ..writeln('## Achados das Regras Offline');
    if (report.findings.isEmpty) {
      buf.writeln('- Nenhum achado registrado.');
    } else {
      for (final f in report.findings) {
        buf.writeln('- [${f.severity.toUpperCase()}] (${f.category}) ${f.title}: ${f.detail}');
      }
    }

    buf
      ..writeln()
      ..writeln('## Eventos / Marcadores Registrados (Total: ${report.events.length})');
    if (report.events.isEmpty) {
      buf.writeln('- Nenhum evento registrado no log.');
    } else {
      for (final ev in report.events.take(20)) {
        buf.writeln('- ${ev.timeSec.toStringAsFixed(1)}s: ${ev.text}');
      }
      if (report.events.length > 20) {
        buf.writeln('- ... e mais ${report.events.length - 20} evento(s).');
      }
    }

    buf
      ..writeln()
      ..writeln('## Formato Obrigatório da Resposta')
      ..writeln('Estruture o parecer exatamente nas 3 seções abaixo:')
      ..writeln('1. **Diagnóstico Geral** (visão objetiva do comportamento do motor e da sessão).')
      ..writeln(
        '2. **Possíveis Problemas** (para cada ponto, informe **Severidade** [Crítico/Atenção/Informativo] '
        '+ **Evidência Numérica** citando média/mediana/moda/mín/máx/P5/P95 observados).',
      )
      ..writeln('3. **Próximas Verificações** (inspeções práticas e testes recomendados em oficina).');

    return buf.toString();
  }

  /// Constrói o prompt estruturado em português para comparar Log A e Log B.
  String buildComparisonPrompt(LogComparisonReport comparison) {
    final a = comparison.reportA;
    final b = comparison.reportB;
    final buf = StringBuffer()
      ..writeln('Compare os dois logs de telemetria automotiva abaixo (Log A como referência e Log B como comparação).')
      ..writeln()
      ..writeln('## Resumo das Sessões')
      ..writeln(
        '- **Log A**: ${a.fileName} | ${a.sampleCount} amostras | '
        '${a.durationSec.toStringAsFixed(1)} s | ${a.distanceKm.toStringAsFixed(2)} km | '
        'Mov ${a.movingPct.toStringAsFixed(0)}% / Lenta ${a.idlePct.toStringAsFixed(0)}% / '
        'Cut-Off ${a.cutoffPct.toStringAsFixed(0)}%',
      )
      ..writeln(
        '- **Log B**: ${b.fileName} | ${b.sampleCount} amostras | '
        '${b.durationSec.toStringAsFixed(1)} s | ${b.distanceKm.toStringAsFixed(2)} km | '
        'Mov ${b.movingPct.toStringAsFixed(0)}% / Lenta ${b.idlePct.toStringAsFixed(0)}% / '
        'Cut-Off ${b.cutoffPct.toStringAsFixed(0)}%',
      )
      ..writeln()
      ..writeln('## Destaques Automáticos')
      ..writeln(comparison.summaryHighlights.map((h) => '- $h').join('\n'))
      ..writeln()
      ..writeln('## Tabela Comparativa de Canais (Log A → Log B)')
      ..writeln(
        '| Canal | Unid. | Média A → B (Δ / Δ%) | Mediana A → B | Moda A → B | Mín/Máx A | Mín/Máx B | Significativo |',
      )
      ..writeln('|---|---:|---|---:|---:|---:|---:|:---:|');

    for (final d in comparison.deltas) {
      final dec = _decimalsFor(d.key);
      final unit = d.unit.isEmpty ? '-' : d.unit;
      final pctStr = d.deltaMeanPct != null ? ' / ${_signed(d.deltaMeanPct!, 1)}%' : '';
      buf.writeln(
        '| ${d.label} (`${d.key}`) | $unit | '
        '${d.statA.mean.toStringAsFixed(dec)} → ${d.statB.mean.toStringAsFixed(dec)} '
        '(${_signed(d.deltaMean, dec)}$pctStr) | '
        '${d.statA.median.toStringAsFixed(dec)} → ${d.statB.median.toStringAsFixed(dec)} | '
        '${d.statA.mode.toStringAsFixed(dec)} → ${d.statB.mode.toStringAsFixed(dec)} | '
        '${d.statA.min.toStringAsFixed(dec)}..${d.statA.max.toStringAsFixed(dec)} | '
        '${d.statB.min.toStringAsFixed(dec)}..${d.statB.max.toStringAsFixed(dec)} | '
        '${d.isSignificant ? 'SIM' : 'não'} |',
      );
    }

    if (comparison.onlyInA.isNotEmpty || comparison.onlyInB.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## Canais Exclusivos');
      if (comparison.onlyInA.isNotEmpty) {
        buf.writeln('- Apenas no Log A: ${comparison.onlyInA.join(', ')}');
      }
      if (comparison.onlyInB.isNotEmpty) {
        buf.writeln('- Apenas no Log B: ${comparison.onlyInB.join(', ')}');
      }
    }

    buf
      ..writeln()
      ..writeln('## Achados Automáticos (Log A)')
      ..writeln(a.findings.map((f) => '- [${f.severity.toUpperCase()}] ${f.title}: ${f.detail}').join('\n'))
      ..writeln()
      ..writeln('## Achados Automáticos (Log B)')
      ..writeln(b.findings.map((f) => '- [${f.severity.toUpperCase()}] ${f.title}: ${f.detail}').join('\n'))
      ..writeln()
      ..writeln('## Formato Obrigatório da Resposta')
      ..writeln('Estruture o parecer comparativo exatamente nas 3 seções abaixo:')
      ..writeln('1. **Diagnóstico Comparativo Geral** (resumo do que melhorou, manteve ou piorou entre A e B).')
      ..writeln(
        '2. **Variações Relevantes & Possíveis Causas** (com **Severidade** + **Evidência Numérica** citando os deltas).',
      )
      ..writeln('3. **Próximas Verificações** (recomendações práticas baseadas nas diferenças encontradas).');

    return buf.toString();
  }

  /// Envia análise de um único log ao provedor de IA configurado.
  Future<LlmDiagnosticResult> analyzeSingleLog({
    required LogAnalysisReport report,
    required AiProviderKind provider,
    required String model,
    required String apiKey,
    String? customBaseUrl,
  }) {
    final prompt = buildSingleLogPrompt(report);
    return _sendPrompt(
      userPrompt: prompt,
      provider: provider,
      model: model,
      apiKey: apiKey,
      customBaseUrl: customBaseUrl,
    );
  }

  /// Envia análise comparativa entre 2 logs ao provedor de IA configurado.
  Future<LlmDiagnosticResult> analyzeComparison({
    required LogComparisonReport comparison,
    required AiProviderKind provider,
    required String model,
    required String apiKey,
    String? customBaseUrl,
  }) {
    final prompt = buildComparisonPrompt(comparison);
    return _sendPrompt(
      userPrompt: prompt,
      provider: provider,
      model: model,
      apiKey: apiKey,
      customBaseUrl: customBaseUrl,
    );
  }

  Future<LlmDiagnosticResult> _sendPrompt({
    required String userPrompt,
    required AiProviderKind provider,
    required String model,
    required String apiKey,
    String? customBaseUrl,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      throw const LlmDiagnosticException(
        'Chave de API não configurada. Acesse Configurações para informar sua chave.',
      );
    }

    final effectiveModel =
        model.trim().isNotEmpty ? model.trim() : provider.defaultModel;

    final Uri uri;
    final Map<String, String> headers;
    final String requestBody;

    if (provider == AiProviderKind.gemini) {
      uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '${Uri.encodeComponent(effectiveModel)}:generateContent',
      );
      headers = {
        'x-goog-api-key': cleanKey,
        'Content-Type': 'application/json',
      };
      requestBody = jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _systemPrompt},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': userPrompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.25,
        },
      });
    } else {
      final rawBase = provider == AiProviderKind.customOpenAi
          ? ((customBaseUrl ?? '').trim().isNotEmpty
              ? customBaseUrl!.trim()
              : provider.defaultBaseUrl)
          : provider.defaultBaseUrl;

      uri = _validateAndBuildChatUri(rawBase);
      headers = {
        'Authorization': 'Bearer $cleanKey',
        'Content-Type': 'application/json',
      };
      requestBody = jsonEncode({
        'model': effectiveModel,
        'temperature': 0.25,
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      });
    }

    final exec = transport ?? _defaultHttpTransport;
    final LlmHttpResponse resp;
    try {
      resp = await exec(
        uri: uri,
        headers: headers,
        body: requestBody,
        timeout: timeout,
      ).timeout(timeout);
    } on TimeoutException {
      throw LlmDiagnosticException(
        'Tempo esgotado (${timeout.inSeconds}s) ao aguardar resposta de ${provider.label}. '
        'Verifique sua conexão e tente novamente.',
      );
    } on SocketException catch (e) {
      throw LlmDiagnosticException(
        _sanitize(
          'Sem conexão de rede ao acessar ${provider.label}: ${e.message}',
          cleanKey,
        ),
      );
    } on HandshakeException catch (e) {
      throw LlmDiagnosticException(
        _sanitize(
          'Falha de certificado TLS/HTTPS ao conectar em ${provider.label}: ${e.message}',
          cleanKey,
        ),
      );
    } on HttpException catch (e) {
      throw LlmDiagnosticException(
        _sanitize(
          'Erro de comunicação HTTP com ${provider.label}: ${e.message}',
          cleanKey,
        ),
      );
    } on LlmDiagnosticException {
      rethrow;
    } catch (e) {
      throw LlmDiagnosticException(
        _sanitize(
          'Falha inesperada ao consultar ${provider.label}: $e',
          cleanKey,
        ),
      );
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LlmDiagnosticException(
        _mapHttpError(
          statusCode: resp.statusCode,
          body: resp.body,
          providerLabel: provider.label,
          model: effectiveModel,
          apiKey: cleanKey,
        ),
      );
    }

    final text = _extractResponseText(
      provider: provider,
      body: resp.body,
      apiKey: cleanKey,
    );

    return LlmDiagnosticResult(
      analysisMarkdown: text.trim(),
      providerLabel: provider.label,
      model: effectiveModel,
      generatedAt: DateTime.now(),
    );
  }

  static Uri _validateAndBuildChatUri(String rawBase) {
    var cleanBase = rawBase.trim();
    while (cleanBase.endsWith('/')) {
      cleanBase = cleanBase.substring(0, cleanBase.length - 1);
    }
    final parsed = Uri.tryParse(cleanBase);
    if (parsed == null || !parsed.hasAuthority || parsed.host.isEmpty) {
      throw const LlmDiagnosticException(
        'URL base da API inválida. Informe um endereço completo (ex.: https://api.openai.com/v1).',
      );
    }

    final hostLower = parsed.host.toLowerCase();
    final isHttps = parsed.scheme == 'https';
    final isAllowedLocalHttp = parsed.scheme == 'http' &&
        (hostLower == 'localhost' ||
            hostLower == '127.0.0.1' ||
            hostLower == '10.0.2.2');

    if (!isHttps && !isAllowedLocalHttp) {
      throw const LlmDiagnosticException(
        'URL da API não segura: apenas HTTPS é permitido (HTTP é aceito apenas em localhost, 127.0.0.1 ou 10.0.2.2).',
      );
    }

    final fullUrl = cleanBase.endsWith('/chat/completions')
        ? cleanBase
        : '$cleanBase/chat/completions';
    return Uri.parse(fullUrl);
  }

  static String _extractResponseText({
    required AiProviderKind provider,
    required String body,
    required String apiKey,
  }) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw LlmDiagnosticException(
        _sanitize(
          'Resposta inválida de ${provider.label} (JSON malformado).',
          apiKey,
        ),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const LlmDiagnosticException(
        'Resposta inesperada do servidor de IA.',
      );
    }

    if (provider == AiProviderKind.gemini) {
      final candidates = decoded['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final first = candidates.first;
        if (first is Map<String, dynamic>) {
          final content = first['content'];
          if (content is Map<String, dynamic>) {
            final parts = content['parts'];
            if (parts is List) {
              final textBuf = StringBuffer();
              for (final p in parts) {
                if (p is Map<String, dynamic> && p['text'] is String) {
                  textBuf.write(p['text'] as String);
                }
              }
              final out = textBuf.toString().trim();
              if (out.isNotEmpty) return out;
            }
          }
        }
      }
      final feedback = decoded['promptFeedback'];
      if (feedback is Map<String, dynamic> && feedback['blockReason'] != null) {
        throw LlmDiagnosticException(
          'A resposta foi bloqueada pelo filtro de segurança do Gemini (${feedback['blockReason']}).',
        );
      }
      throw const LlmDiagnosticException(
        'O Gemini não retornou texto diagnóstico na resposta.',
      );
    }

    // OpenAI / Custom OpenAI-compatible
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map<String, dynamic>) {
        final message = first['message'];
        if (message is Map<String, dynamic>) {
          final content = message['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content;
          }
          if (content is List) {
            final textBuf = StringBuffer();
            for (final item in content) {
              if (item is Map<String, dynamic> && item['text'] is String) {
                textBuf.write(item['text'] as String);
              }
            }
            final out = textBuf.toString().trim();
            if (out.isNotEmpty) return out;
          }
        }
      }
    }

    throw LlmDiagnosticException(
      'O provedor ${provider.label} não retornou conteúdo diagnóstico em choices[0].message.content.',
    );
  }

  static String _mapHttpError({
    required int statusCode,
    required String body,
    required String providerLabel,
    required String model,
    required String apiKey,
  }) {
    final serverMsg = _extractApiErrorMessage(body);
    final sanitizedDetail =
        serverMsg != null ? _sanitize(serverMsg, apiKey) : null;

    if (statusCode == 401 || statusCode == 403) {
      return 'Autenticação recusada ($statusCode) em $providerLabel. '
          'Verifique se sua chave de API é válida e possui permissão.';
    }
    if (statusCode == 429) {
      return 'Limite de uso ou cota excedida (429) em $providerLabel. '
          'Aguarde alguns instantes e tente novamente.';
    }
    if (statusCode == 404) {
      return 'Modelo "$model" ou endpoint não encontrado (404) em $providerLabel. '
          'Confira o nome do modelo e a URL configurada.';
    }
    if (statusCode >= 500) {
      return 'Erro temporário no servidor de $providerLabel ($statusCode). '
          'Tente novamente em instantes.';
    }
    final detailSuffix =
        (sanitizedDetail != null && sanitizedDetail.isNotEmpty)
            ? ': $sanitizedDetail'
            : '';
    return 'Erro HTTP $statusCode em $providerLabel$detailSuffix';
  }

  static String? _extractApiErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic> && err['message'] is String) {
          return (err['message'] as String).trim();
        }
        if (err is String && err.trim().isNotEmpty) {
          return err.trim();
        }
        if (decoded['message'] is String) {
          return (decoded['message'] as String).trim();
        }
      }
    } catch (_) {}
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}...' : trimmed;
  }

  static String _sanitize(String message, String apiKey) {
    if (apiKey.isEmpty) return message;
    var out = message.replaceAll(apiKey, '***');
    final encodedQuery = Uri.encodeQueryComponent(apiKey);
    if (encodedQuery.isNotEmpty) {
      out = out.replaceAll(encodedQuery, '***');
    }
    final encodedComp = Uri.encodeComponent(apiKey);
    if (encodedComp.isNotEmpty) {
      out = out.replaceAll(encodedComp, '***');
    }
    return out;
  }

  static Future<LlmHttpResponse> _defaultHttpTransport({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      headers.forEach((k, v) => request.headers.set(k, v));
      request.add(utf8.encode(body));
      final response = await request.close().timeout(timeout);
      final responseBody =
          await response.transform(utf8.decoder).join().timeout(timeout);
      return LlmHttpResponse(response.statusCode, responseBody);
    } finally {
      client.close(force: true);
    }
  }

  static int _decimalsFor(String key) {
    final core = coreChannels[key];
    if (core != null) return core.decimals;
    if (key == 'inj_pulse_width' || key == 'accel_g') return 2;
    return 2;
  }

  static String _signed(double v, int decimals) {
    final prefix = v >= 0 ? '+' : '';
    return '$prefix${v.toStringAsFixed(decimals)}';
  }
}
