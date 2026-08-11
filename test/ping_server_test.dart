import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'tool_runner.dart';

/// Walks up from the test CWD until the package root (pubspec.yaml) is found.
String _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

void main() {
  test('ping server E2E: POST /ping masuk ke /export.csv', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-pingserver-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final dataFile = File('${root.path}${sep}ping_data.jsonl');

    // Grab a free port, then hand it to the server subprocess.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final (executable, arguments) = toolLaunch('tool/ping_server.dart', [
      '--data',
      dataFile.path,
      '--port',
      '$port',
      '--host',
      '127.0.0.1',
      '--max-lifetime',
      '120',
    ]);
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: _packageRoot(),
      runInShell: false,
    );
    addTearDown(() async {
      // Kill the whole tree: on Windows the dart.exe launcher spawns a child
      // VM that survives a plain kill. taskkill /T covers the tree; POSIX
      // sigkill hits the direct process (no wrapper). The --max-lifetime flag
      // is the final safety net either way.
      if (Platform.isWindows) {
        try {
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        } catch (_) {}
      } else {
        process.kill(ProcessSignal.sigkill);
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        // Process already gone.
      }
    });

    final base = 'http://127.0.0.1:$port';
    var healthy = false;
    for (var attempt = 0; attempt < 30 && !healthy; attempt++) {
      try {
        final response = await http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 1));
        healthy = response.statusCode == 200;
      } catch (_) {}
      if (!healthy) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    expect(healthy, isTrue, reason: 'server tidak sehat');

    // Valid ping diterima.
    final ping = await http.post(
      Uri.parse('$base/ping'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'version': '1.3.6',
        'channel': 'stable',
        'os': 'windows',
        'install_id': 'install-a',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    expect(ping.statusCode, 200);

    // Payload tanpa version/install_id ditolak.
    final bad = await http.post(
      Uri.parse('$base/ping'),
      body: jsonEncode({'os': 'windows'}),
    );
    expect(bad.statusCode, 400);

    // Export memuat baris ping + header.
    final export = await http.get(Uri.parse('$base/export.csv'));
    expect(export.statusCode, 200);
    expect(export.body, startsWith('timestamp,version,channel,os,install_id'));
    expect(export.body, contains('1.3.6'));
    expect(export.body, contains('install-a'));

    // Data juga tersimpan di file JSONL.
    expect(await dataFile.readAsString(), contains('install-a'));
  });
}
