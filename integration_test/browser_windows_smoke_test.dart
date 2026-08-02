import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kode_agent_desktop/services/browser_agent_service.dart';
import 'package:webview_windows/webview_windows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'WebView2 browser agent reads, types, clicks, and screenshots',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('''
<!doctype html>
<html>
<head><title>Agent Browser Smoke Test</title></head>
<body>
  <h1>Local project preview</h1>
  <label>Name <input aria-label="Name" value=""></label>
  <button onclick="
    document.querySelector('#result').textContent =
      'Hello ' + document.querySelector('input').value
  ">Update preview</button>
  <p id="result">Waiting</p>
</body>
</html>
''');
        await request.response.close();
      });
      final service = BrowserAgentService();
      final screenshotDirectory = await Directory.systemTemp.createTemp(
        'younz-browser-smoke-',
      );
      addTearDown(() async {
        await service.shutdown();
        await server.close(force: true);
        await requests.cancel();
        await screenshotDirectory.delete(recursive: true);
      });

      await service.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Webview(
              service.controller!,
              permissionRequested: (_, _, _) async =>
                  WebviewPermissionDecision.deny,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await service.openUrl('http://127.0.0.1:${server.port}');
      await _waitForPage(service, tester);
      final initial = await service.readPage();
      expect(initial.title, 'Agent Browser Smoke Test');
      expect(initial.text, contains('Local project preview'));

      final inputRef = _refContaining(initial.elements, 'Name');
      final buttonRef = _refContaining(initial.elements, 'Update preview');
      await service.typeText(inputRef, 'Codex', clear: true, submit: false);
      await service.click(buttonRef);
      await tester.pump(const Duration(milliseconds: 250));

      final updated = await service.readPage();
      expect(updated.text, contains('Hello Codex'));
      final screenshot = await service.takeScreenshot(screenshotDirectory.path);
      expect(await File(screenshot).exists(), isTrue);
      expect(await File(screenshot).length(), greaterThan(1000));
    },
    skip: !Platform.isWindows,
  );
}

Future<void> _waitForPage(
  BrowserAgentService service,
  WidgetTester tester,
) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!service.state.loading &&
        service.currentUrl.startsWith('http://127.0.0.1:')) {
      return;
    }
  }
  throw TestFailure('Browser preview tidak selesai dimuat.');
}

String _refContaining(List<String> elements, String text) {
  final line = elements.firstWhere(
    (element) => element.toLowerCase().contains(text.toLowerCase()),
  );
  final match = RegExp(r'\[ref=([^\]]+)\]').firstMatch(line);
  if (match == null) throw TestFailure('Ref tidak ditemukan untuk "$text".');
  return match.group(1)!;
}
