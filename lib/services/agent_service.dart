import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_entry.dart';
import '../models/workspace_change.dart';
import 'approval_mode.dart';
import 'agent_completion_client.dart';
import 'agent_errors.dart';
import 'browser_agent_service.dart';
import 'mcp_client.dart';
import 'tool_permission_store.dart';
import 'workspace_tools.dart';

export 'agent_errors.dart'
    show
        AgentCancelledException,
        AgentEmptyResponseException,
        AgentHttpException,
        AgentStepLimitException,
        AgentTurnTimeoutException;

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
    this.toolPermissionPolicies = const {},
    this.onToolPermissionChanged,
    this.allowExternalPaths = true,
    BrowserAutomation? browser,
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
         browser: browser,
         allowExternalPaths: allowExternalPaths,
         toolPermissionPolicies: toolPermissionPolicies,
         onToolPermissionChanged: onToolPermissionChanged,
       ) {
    _completionClient = AgentCompletionClient(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      timeoutMs: timeoutMs,
      headers: headers,
      maxRequestAttempts: maxRequestAttempts,
      retryBaseDelay: retryBaseDelay,
      onStatus: onStatus,
      isCancelled: () => _cancelRequested,
      shouldStop: () => _finalizationRequested,
      onInsight: onInsight,
      httpClient: httpClient,
    );
  }

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
  final Map<String, ToolPermissionPolicy> toolPermissionPolicies;
  final ToolPermissionChanged? onToolPermissionChanged;

  /// When false, the agent can never read or write outside [workspace];
  /// external-directory access is rejected outright instead of prompting.
  final bool allowExternalPaths;
  final WorkspaceTools _tools;
  late final AgentCompletionClient _completionClient;
  final List<Map<String, dynamic>> _messages = [];
  final List<String> _recentToolCalls = [];
  List<Map<String, Object>>? _toolDefinitions;
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

  /// Continues the same logical task with an internal user prompt while
  /// preserving staged workspace edits from the preceding completion.
  Future<String> continueWithPrompt(String prompt) async {
    _ensureUsable();
    if (_messages.isEmpty) {
      throw StateError('Belum ada checkpoint yang dapat dilanjutkan.');
    }
    _cancelRequested = false;
    _recentToolCalls.clear();
    onStatus('Melanjutkan goal dari checkpoint');
    _messages.add({'role': 'user', 'content': prompt});
    _notifyCheckpoint();
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
          final calls = message['tool_calls'] as List<dynamic>?;
          if (calls == null || calls.isEmpty) {
            final answer = _messageText(message['content']).trim();
            if (answer.isEmpty) {
              throw const AgentEmptyResponseException();
            }
            _messages.add(message);
            _notifyCheckpoint();
            onStatus('Jawaban siap');
            return answer;
          }
          _messages.add(message);
          _notifyCheckpoint();

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
    _completionClient.closeActiveTransport();
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
      final answer = _messageText(message['content']).trim();
      if (answer.isEmpty) {
        throw const AgentEmptyResponseException(
          'Model tidak memberikan ringkasan akhir setelah dicoba ulang.',
        );
      }
      _messages.add(message);
      _notifyCheckpoint();
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
    _completionClient.closeActiveTransport();
    await _tools.cancelActive();
  }

  Future<Map<String, dynamic>> _requestCompletion({
    bool allowTools = true,
    String? finalInstruction,
  }) async {
    final definitions = allowTools
        ? (_toolDefinitions ??= await _tools.initializeAndDefinitions())
        : const <Map<String, Object>>[];
    try {
      return await _completionClient.request(
        messages: _messages,
        toolDefinitions: definitions,
        allowTools: allowTools,
        finalInstruction: finalInstruction,
      );
    } on AgentCompletionStoppedException {
      throw const _AgentFinalizationException(
        'transport eksplorasi dihentikan untuk finalisasi',
      );
    }
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
        'Untuk tugas web, panggil browser_open lalu browser_read sebelum '
        'berinteraksi dengan ref elemen; jangan menebak ref. '
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
    _completionClient.dispose();
    await _tools.cancelActive();
    _disposed = true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRequested = true;
    _completionClient.dispose();
    await _tools.dispose();
  }

  String _toolStatus(String name) => switch (name) {
    'list_files' => 'Memetakan file workspace',
    'read_file' => 'Membaca konteks kode',
    'search_text' => 'Mencari referensi kode',
    'write_file' => 'Menyiapkan perubahan file',
    'replace_text' => 'Menerapkan perubahan kode',
    'run_command' => 'Menjalankan verifikasi',
    'browser_open' => 'Membuka halaman di Agent Browser',
    'browser_read' => 'Membaca struktur halaman',
    'browser_click' => 'Mengklik elemen browser',
    'browser_type' => 'Mengisi halaman browser',
    'browser_upload' => 'Menyiapkan upload browser',
    'browser_screenshot' => 'Mengambil screenshot browser',
    'browser_back' ||
    'browser_forward' ||
    'browser_reload' => 'Menavigasi Agent Browser',
    _ => 'Menjalankan $name',
  };

  String _toolDetail(String name, Map<String, dynamic> arguments) {
    final value = switch (name) {
      'run_command' => arguments['command'],
      'read_file' || 'write_file' || 'replace_text' => arguments['path'],
      'browser_open' => arguments['url'],
      'browser_click' || 'browser_type' || 'browser_upload' => arguments['ref'],
      'browser_read' ||
      'browser_screenshot' ||
      'browser_back' ||
      'browser_forward' ||
      'browser_reload' => 'Agent Browser',
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
