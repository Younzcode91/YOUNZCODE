import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reference update-ping collector. Fleet telemetry endpoint that the app's
/// UpdatePingService POSTs installed versions to; the retire gate consumes
/// /export.csv to measure true adoption instead of the nightly-run proxy.
///
/// Usage:
///   dart run tool/ping_server.dart [--data <file>] [--port <n>]
///                                   [--host <addr>] [--max-lifetime <sec>]
///
/// Endpoints:
///   POST /ping       body: {"version","channel","os","install_id",
///                          "timestamp"} — validated, appended to the JSONL
///                          data file. 400 on invalid payload.
///   GET  /export.csv header + rows (timestamp,version,channel,os,install_id)
///   GET  /health     "ok"
///
/// Deploy anywhere `dart` runs (a small VM/container), put the public HTTPS
/// URL in lib/services/update_ping_service.dart (`updatePingEndpointUrl` +
/// `updatePingAllowedHosts`), and point the ping-collect workflow at it.
Future<void> main(List<String> args) async {
  var dataPath = 'ping_data.jsonl';
  var port = 8787;
  var host = InternetAddress.anyIPv4;
  var maxLifetimeSeconds = 0;
  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--data':
        if (index + 1 >= args.length) {
          stderr.writeln('--data membutuhkan path file.');
          exitCode = 1;
          return;
        }
        dataPath = args[++index];
      case '--port':
        if (index + 1 >= args.length) {
          stderr.writeln('--port membutuhkan angka.');
          exitCode = 1;
          return;
        }
        port = int.tryParse(args[++index]) ?? 8787;
      case '--host':
        if (index + 1 >= args.length) {
          stderr.writeln('--host membutuhkan alamat.');
          exitCode = 1;
          return;
        }
        host =
            InternetAddress.tryParse(args[++index]) ?? InternetAddress.anyIPv4;
      case '--max-lifetime':
        if (index + 1 >= args.length) {
          stderr.writeln('--max-lifetime membutuhkan angka.');
          exitCode = 1;
          return;
        }
        maxLifetimeSeconds = int.tryParse(args[++index]) ?? 0;
      default:
        stderr.writeln('Argumen tidak dikenal: ${args[index]}');
        exitCode = 1;
        return;
    }
  }

  final dataFile = File(dataPath);
  final server = await HttpServer.bind(host, port);
  stdout.writeln('Ping collector listening on ${server.address.address}:$port');
  stdout.writeln('Data file: ${dataFile.absolute.path}');
  if (maxLifetimeSeconds > 0) {
    // Self-terminate after the lifetime (safety net for tests/CI so a leaked
    // server process can never linger forever).
    Timer(Duration(seconds: maxLifetimeSeconds), () {
      server.close();
      stdout.writeln('Lifetime expired - shutting down.');
    });
  }

  await for (final request in server) {
    try {
      await _handle(request, dataFile);
    } catch (_) {
      _respond(request, 500, 'internal error');
    }
  }
}

Future<void> _handle(HttpRequest request, File dataFile) async {
  final path = request.uri.path;
  if (request.method == 'POST' && path == '/ping') {
    await _handlePing(request, dataFile);
  } else if (request.method == 'GET' && path == '/export.csv') {
    await _handleExport(request, dataFile);
  } else if (request.method == 'GET' && path == '/health') {
    _respond(request, 200, 'ok');
  } else {
    _respond(request, 404, 'not found');
  }
}

Future<void> _handlePing(HttpRequest request, File dataFile) async {
  final body = await utf8.decoder.bind(request).join();
  Map<String, dynamic> payload;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    payload = decoded;
  } catch (_) {
    _respond(request, 400, 'invalid JSON body');
    return;
  }
  final version = '${payload['version'] ?? ''}'.trim();
  final installId = '${payload['install_id'] ?? ''}'.trim();
  if (version.isEmpty || installId.isEmpty) {
    _respond(request, 400, 'version and install_id are required');
    return;
  }
  final timestamp =
      DateTime.tryParse(
        '${payload['timestamp'] ?? ''}',
      )?.toUtc().toIso8601String() ??
      DateTime.now().toUtc().toIso8601String();
  final row = jsonEncode({
    'timestamp': timestamp,
    'version': version,
    'channel': '${payload['channel'] ?? ''}',
    'os': '${payload['os'] ?? ''}',
    'install_id': installId,
  });
  await dataFile.parent.create(recursive: true);
  await dataFile.writeAsString('$row\n', mode: FileMode.append, flush: true);
  _respond(request, 200, 'accepted');
}

Future<void> _handleExport(HttpRequest request, File dataFile) async {
  final lines = <String>['timestamp,version,channel,os,install_id'];
  if (dataFile.existsSync()) {
    for (final line in dataFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final row = jsonDecode(trimmed) as Map<String, dynamic>;
        // CSV-escape the fields defensively (telemetry values are app-owned).
        String csv(String value) => value.contains(RegExp(r'[",\n]'))
            ? '"${value.replaceAll('"', '""')}"'
            : value;
        lines.add(
          '${csv('${row['timestamp'] ?? ''}')},'
          '${csv('${row['version'] ?? ''}')},'
          '${csv('${row['channel'] ?? ''}')},'
          '${csv('${row['os'] ?? ''}')},'
          '${csv('${row['install_id'] ?? ''}')}',
        );
      } catch (_) {
        // Skip corrupt rows instead of breaking the export.
      }
    }
  }
  _respond(request, 200, '${lines.join('\n')}\n', contentType: 'text/csv');
}

void _respond(
  HttpRequest request,
  int status,
  String body, {
  String contentType = 'text/plain',
}) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.parse(contentType)
    ..write(body);
  request.response.close();
}
