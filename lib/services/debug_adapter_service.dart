import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_launch.dart';

class DebugAdapterLaunch {
  const DebugAdapterLaunch({
    required this.executable,
    required this.arguments,
    required this.launchArguments,
    this.socketServer = false,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, Object?> launchArguments;
  final bool socketServer;

  static DebugAdapterLaunch? forFile(String filePath, String workspace) {
    final extension = filePath.split('.').last.toLowerCase();
    return switch (extension) {
      'dart' => DebugAdapterLaunch(
        executable: 'dart',
        arguments: const ['debug_adapter'],
        launchArguments: {
          'type': 'dart',
          'request': 'launch',
          'name': 'YOUNZCODE Dart',
          'program': filePath,
          'cwd': workspace,
          'stopOnEntry': false,
          'toolArgs': ['--enable-asserts'],
        },
      ),
      'py' => DebugAdapterLaunch(
        executable: 'python',
        arguments: const ['-m', 'debugpy.adapter'],
        launchArguments: {
          'type': 'python',
          'request': 'launch',
          'name': 'YOUNZCODE Python',
          'program': filePath,
          'cwd': workspace,
          'console': 'internalConsole',
          'stopOnEntry': false,
          'justMyCode': true,
        },
      ),
      'js' || 'mjs' || 'cjs' => _javascriptLaunch(filePath, workspace),
      _ => null,
    };
  }

  static DebugAdapterLaunch? _javascriptLaunch(
    String filePath,
    String workspace,
  ) {
    final configured = Platform.environment['YOUNZCODE_JS_DEBUG'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (configured != null && configured.isNotEmpty) configured,
      '$executableDirectory${Platform.pathSeparator}debug-adapters'
          '${Platform.pathSeparator}js-debug${Platform.pathSeparator}src'
          '${Platform.pathSeparator}dapDebugServer.js',
      if (localAppData != null)
        '$localAppData${Platform.pathSeparator}YOUNZCODE${Platform.pathSeparator}'
            'debug-adapters${Platform.pathSeparator}js-debug${Platform.pathSeparator}'
            'src${Platform.pathSeparator}dapDebugServer.js',
    ];
    final script = candidates
        .where((path) => File(path).existsSync())
        .firstOrNull;
    if (script == null) return null;
    final nodeBinary = Platform.isWindows ? 'node.exe' : 'node';
    final bundledNode = File(
      '${File(script).parent.parent.parent.path}${Platform.pathSeparator}'
      'node${Platform.pathSeparator}$nodeBinary',
    );
    final runtimeExecutable = bundledNode.existsSync()
        ? bundledNode.path
        : 'node';
    return DebugAdapterLaunch(
      executable: runtimeExecutable,
      arguments: [script, '0', '127.0.0.1'],
      socketServer: true,
      launchArguments: {
        'type': 'pwa-node',
        'request': 'launch',
        'name': 'YOUNZCODE Node.js',
        'program': filePath,
        'cwd': workspace,
        '__workspaceFolder': workspace,
        'console': 'internalConsole',
        'stopOnEntry': false,
        'runtimeExecutable': runtimeExecutable,
        'attachSimplePort': 0,
        'autoAttachChildProcesses': false,
        'outputCapture': 'std',
        'skipFiles': ['<node_internals>/**'],
      },
    );
  }
}

class DebugAdapterEvent {
  const DebugAdapterEvent(this.name, this.body);
  final String name;
  final Map<String, dynamic> body;
}

/// Handshake timing for one debug session, so the load-test harness can
/// report how close a cold start came to the configured timeout.
class DebugAdapterTiming {
  DebugAdapterTiming({required this.adapterId, required this.timeout});

  final String adapterId;
  final Duration timeout;
  final _stopwatch = Stopwatch()..start();
  Duration? initializedAfter;
  Duration? launchAfter;

  void markInitialized() => initializedAfter ??= _stopwatch.elapsed;

  void markLaunch() => launchAfter ??= _stopwatch.elapsed;

  Duration get total => launchAfter ?? initializedAfter ?? _stopwatch.elapsed;

  Map<String, Object?> toJson() => {
    'adapterId': adapterId,
    'timeoutMs': timeout.inMilliseconds,
    'initializedMs': initializedAfter?.inMilliseconds,
    'launchMs': launchAfter?.inMilliseconds,
    'totalMs': total.inMilliseconds,
  };
}

/// A DAP request that is still waiting for the adapter's response.
/// Tracked so a failed session can report which commands were in flight.
class _PendingRequest {
  _PendingRequest({required this.command});

  final String command;
  final DateTime startedAt = DateTime.now();
  final completer = Completer<Map<String, dynamic>>();
}

class DebugAdapterService {
  DebugAdapterService({this.timeout = const Duration(seconds: 30)});

  /// Timeout for the DAP handshake: per-request responses, the initial
  /// `initialized` event, and the JavaScript adapter's listening line.
  /// Deliberately generous: debugpy / js-debug cold starts can exceed 15
  /// seconds on a busy machine (for example when the full test suite runs
  /// concurrently), and a premature timeout tears the adapter down and fails
  /// the debug session.
  final Duration timeout;

  Process? _process;
  Socket? _socket;
  IOSink? _sink;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final _childSockets = <Socket>[];
  final _childSubscriptions = <StreamSubscription<List<int>>>[];
  final _events = StreamController<DebugAdapterEvent>.broadcast();
  final _pending = <int, _PendingRequest>{};
  final _stderrBuffer = <String>[];
  Timer? _watchdog;
  bool _processExited = false;
  int? _processExitCode;
  bool _cleaning = false;
  bool _diagnosticsEmitted = false;
  DebugAdapterTiming? _timing;
  final _buffers = <IOSink, List<int>>{};
  final _initialized = <IOSink, Completer<void>>{};
  Future<void> _writeTail = Future<void>.value();
  int _sequence = 1;
  int? _threadId;
  int? _pendingEntryThreadId;
  bool _configurationDone = false;
  int? _serverPort;
  String? _sourcePath;
  Set<int> _breakpoints = const {};

  Stream<DebugAdapterEvent> get events => _events.stream;
  bool get running => _process != null;
  int? get threadId => _threadId;

  /// Handshake timing of the most recent session (null before any `start`).
  /// The load-test harness reads this to report cold-start margins.
  Map<String, Object?>? get handshakeTiming => _timing?.toJson();

  Future<void> start({
    required DebugAdapterLaunch launch,
    required String workspace,
    required String sourcePath,
    required Set<int> breakpoints,
  }) async {
    if (_process != null) throw StateError('Debug adapter is already running.');
    // Adapter executables and scripts can live under paths containing `&` or
    // spaces; launch without a shell so no metacharacter is ever interpreted.
    final resolved = resolveProcessLaunch(launch.executable, launch.arguments);
    final process = await Process.start(
      resolved.executable,
      resolved.arguments,
      workingDirectory: workspace,
      runInShell: false,
    );
    _process = process;
    _processExited = false;
    _processExitCode = null;
    _diagnosticsEmitted = false;
    // Watchdog: periodically check adapter health so a crash mid-handshake
    // fails fast with diagnostics instead of waiting for a request timeout.
    _watchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _watchdogTick(),
    );
    try {
      if (launch.socketServer) {
        final stdout = process.stdout.asBroadcastStream();
        final listening = await stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line.contains('Debug server listening at'))
            .timeout(timeout);
        final port = int.tryParse(
          RegExp(r':(\d+)\s*$').firstMatch(listening)?.group(1) ?? '',
        );
        if (port == null) {
          throw StateError('Invalid JavaScript adapter address.');
        }
        final socket = await Socket.connect('127.0.0.1', port);
        _serverPort = port;
        _socket = socket;
        _sink = socket;
        _buffers[socket] = <int>[];
        _stdoutSubscription = socket.listen(
          (bytes) => _receiveBytes(socket, bytes),
        );
      } else {
        _sink = process.stdin;
        _buffers[process.stdin] = <int>[];
        _stdoutSubscription = process.stdout.listen(
          (bytes) => _receiveBytes(process.stdin, bytes),
        );
      }
      _stderrSubscription = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((text) {
            _appendStderr(text);
            _events.add(
              DebugAdapterEvent('output', {
                'category': 'stderr',
                'output': text,
              }),
            );
          });
      unawaited(
        process.exitCode.then((code) {
          if (!identical(_process, process)) return;
          _processExited = true;
          _processExitCode = code;
          _events.add(DebugAdapterEvent('terminated', {'exitCode': code}));
          // Requests still in flight mean the session died mid-handshake or
          // mid-command; fail with diagnostics instead of a bare error.
          unawaited(
            _pending.isEmpty
                ? _cleanProcess(process)
                : _failSession(
                    'The debug adapter process exited (code $code) with '
                    'requests still pending.',
                  ),
          );
        }),
      );

      _timing = DebugAdapterTiming(
        adapterId: '${launch.launchArguments['type']}',
        timeout: timeout,
      );
      final sink = _sink!;
      final initialized = Completer<void>();
      _initialized[sink] = initialized;
      _sourcePath = sourcePath;
      _breakpoints = Set<int>.from(breakpoints);
      await request('initialize', {
        'clientID': 'younzcode',
        'clientName': 'YOUNZCODE',
        'adapterID': launch.launchArguments['type'],
        'pathFormat': 'path',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'supportsRunInTerminalRequest': false,
        'supportsStartDebuggingRequest': launch.socketServer,
      });
      final launchRequest = request('launch', launch.launchArguments);
      await initialized.future.timeout(timeout);
      _timing?.markInitialized();
      await _setBreakpoints(sink, sourcePath, breakpoints);
      await request('setExceptionBreakpoints', {'filters': <String>[]});
      await request('configurationDone');
      _configurationDone = true;
      if (_pendingEntryThreadId != null) {
        _pendingEntryThreadId = null;
        await continueExecution();
      }
      await launchRequest;
      _timing?.markLaunch();
    } catch (error) {
      await _failSession('Debug session failed: $error');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final sink = _sink;
    if (_process == null || sink == null) {
      throw StateError('Debug adapter is not running.');
    }
    return _requestOn(sink, command, arguments);
  }

  Future<Map<String, dynamic>> _requestOn(
    IOSink sink,
    String command, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final sequence = _sequence++;
    final pending = _PendingRequest(command: command);
    _pending[sequence] = pending;
    final encodedMessage = jsonEncode({
      'seq': sequence,
      'type': 'request',
      'command': command,
      if (arguments.isNotEmpty) 'arguments': arguments,
    });
    final bytes = utf8.encode(encodedMessage);
    await _writeFrame(sink, bytes);
    return pending.completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(sequence);
        _emitDiagnostics(
          reason:
              'Debug adapter did not answer "$command" within '
              '${timeout.inSeconds}s.',
        );
        throw TimeoutException('Debug adapter did not answer $command.');
      },
    );
  }

  Future<void> continueExecution() async =>
      request('continue', {'threadId': _requiredThread()});

  Future<void> pause() async =>
      request('pause', {'threadId': _requiredThread()});

  Future<void> next() async =>
      request('next', {'threadId': _requiredThread(), 'granularity': 'line'});

  Future<void> stepIn() async =>
      request('stepIn', {'threadId': _requiredThread(), 'granularity': 'line'});

  Future<void> stepOut() async => request('stepOut', {
    'threadId': _requiredThread(),
    'granularity': 'line',
  });

  Future<void> updateBreakpoints(
    String sourcePath,
    Set<int> breakpoints,
  ) async {
    await request('setBreakpoints', {
      'source': {
        'path': sourcePath,
        'name': sourcePath.split(RegExp(r'[/\\]')).last,
      },
      'breakpoints': [
        for (final line in breakpoints.toList()..sort()) {'line': line},
      ],
      'sourceModified': false,
    });
  }

  Future<void> disconnect() async {
    final process = _process;
    final sink = _sink;
    if (process == null || sink == null) return;
    try {
      await request('disconnect', {
        'restart': false,
        'terminateDebuggee': true,
      });
    } catch (_) {
      process.kill();
    }
    await _cleanProcess(process);
  }

  int _requiredThread() {
    final value = _threadId;
    if (value == null) throw StateError('The debugger is not paused.');
    return value;
  }

  void _receiveBytes(IOSink sink, List<int> bytes) {
    final buffer = _buffers.putIfAbsent(sink, () => <int>[]);
    buffer.addAll(bytes);
    while (true) {
      final headerEnd = _indexOf(buffer, const [13, 10, 13, 10]);
      if (headerEnd < 0) return;
      final header = ascii.decode(buffer.sublist(0, headerEnd));
      final match = RegExp(
        r'Content-Length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(header);
      if (match == null) {
        buffer.removeRange(0, headerEnd + 4);
        continue;
      }
      final length = int.parse(match.group(1)!);
      final bodyStart = headerEnd + 4;
      if (buffer.length < bodyStart + length) return;
      final body = utf8.decode(buffer.sublist(bodyStart, bodyStart + length));
      buffer.removeRange(0, bodyStart + length);
      _handleMessage(sink, jsonDecode(body) as Map<String, dynamic>);
    }
  }

  void _handleMessage(IOSink sink, Map<String, dynamic> message) {
    if (message['type'] == 'response') {
      final pending = _pending.remove(message['request_seq']);
      if (pending == null) return;
      final completer = pending.completer;
      if (message['success'] == false) {
        completer.completeError(
          StateError(
            '${message['command']}: ${message['message'] ?? 'request failed'}',
          ),
        );
      } else {
        completer.complete(
          Map<String, dynamic>.from(message['body'] as Map? ?? const {}),
        );
      }
      return;
    }
    if (message['type'] == 'event') {
      final name = '${message['event']}';
      final body = Map<String, dynamic>.from(
        message['body'] as Map? ?? const {},
      );
      if (name == 'initialized') {
        final initialized = _initialized[sink];
        if (initialized != null && !initialized.isCompleted) {
          initialized.complete();
        }
      }
      if (name == 'stopped') {
        _threadId = body['threadId'] as int?;
        if (body['reason'] == 'entry' && _threadId != null) {
          if (!_configurationDone) {
            _pendingEntryThreadId = _threadId;
            return;
          }
          unawaited(
            continueExecution().catchError((Object error) {
              _events.add(
                DebugAdapterEvent('output', {
                  'category': 'stderr',
                  'output': 'Unable to continue after entry: $error',
                }),
              );
            }),
          );
          return;
        }
      }
      if (name == 'continued') _threadId = null;
      _events.add(DebugAdapterEvent(name, body));
      return;
    }
    if (message['type'] == 'request') {
      if (message['command'] == 'startDebugging') {
        unawaited(_startChildSession(sink, message));
      } else if (message['command'] == 'runInTerminal') {
        _respondUnsupported(sink, message);
      }
    }
  }

  Future<void> _startChildSession(
    IOSink parentSink,
    Map<String, dynamic> reverseRequest,
  ) async {
    try {
      final port = _serverPort;
      final sourcePath = _sourcePath;
      if (port == null || sourcePath == null) {
        throw StateError('JavaScript debug server is unavailable.');
      }
      final arguments = Map<String, dynamic>.from(
        reverseRequest['arguments'] as Map? ?? const {},
      );
      final configuration = Map<String, Object?>.from(
        arguments['configuration'] as Map? ?? const {},
      );
      final command = '${arguments['request'] ?? 'launch'}';
      final socket = await Socket.connect('127.0.0.1', port);
      _childSockets.add(socket);
      _buffers[socket] = <int>[];
      _initialized[socket] = Completer<void>();
      _childSubscriptions.add(
        socket.listen((bytes) => _receiveBytes(socket, bytes)),
      );
      await _requestOn(socket, 'initialize', {
        'clientID': 'younzcode',
        'clientName': 'YOUNZCODE',
        'adapterID': configuration['type'],
        'pathFormat': 'path',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'supportsRunInTerminalRequest': false,
        'supportsStartDebuggingRequest': true,
      });
      final launchRequest = _requestOn(socket, command, configuration);
      await _initialized[socket]!.future.timeout(timeout);
      await _setBreakpoints(socket, sourcePath, _breakpoints);
      await _requestOn(socket, 'setExceptionBreakpoints', {
        'filters': <String>[],
      });
      _sink = socket;
      _configurationDone = true;
      await _requestOn(socket, 'configurationDone');
      await _respond(parentSink, reverseRequest, success: true);
      await launchRequest;
    } catch (error) {
      await _respond(
        parentSink,
        reverseRequest,
        success: false,
        message: '$error',
      );
    }
  }

  Future<void> _setBreakpoints(
    IOSink sink,
    String sourcePath,
    Set<int> breakpoints,
  ) => _requestOn(sink, 'setBreakpoints', {
    'source': {
      'path': sourcePath,
      'name': sourcePath.split(RegExp(r'[/\\]')).last,
    },
    'breakpoints': [
      for (final line in breakpoints.toList()..sort()) {'line': line},
    ],
    'sourceModified': false,
  });

  void _respondUnsupported(IOSink sink, Map<String, dynamic> request) {
    if (_process == null) return;
    unawaited(
      _respond(
        sink,
        request,
        success: false,
        message: 'Integrated terminal requests are not supported.',
      ),
    );
  }

  Future<void> _respond(
    IOSink sink,
    Map<String, dynamic> request, {
    required bool success,
    String? message,
  }) {
    final encodedMessage = jsonEncode({
      'seq': _sequence++,
      'type': 'response',
      'request_seq': request['seq'],
      'success': success,
      'command': request['command'],
      'message': ?message,
    });
    final bytes = utf8.encode(encodedMessage);
    return _writeFrame(sink, bytes);
  }

  Future<void> _writeFrame(IOSink sink, List<int> bytes) {
    final operation = _writeTail.then<void>((_) async {
      sink.add(ascii.encode('Content-Length: ${bytes.length}\r\n\r\n'));
      sink.add(bytes);
      await sink.flush();
    });
    _writeTail = operation.catchError((_) {});
    return operation;
  }

  static int _indexOf(List<int> source, List<int> pattern) {
    for (var index = 0; index <= source.length - pattern.length; index++) {
      var matches = true;
      for (var offset = 0; offset < pattern.length; offset++) {
        if (source[index + offset] != pattern[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return index;
    }
    return -1;
  }

  static const _stderrBufferLimit = 60;

  void _appendStderr(String text) {
    for (final line in text.trimRight().split('\n')) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      _stderrBuffer.add(trimmed);
    }
    if (_stderrBuffer.length > _stderrBufferLimit) {
      _stderrBuffer.removeRange(0, _stderrBuffer.length - _stderrBufferLimit);
    }
  }

  /// Periodic health check: if the adapter process has already exited while
  /// requests are still in flight, fail the session right away with
  /// diagnostics instead of waiting for the per-request timeout to expire.
  void _watchdogTick() {
    if (!_processExited || _pending.isEmpty || _process == null) return;
    final exitCode = _processExitCode;
    unawaited(
      _failSession(
        'The debug adapter process exited (code $exitCode) while requests '
        'were still pending.',
      ),
    );
  }

  /// Emits a 'diagnostics' event carrying the adapter's stderr tail and the
  /// in-flight request details, so the UI can explain why a session failed.
  /// Emitted at most once per session.
  void _emitDiagnostics({required String reason}) {
    if (_events.isClosed || _diagnosticsEmitted) return;
    _diagnosticsEmitted = true;
    _events.add(
      DebugAdapterEvent('diagnostics', {
        'reason': reason,
        'stderr': List<String>.from(_stderrBuffer),
        'pending': [
          for (final entry in _pending.entries)
            {
              'seq': entry.key,
              'command': entry.value.command,
              'elapsedMs': DateTime.now()
                  .difference(entry.value.startedAt)
                  .inMilliseconds,
            },
        ],
        'exitCode': _processExitCode,
        'timing': _timing?.toJson(),
      }),
    );
  }

  /// Tears a failed session down after surfacing a diagnostics event.
  Future<void> _failSession(String reason) async {
    _emitDiagnostics(reason: reason);
    await _cleanProcess();
  }

  Future<void> _cleanProcess([Process? expectedProcess]) async {
    if (_cleaning) return;
    final process = _process;
    if (expectedProcess != null && !identical(process, expectedProcess)) return;
    _cleaning = true;
    _process = null;
    _processExited = false;
    _processExitCode = null;
    _watchdog?.cancel();
    _watchdog = null;
    _stderrBuffer.clear();
    final stdoutSubscription = _stdoutSubscription;
    final stderrSubscription = _stderrSubscription;
    final socket = _socket;
    final childSockets = List<Socket>.from(_childSockets);
    final childSubscriptions = List<StreamSubscription<List<int>>>.from(
      _childSubscriptions,
    );
    _sink = null;
    _threadId = null;
    _pendingEntryThreadId = null;
    _configurationDone = false;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _socket = null;
    _serverPort = null;
    _sourcePath = null;
    _breakpoints = const {};
    _childSockets.clear();
    _childSubscriptions.clear();
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('Debug adapter stopped.'));
      }
    }
    _pending.clear();
    _buffers.clear();
    _initialized.clear();
    _writeTail = Future<void>.value();
    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();
    for (final subscription in childSubscriptions) {
      await subscription.cancel();
    }
    for (final childSocket in childSockets) {
      await childSocket.close();
    }
    await socket?.close();
    if (process != null) await _terminateProcessTree(process);
    _cleaning = false;
  }

  static Future<void> _terminateProcessTree(Process process) async {
    final exitCode = process.exitCode;
    if (Platform.isWindows) {
      try {
        await Process.run(
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
          r'\System32\taskkill.exe',
          ['/PID', '${process.pid}', '/T', '/F'],
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    } else {
      process.kill(ProcessSignal.sigkill);
    }
    await exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    if (Platform.isWindows) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}
