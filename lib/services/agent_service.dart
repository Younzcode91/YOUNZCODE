import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/chat_entry.dart';
import '../models/workspace_change.dart';
import 'approval_mode.dart';
import 'mcp_client.dart';
import 'settings_store.dart';
import 'workspace_tools.dart';

typedef ToolActivity =
    void Function(String id, String name, String detail, String state);
typedef AgentStatus = void Function(String status);
typedef AgentCheckpoint = void Function(List<Map<String, dynamic>> messages);
typedef AgentChanges = void Function(WorkspaceTurnChanges? changes);

// Out-of-band signals for a completion: the model's reasoning (thinking) tokens
// and the provider's token usage. Reasoning is surfaced here rather than kept in
// the message history, so it is never echoed back to the provider.
typedef AgentInsight =
    void Function({
      String? reasoning,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens,
    });

class AgentCancelledException implements Exception {
  const AgentCancelledException([
    this.message = 'Tugas dibatalkan oleh pengguna.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class AgentStepLimitException implements Exception {
  const AgentStepLimitException(this.maxSteps);

  final int maxSteps;

  @override
  String toString() =>
      'Agent mencapai batas $maxSteps langkah. Checkpoint telah disimpan; '
      'lanjutkan dari checkpoint untuk meneruskan.';
}

class AgentTurnTimeoutException extends TimeoutException {
  AgentTurnTimeoutException(this.limit)
    : super(
        'Tugas melewati batas waktu total ${limit.inMinutes} menit.',
        limit,
      );

  final Duration limit;
}

class _AgentFinalizationException implements Exception {
  const _AgentFinalizationException(this.reason);

  final String reason;
}

class AgentService {
  AgentService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.workspace,
    required PermissionRequest requestPermission,
    required this.onToolActivity,
    required this.onStatus,
    required this.allowWrite,
    required this.allowTerminal,
    this.approvalMode = ApprovalMode.askForApproval,
    required this.environment,
    required this.timeoutMs,
    required this.headers,
    this.planMode = false,
    this.maxSteps = 40,
    this.maxToolCalls = 24,
    this.maxTurnDuration = const Duration(minutes: 10),
    this.maxRequestAttempts = 4,
    this.retryBaseDelay = const Duration(milliseconds: 750),
    this.addonInstructions = const [],
    this.mcpClients = const [],
    this.onCheckpoint,
    this.onChanges,
    this.onInsight,
    http.Client? httpClient,
  }) : _tools = WorkspaceTools(
         root: workspace,
         requestPermission: requestPermission,
         allowWrite: allowWrite,
         allowTerminal: allowTerminal,
         approvalMode: approvalMode,
         environment: environment,
         mcpClients: mcpClients,
         commandTimeoutMs: timeoutMs,
         onChangesChanged: onChanges,
         stageEdits: true,
       ),
       _injectedHttpClient = httpClient;

  final String baseUrl;
  final String apiKey;
  final String model;
  final String workspace;
  final ToolActivity onToolActivity;
  final AgentStatus onStatus;
  final bool allowWrite;
  final bool allowTerminal;
  final ApprovalMode approvalMode;
  final Map<String, String> environment;
  final int timeoutMs;
  final Map<String, String> headers;
  final bool planMode;
  final int maxSteps;
  final int maxToolCalls;
  final Duration maxTurnDuration;
  final int maxRequestAttempts;
  final Duration retryBaseDelay;
  final List<String> addonInstructions;
  final List<McpClient> mcpClients;
  final AgentCheckpoint? onCheckpoint;
  final AgentChanges? onChanges;
  final AgentInsight? onInsight;
  final WorkspaceTools _tools;
  final http.Client? _injectedHttpClient;
  final List<Map<String, dynamic>> _messages = [];
  final List<String> _recentToolCalls = [];
  List<Map<String, Object>>? _toolDefinitions;
  http.Client? _activeHttpClient;
  bool _cancelRequested = false;
  bool _finalizationRequested = false;
  bool _turnDeadlineReached = false;
  bool _disposed = false;

  void clear() {
    _messages.clear();
    _recentToolCalls.clear();
    _notifyCheckpoint();
  }

  void restore(List<ChatEntry> entries) {
    _messages.clear();
    _messages.add(_systemMessage());
    for (final entry in entries) {
      if (entry.role == ChatRole.user || entry.role == ChatRole.assistant) {
        _messages.add({
          'role': entry.role == ChatRole.user ? 'user' : 'assistant',
          'content': entry.content,
        });
      }
    }
    _notifyCheckpoint();
  }

  void restoreMessages(List<Map<String, dynamic>> messages) {
    _messages
      ..clear()
      ..addAll(_copyMessages(messages));
    if (_messages.isEmpty || _messages.first['role'] != 'system') {
      _messages.insert(0, _systemMessage());
    } else {
      _messages[0] = _systemMessage();
    }
    _notifyCheckpoint();
  }

  List<Map<String, dynamic>> snapshotMessages() => _copyMessages(_messages);

  Future<String> send(String prompt) async {
    _ensureUsable();
    _cancelRequested = false;
    _recentToolCalls.clear();
    _tools.beginTurn(prompt);
    onStatus('Menghubungi model');
    if (_messages.isEmpty) {
      _messages.add(_systemMessage());
    }
    _messages.add({'role': 'user', 'content': prompt});
    _notifyCheckpoint();
    return _runLoop();
  }

  WorkspaceTurnChanges? get pendingChanges => _tools.pendingChanges;
  WorkspaceTurnChanges? get lastAppliedTurn => _tools.lastAppliedTurn;

  Future<WorkspaceTurnChanges?> applyPendingChanges({Set<String>? hunkIds}) =>
      _tools.applyChanges(hunkIds: hunkIds);

  void rejectPendingChanges() => _tools.rejectChanges();

  Future<void> revertLastTurn() => _tools.revertLastTurn();

  Future<String> continueFromCheckpoint() async {
    _ensureUsable();
    if (_messages.isEmpty) {
      throw StateError('Belum ada checkpoint yang dapat dilanjutkan.');
    }
    _cancelRequested = false;
    _recentToolCalls.clear();
    onStatus('Melanjutkan dari checkpoint');
    return _runLoop();
  }

  Future<String> _runLoop() async {
    final effectiveTurnDuration = maxTurnDuration > Duration.zero
        ? maxTurnDuration
        : const Duration(minutes: 10);
    final deadline = DateTime.now().add(effectiveTurnDuration);
    final reserveMilliseconds = (effectiveTurnDuration.inMilliseconds ~/ 5)
        .clamp(1, const Duration(minutes: 2).inMilliseconds)
        .toInt();
    final explorationDeadline = deadline.subtract(
      Duration(milliseconds: reserveMilliseconds),
    );
    final effectiveMaxToolCalls = maxToolCalls > 0 ? maxToolCalls : 24;
    var toolCallCount = 0;
    _finalizationRequested = false;
    _turnDeadlineReached = false;
    try {
      try {
        for (var step = 0; step < maxSteps; step++) {
          await _throwIfExplorationExpired(explorationDeadline);
          if (toolCallCount >= effectiveMaxToolCalls) {
            throw _AgentFinalizationException(
              'batas $effectiveMaxToolCalls pemanggilan tool tercapai',
            );
          }
          onStatus(
            step == 0 ? 'Menganalisis permintaan' : 'Melanjutkan analisis',
          );
          final message = await _withinExplorationDeadline(
            _requestCompletion(),
            explorationDeadline,
          );
          _throwIfCancelled();
          _messages.add(message);
          _notifyCheckpoint();
          final calls = message['tool_calls'] as List<dynamic>?;
          if (calls == null || calls.isEmpty) {
            onStatus('Jawaban siap');
            return _messageText(message['content']);
          }

          _AgentFinalizationException? pendingFinalization;
          for (final rawCall in calls) {
            _throwIfCancelled();
            final call = rawCall is Map
                ? Map<String, dynamic>.from(rawCall)
                : <String, dynamic>{};
            final activityId = '${call['id']}';
            String name;
            Map<String, dynamic> typedArguments;
            String? argumentError;
            try {
              final function = Map<String, dynamic>.from(
                call['function'] as Map,
              );
              name = function['name'] as String;
              final rawArguments = function['arguments'];
              // Providers legitimately send "", "{}", or an already-decoded map
              // for no-arg tools; a misbehaving model can send invalid JSON or a
              // non-object. Tolerate all of these so one bad call becomes a
              // recoverable tool error instead of crashing the whole turn.
              final decoded = rawArguments is Map
                  ? rawArguments
                  : (rawArguments is String && rawArguments.trim().isNotEmpty
                        ? jsonDecode(rawArguments)
                        : const <String, dynamic>{});
              typedArguments = Map<String, dynamic>.from(decoded as Map);
            } catch (error) {
              final rawFunction = call['function'];
              name = rawFunction is Map && rawFunction['name'] is String
                  ? rawFunction['name'] as String
                  : 'unknown';
              typedArguments = const {};
              argumentError = 'argumen tool tidak valid ($error)';
            }
            final detail = _toolDetail(name, typedArguments);
            onStatus(_toolStatus(name));
            onToolActivity(activityId, name, detail, 'berjalan');
            String result;
            var activityState = 'selesai';
            Object? terminalError;
            if (argumentError != null) {
              result =
                  'Error: $argumentError. Periksa kembali format argumen dan '
                  'panggil tool lagi dengan JSON yang benar.';
              activityState = 'gagal';
            } else if (toolCallCount >= effectiveMaxToolCalls) {
              result =
                  'Tidak dijalankan karena batas $effectiveMaxToolCalls '
                  'pemanggilan tool tercapai.';
              activityState = 'dibatalkan';
              pendingFinalization ??= _AgentFinalizationException(
                'batas $effectiveMaxToolCalls pemanggilan tool tercapai',
              );
            } else {
              toolCallCount++;
              try {
                final signature = '$name:${jsonEncode(typedArguments)}';
                _recentToolCalls.add(signature);
                if (_recentToolCalls.length > 3) _recentToolCalls.removeAt(0);
                if (_recentToolCalls.length == 3 &&
                    _recentToolCalls.every((item) => item == signature) &&
                    !await _tools.approveDoomLoop(name, typedArguments)) {
                  result = 'Ditolak oleh pengguna karena tool berulang.';
                  activityState = 'ditolak';
                } else {
                  result = await _withinExplorationDeadline(
                    _tools.execute(name, typedArguments),
                    explorationDeadline,
                  );
                  _throwIfCancelled();
                }
              } catch (error) {
                if (error is _AgentFinalizationException) {
                  result =
                      'Dihentikan agar agent sempat menyusun jawaban akhir.';
                  activityState = 'dibatalkan';
                  terminalError = error;
                } else if (error is AgentTurnTimeoutException) {
                  result = 'Error: $error';
                  activityState = 'gagal';
                  terminalError = error;
                } else if (_cancelRequested) {
                  result = 'Dibatalkan oleh pengguna.';
                  activityState = 'dibatalkan';
                } else {
                  result = 'Error: $error';
                  activityState = 'gagal';
                }
              }
            }
            onToolActivity(
              activityId,
              name,
              _completedToolDetail(name, detail, result, activityState),
              activityState,
            );
            _messages.add({
              'role': 'tool',
              'tool_call_id': call['id'],
              'content': result,
            });
            _notifyCheckpoint();
            if (terminalError != null) throw terminalError;
            _throwIfCancelled();
          }
          if (pendingFinalization != null) throw pendingFinalization;
        }
        throw _AgentFinalizationException(
          'batas $maxSteps langkah analisis tercapai',
        );
      } on _AgentFinalizationException catch (error) {
        return await _finalizeTurn(
          reason: error.reason,
          deadline: deadline,
          limit: effectiveTurnDuration,
        );
      }
    } catch (error) {
      _notifyCheckpoint();
      if (_cancelRequested && error is! AgentCancelledException) {
        throw const AgentCancelledException();
      }
      rethrow;
    }
  }

  Future<T> _withinExplorationDeadline<T>(
    Future<T> operation,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await _prepareFinalization();
      throw const _AgentFinalizationException('waktu eksplorasi telah habis');
    }
    try {
      return await operation.timeout(
        remaining,
        onTimeout: () => throw const _AgentFinalizationException(
          'waktu eksplorasi telah habis',
        ),
      );
    } on _AgentFinalizationException {
      await _prepareFinalization();
      rethrow;
    }
  }

  Future<void> _throwIfExplorationExpired(DateTime deadline) async {
    _throwIfCancelled();
    if (!DateTime.now().isBefore(deadline)) {
      await _prepareFinalization();
      throw const _AgentFinalizationException('waktu eksplorasi telah habis');
    }
  }

  Future<void> _prepareFinalization() async {
    if (_finalizationRequested) return;
    _finalizationRequested = true;
    onStatus('Menyiapkan ringkasan akhir');
    if (_injectedHttpClient == null) _activeHttpClient?.close();
    await _tools.cancelActive();
  }

  Future<String> _finalizeTurn({
    required String reason,
    required DateTime deadline,
    required Duration limit,
  }) async {
    await _prepareFinalization();
    onStatus('Merangkum hasil pemeriksaan');
    try {
      final message = await _withinTurnDeadline(
        _requestCompletion(
          allowTools: false,
          finalInstruction:
              'Eksplorasi dihentikan karena $reason. Berikan jawaban akhir '
              'sekarang berdasarkan bukti dan hasil tool yang sudah tersedia. '
              'Tulis dengan bahasa yang natural, santai, dan langsung ke inti. '
              'Gunakan paragraf pendek serta satu baris kosong antarbagian. '
              'Sebutkan dengan jujur tes yang gagal atau timeout, tetapi '
              'jelaskan bahwa itu kegagalan tool bila respons tetap berhasil. '
              'Jangan meminta tool lagi.',
        ),
        deadline,
        limit,
      );
      _throwIfCancelled();
      _messages.add(message);
      _notifyCheckpoint();
      final answer = _messageText(message['content']).trim();
      if (answer.isEmpty) {
        throw StateError('Model tidak memberikan ringkasan akhir.');
      }
      onStatus('Jawaban siap');
      return answer;
    } on TimeoutException {
      await _expireTurn(limit);
      throw AgentTurnTimeoutException(limit);
    } on http.ClientException {
      await _expireTurn(limit);
      throw AgentTurnTimeoutException(limit);
    } finally {
      // Finalization may stop MCP processes; rebuild their definitions on the
      // next turn while preserving staged edits for the review UI.
      _toolDefinitions = null;
    }
  }

  Future<T> _withinTurnDeadline<T>(
    Future<T> operation,
    DateTime deadline,
    Duration limit,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await _expireTurn(limit);
      throw AgentTurnTimeoutException(limit);
    }
    try {
      return await operation.timeout(
        remaining,
        onTimeout: () => throw AgentTurnTimeoutException(limit),
      );
    } on AgentTurnTimeoutException {
      await _expireTurn(limit);
      rethrow;
    }
  }

  Future<void> _expireTurn(Duration limit) async {
    if (_turnDeadlineReached) return;
    _turnDeadlineReached = true;
    onStatus('Batas waktu total ${limit.inMinutes} menit tercapai');
    if (_injectedHttpClient == null) _activeHttpClient?.close();
    await _tools.cancelActive();
  }

  Future<Map<String, dynamic>> _requestCompletion({
    bool allowTools = true,
    String? finalInstruction,
  }) async {
    Object? lastError;
    var useStreaming = !_isLocal9Router;
    for (var attempt = 1; attempt <= maxRequestAttempts; attempt++) {
      _throwIfCancelled();
      if (allowTools && _finalizationRequested) {
        return const {'role': 'assistant', 'content': ''};
      }
      var switchingToCompatibleMode = false;
      try {
        return await _performRequest(
          stream: useStreaming,
          allowTools: allowTools,
          finalInstruction: finalInstruction,
        );
      } on AgentHttpException catch (error) {
        lastError = error;
        if (!error.isRetryable || attempt == maxRequestAttempts) rethrow;
      } on TimeoutException catch (error) {
        lastError = error;
        if (attempt == maxRequestAttempts) rethrow;
      } on http.ClientException catch (error) {
        if (_cancelRequested) throw const AgentCancelledException();
        if (allowTools && _finalizationRequested) {
          return const {'role': 'assistant', 'content': ''};
        }
        lastError = error;
        final nextStreamingMode = _isLocal9Router;
        switchingToCompatibleMode = useStreaming != nextStreamingMode;
        useStreaming = nextStreamingMode;
        if (attempt == maxRequestAttempts) rethrow;
      }
      final transportClosed = lastError is http.ClientException;
      onStatus(
        '${switchingToCompatibleMode
            ? _isLocal9Router
                  ? 'Respons lokal terputus, beralih ke streaming'
                  : 'Streaming terputus, beralih ke mode kompatibel'
            : transportClosed
            ? 'Koneksi provider terputus'
            : 'Gangguan koneksi'}, '
        'mencoba ulang ($attempt/$maxRequestAttempts)',
      );
      final retryDelay = Duration(
        milliseconds: retryBaseDelay.inMilliseconds * (1 << (attempt - 1)),
      );
      if (retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw StateError('Request model gagal: $lastError');
  }

  bool get _isLocal9Router {
    final uri = Uri.tryParse(baseUrl);
    return uri != null &&
        uri.scheme == 'http' &&
        {'127.0.0.1', 'localhost'}.contains(uri.host.toLowerCase()) &&
        uri.port == 20128;
  }

  Future<Map<String, dynamic>> _performRequest({
    required bool stream,
    required bool allowTools,
    String? finalInstruction,
  }) async {
    final requestBaseUrl = normalizeProviderBaseUrl(baseUrl);
    final client = _injectedHttpClient ?? http.Client();
    _activeHttpClient = client;
    final requestBody = <String, Object?>{
      'model': model,
      'messages': [
        ..._messages,
        if (finalInstruction != null)
          {'role': 'system', 'content': finalInstruction},
      ],
      if (allowTools)
        'tools': _toolDefinitions ??= await _tools.initializeAndDefinitions(),
      if (allowTools) 'tool_choice': 'auto',
      'stream': stream,
    };
    final request =
        http.Request('POST', Uri.parse('$requestBaseUrl/chat/completions'))
          ..headers.addAll({
            ...headers,
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': stream
                ? 'text/event-stream, application/json'
                : 'application/json',
          })
          ..body = jsonEncode(requestBody);
    final requestTimeout = Duration(
      milliseconds: timeoutMs > 0 ? timeoutMs : 120000,
    );

    try {
      final response = await client
          .send(request)
          .timeout(
            requestTimeout,
            onTimeout: () {
              if (_injectedHttpClient == null) client.close();
              throw TimeoutException(
                'Model tidak merespons dalam ${requestTimeout.inSeconds} detik.',
                requestTimeout,
              );
            },
          );
      final byteStream = response.stream.timeout(
        requestTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'Aliran respons model berhenti lebih dari '
              '${requestTimeout.inSeconds} detik.',
              requestTimeout,
            ),
          );
          sink.close();
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decodeStream(byteStream);
        throw AgentHttpException.fromParts(response.statusCode, body);
      }
      return await (stream
          ? _decodeCompletionStream(byteStream)
          : _decodeJsonCompletion(byteStream));
    } finally {
      if (identical(_activeHttpClient, client)) _activeHttpClient = null;
      if (_injectedHttpClient == null) client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeJsonCompletion(
    Stream<List<int>> byteStream,
  ) async {
    final bytes = BytesBuilder(copy: false);
    http.ClientException? transportError;
    try {
      await for (final chunk in byteStream) {
        _throwIfCancelled();
        bytes.add(chunk);
      }
    } on http.ClientException catch (error) {
      if (_cancelRequested) throw const AgentCancelledException();
      transportError = error;
    }

    final body = utf8.decode(bytes.takeBytes()).trim();
    if (body.isEmpty) {
      if (transportError != null) throw transportError;
      throw StateError('Provider mengembalikan respons kosong.');
    }
    try {
      final payload = jsonDecode(body);
      if (payload is! Map) {
        throw const FormatException('Respons provider bukan objek JSON.');
      }
      return _messageFromPayload(Map<String, dynamic>.from(payload));
    } catch (_) {
      if (transportError != null) throw transportError;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _decodeCompletionStream(
    Stream<List<int>> byteStream,
  ) async {
    final plainBody = StringBuffer();
    final content = StringBuffer();
    final reasoning = StringBuffer();
    Object? usage;
    final toolCalls = <int, Map<String, dynamic>>{};
    Map<String, dynamic>? fullMessage;
    var role = 'assistant';
    var sawSse = false;
    var sawTerminalEvent = false;

    try {
      await for (final line
          in byteStream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        _throwIfCancelled();
        if (!line.startsWith('data:')) {
          if (line.trim().isNotEmpty) plainBody.writeln(line);
          continue;
        }
        sawSse = true;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          sawTerminalEvent = true;
          continue;
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          // Skip a malformed / partial SSE chunk instead of aborting the turn.
          continue;
        }
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        if (payload['error'] != null) {
          throw AgentHttpException.fromParts(502, jsonEncode(payload));
        }
        if (payload['usage'] != null) usage = payload['usage'];
        final choices = payload['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) continue;
        final choice = Map<String, dynamic>.from(choices.first as Map);
        if (choice['finish_reason'] != null) sawTerminalEvent = true;
        final rawMessage = choice['message'];
        if (rawMessage is Map) {
          fullMessage = Map<String, dynamic>.from(rawMessage);
          continue;
        }
        final rawDelta = choice['delta'];
        if (rawDelta is! Map) continue;
        final delta = Map<String, dynamic>.from(rawDelta);
        if (delta['role'] is String) role = delta['role'] as String;
        content.write(_messageText(delta['content']));
        reasoning.write(
          _messageText(delta['reasoning_content'] ?? delta['reasoning']),
        );
        for (final rawCall
            in delta['tool_calls'] as List<dynamic>? ?? const []) {
          final call = Map<String, dynamic>.from(rawCall as Map);
          final index = call['index'] as int? ?? toolCalls.length;
          final target = toolCalls.putIfAbsent(
            index,
            () => {
              'id': '',
              'type': 'function',
              'function': {'name': '', 'arguments': ''},
            },
          );
          if (call['id'] is String) {
            target['id'] = '${target['id']}${call['id']}';
          }
          if (call['type'] is String) target['type'] = call['type'];
          final rawFunction = call['function'];
          if (rawFunction is Map) {
            final function = target['function'] as Map<String, dynamic>;
            if (rawFunction['name'] is String) {
              function['name'] =
                  '${function['name']}${rawFunction['name'] as String}';
            }
            if (rawFunction['arguments'] is String) {
              function['arguments'] =
                  '${function['arguments']}${rawFunction['arguments'] as String}';
            }
          }
        }
      }
    } on http.ClientException {
      if (!sawTerminalEvent) rethrow;
    }

    if (!sawSse) {
      final body = plainBody.toString().trim();
      if (body.isEmpty) {
        throw StateError('Provider mengembalikan respons kosong.');
      }
      // _messageFromPayload emits its own insight for the non-SSE path.
      return _messageFromPayload(jsonDecode(body) as Map<String, dynamic>);
    }
    _emitInsight(reasoning.toString(), usage);
    if (fullMessage != null) {
      fullMessage
        ..remove('reasoning_content')
        ..remove('reasoning');
      return fullMessage;
    }
    final orderedCalls = toolCalls.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    if (content.isEmpty && orderedCalls.isEmpty) {
      throw StateError('Provider tidak mengembalikan isi jawaban.');
    }
    return {
      'role': role,
      'content': content.isEmpty ? null : content.toString(),
      if (orderedCalls.isNotEmpty)
        'tool_calls': orderedCalls.map((entry) => entry.value).toList(),
    };
  }

  Map<String, dynamic> _messageFromPayload(Map<String, dynamic> payload) {
    final choices = payload['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw StateError('Provider tidak mengembalikan pilihan jawaban.');
    }
    final choice = Map<String, dynamic>.from(choices.first as Map);
    final message = Map<String, dynamic>.from(choice['message'] as Map);
    _emitInsight(
      _messageText(message['reasoning_content'] ?? message['reasoning']),
      payload['usage'],
    );
    // Keep reasoning out of the conversation history sent back to the provider.
    message.remove('reasoning_content');
    message.remove('reasoning');
    return message;
  }

  void _emitInsight(String reasoning, Object? usage) {
    final callback = onInsight;
    if (callback == null) return;
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    final usageMap = usage is Map ? usage : null;
    final trimmedReasoning = reasoning.trim();
    final prompt = asInt(usageMap?['prompt_tokens']);
    final completion = asInt(usageMap?['completion_tokens']);
    final total =
        asInt(usageMap?['total_tokens']) ??
        ((prompt != null && completion != null) ? prompt + completion : null);
    if (trimmedReasoning.isEmpty &&
        prompt == null &&
        completion == null &&
        total == null) {
      return;
    }
    callback(
      reasoning: trimmedReasoning.isEmpty ? null : trimmedReasoning,
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
    );
  }

  static String _messageText(Object? value) {
    if (value is String) return value;
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => item['text'])
          .whereType<String>()
          .join();
    }
    return '';
  }

  static List<Map<String, dynamic>> _copyMessages(
    List<Map<String, dynamic>> messages,
  ) => (jsonDecode(jsonEncode(messages)) as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();

  void _notifyCheckpoint() {
    onCheckpoint?.call(snapshotMessages());
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('Agent sudah dihentikan dan harus dibuat ulang.');
    }
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const AgentCancelledException();
  }

  Map<String, dynamic> _systemMessage() => {
    'role': 'system',
    'content':
        'Anda adalah coding agent pragmatis. Workspace: $workspace. '
        'Periksa kode sebelum mengubahnya, buat perubahan sekecil mungkin, '
        'dan verifikasi dengan test atau build. Gunakan tool secara hemat, '
        'jangan ulangi tes yang sudah timeout, dan berikan kesimpulan segera '
        'setelah bukti utama cukup. Abaikan folder build, release, '
        'release-*, dan graphify-out kecuali memang relevan. '
        'Ikuti bahasa dan nada pengguna. Dalam bahasa Indonesia, tulis seperti '
        'rekan kerja yang ramah: natural, tidak kaku, tidak birokratis, dan '
        'langsung ke hasil. Gunakan paragraf pendek dengan satu baris kosong '
        'antarparagraf atau antarbagian. Gunakan bullet hanya saat benar-benar '
        'membantu; jangan memaksa semua jawaban menjadi daftar bernomor. '
        'Hindari heading Markdown berlebihan dan fenced code block tiga '
        'backtick kecuali pengguna secara khusus meminta contoh kode. '
        'Jangan gunakan backtick atau tanda petik tunggal untuk nilai, istilah, '
        'status, nama file, perintah, atau inline code; selalu gunakan tanda '
        'petik ganda, misalnya HTTP "200". '
        'Jangan gunakan penekanan Markdown dengan tanda **; gunakan kalimat '
        'yang jelas tanpa gaya template yang berulang. '
        '${approvalMode == ApprovalMode.fullAccess ? 'Mode Full access aktif; akses di luar workspace diizinkan bila diperlukan.' : 'Jangan mengakses luar workspace.'}'
        '${planMode ? ' PLAN MODE AKTIF: hanya analisis dan buat rencana langkah demi langkah. Jangan mengubah file atau menjalankan perintah.' : ''}'
        '${addonInstructions.isEmpty ? '' : '\n\nADD-ON INSTRUCTIONS:\n${addonInstructions.join('\n\n---\n\n')}'}',
  };

  Future<void> cancel() async {
    if (_disposed) return;
    _cancelRequested = true;
    onStatus('Membatalkan tugas');
    _activeHttpClient?.close();
    _injectedHttpClient?.close();
    await _tools.cancelActive();
    _disposed = true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRequested = true;
    _activeHttpClient?.close();
    _injectedHttpClient?.close();
    await _tools.dispose();
  }

  String _toolStatus(String name) => switch (name) {
    'list_files' => 'Memetakan file workspace',
    'read_file' => 'Membaca konteks kode',
    'search_text' => 'Mencari referensi kode',
    'write_file' => 'Menyiapkan perubahan file',
    'replace_text' => 'Menerapkan perubahan kode',
    'run_command' => 'Menjalankan verifikasi',
    _ => 'Menjalankan $name',
  };

  String _toolDetail(String name, Map<String, dynamic> arguments) {
    final value = switch (name) {
      'run_command' => arguments['command'],
      'read_file' || 'write_file' || 'replace_text' => arguments['path'],
      'list_files' => arguments['pattern'],
      'search_text' => arguments['pattern'],
      _ => arguments.isEmpty ? null : jsonEncode(arguments),
    };
    return value is String && value.trim().isNotEmpty ? value.trim() : name;
  }

  String _completedToolDetail(
    String name,
    String detail,
    String result,
    String state,
  ) {
    final trimmed = result.trim();
    if (state != 'selesai') {
      return '$detail\n${trimmed.isEmpty ? 'Tidak ada detail tambahan.' : _shortResult(trimmed)}';
    }
    final lines = trimmed
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final explanation = switch (name) {
      'run_command' =>
        trimmed.isEmpty
            ? 'Perintah selesai tanpa output.'
            : 'Perintah selesai. ${_shortResult(trimmed)}',
      'read_file' => 'File selesai dibaca: ${lines.length} baris.',
      'search_text' =>
        lines.isEmpty
            ? 'Pencarian selesai tanpa kecocokan.'
            : 'Pencarian selesai: ${lines.length} kecocokan.',
      'list_files' =>
        lines.isEmpty
            ? 'Pemetaan selesai tanpa file yang cocok.'
            : 'Pemetaan selesai: ${lines.length} file ditemukan.',
      'write_file' => 'Penulisan selesai. ${_shortResult(trimmed)}',
      'replace_text' => 'Edit selesai. ${_shortResult(trimmed)}',
      _ when name.startsWith('mcp_') =>
        'Tool MCP selesai. ${_shortResult(trimmed)}',
      _ =>
        trimmed.isEmpty
            ? 'Tool selesai tanpa output.'
            : 'Tool selesai. ${_shortResult(trimmed)}',
    };
    return '$detail\n$explanation';
  }

  String _shortResult(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 240
        ? normalized
        : '${normalized.substring(0, 237)}...';
  }
}

class AgentHttpException implements Exception {
  const AgentHttpException(this.message, {this.statusCode});

  factory AgentHttpException.fromResponse(http.Response response) {
    return AgentHttpException.fromParts(response.statusCode, response.body);
  }

  factory AgentHttpException.fromParts(int statusCode, String responseBody) {
    try {
      final body = jsonDecode(responseBody) as Map<String, dynamic>;
      final error = body['error'];
      if (error is Map && error['message'] is String) {
        return AgentHttpException(
          '$statusCode: ${error['message']}',
          statusCode: statusCode,
        );
      }
      if (error is String) {
        return AgentHttpException(
          '$statusCode: $error',
          statusCode: statusCode,
        );
      }
      if (body['message'] is String) {
        return AgentHttpException(
          '$statusCode: ${body['message']}',
          statusCode: statusCode,
        );
      }
    } catch (_) {
      // Gunakan body mentah jika provider tidak mengirim JSON error.
    }
    final detail = responseBody.trim();
    final lowerDetail = detail.toLowerCase();
    final looksLikeHtml =
        lowerDetail.startsWith('<!doctype html') ||
        lowerDetail.startsWith('<html');
    if (looksLikeHtml) {
      return AgentHttpException(
        'HTTP $statusCode: endpoint API provider tidak ditemukan. '
        'Periksa Base URL; endpoint OpenAI-compatible biasanya berakhir /v1.',
        statusCode: statusCode,
      );
    }
    final safeDetail = detail.length > 500
        ? '${detail.substring(0, 500)}…'
        : detail;
    return AgentHttpException(
      safeDetail.isEmpty ? 'HTTP $statusCode' : '$statusCode: $safeDetail',
      statusCode: statusCode,
    );
  }

  final String message;
  final int? statusCode;

  bool get isRetryable =>
      const {408, 425, 429, 502, 503, 504, 520, 522, 524}.contains(statusCode);

  @override
  String toString() => message;
}
