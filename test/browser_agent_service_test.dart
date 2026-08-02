import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/approval_mode.dart';
import 'package:kode_agent_desktop/services/browser_agent_service.dart';
import 'package:kode_agent_desktop/services/workspace_tools.dart';

void main() {
  group('BrowserAgentService URL policy', () {
    test('menambahkan HTTPS untuk host publik', () async {
      final result = await BrowserAgentService.normalizeAndValidateUrl(
        'example.com/docs',
        hostLookup: (_) async => [InternetAddress('93.184.216.34')],
      );

      expect(result.toString(), 'https://example.com/docs');
    });

    test('mengizinkan HTTP hanya untuk localhost preview', () async {
      var lookupCalled = false;
      final result = await BrowserAgentService.normalizeAndValidateUrl(
        'localhost:4173',
        hostLookup: (_) async {
          lookupCalled = true;
          return [];
        },
      );

      expect(result.toString(), 'http://localhost:4173');
      expect(lookupCalled, isFalse);
    });

    test('menolak HTTP publik dan host yang resolve ke private IP', () async {
      await expectLater(
        BrowserAgentService.normalizeAndValidateUrl(
          'http://example.com',
          hostLookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        throwsA(isA<BrowserUrlPolicyException>()),
      );
      await expectLater(
        BrowserAgentService.normalizeAndValidateUrl(
          'https://example.com',
          hostLookup: (_) async => [InternetAddress('192.168.1.4')],
        ),
        throwsA(isA<BrowserUrlPolicyException>()),
      );
    });

    test('menolak kredensial yang ditanam dalam URL', () async {
      await expectLater(
        BrowserAgentService.normalizeAndValidateUrl(
          'https://user:password@example.com',
          hostLookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        throwsA(isA<BrowserUrlPolicyException>()),
      );
    });
  });

  group('WorkspaceTools browser approval', () {
    test('mendaftarkan tool browser ketika service tersedia', () async {
      final root = await Directory.systemTemp.createTemp('younz-browser-');
      addTearDown(() => root.delete(recursive: true));
      final tools = _browserTools(root, _FakeBrowser());

      final definitions = await tools.initializeAndDefinitions();
      final names = definitions
          .map(
            (definition) =>
                (definition['function']! as Map<String, Object>)['name'],
          )
          .toSet();

      expect(
        names,
        containsAll([
          'browser_open',
          'browser_read',
          'browser_click',
          'browser_type',
          'browser_upload',
          'browser_screenshot',
        ]),
      );
    });

    test('read halaman aman berjalan tanpa popup approval', () async {
      final root = await Directory.systemTemp.createTemp('younz-browser-');
      addTearDown(() => root.delete(recursive: true));
      final browser = _FakeBrowser();
      var permissionAsked = false;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          permissionAsked = true;
          return PermissionDecision.reject;
        },
        allowWrite: false,
        allowTerminal: false,
        approvalMode: ApprovalMode.askForApproval,
        environment: const {},
        browser: browser,
      );

      expect(
        await tools.execute('browser_read', const {}),
        contains('Project content'),
      );
      expect(permissionAsked, isFalse);
      expect(browser.readCount, 1);
    });

    test('klik aman berjalan tanpa popup approval', () async {
      final root = await Directory.systemTemp.createTemp('younz-browser-');
      addTearDown(() => root.delete(recursive: true));
      final browser = _FakeBrowser(
        element: const BrowserElementInfo(
          ref: 'e1',
          tag: 'button',
          text: 'Next page',
          type: 'button',
          href: '',
          editable: false,
        ),
      );
      var permissionAsked = false;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          permissionAsked = true;
          return PermissionDecision.reject;
        },
        allowWrite: false,
        allowTerminal: false,
        approvalMode: ApprovalMode.askForApproval,
        environment: const {},
        browser: browser,
      );

      expect(await tools.execute('browser_click', {'ref': 'e1'}), 'clicked');
      expect(permissionAsked, isFalse);
      expect(browser.clickedRefs, ['e1']);
    });

    test('delete tetap meminta approval pada fullAccess', () async {
      final root = await Directory.systemTemp.createTemp('younz-browser-');
      addTearDown(() => root.delete(recursive: true));
      final browser = _FakeBrowser(
        element: const BrowserElementInfo(
          ref: 'e1',
          tag: 'button',
          text: 'Delete project',
          type: 'button',
          href: '',
          editable: false,
        ),
      );
      var permissionAsked = false;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, detail) async {
          permissionAsked = detail.contains('important-action');
          return PermissionDecision.reject;
        },
        allowWrite: true,
        allowTerminal: true,
        approvalMode: ApprovalMode.fullAccess,
        environment: const {},
        browser: browser,
      );

      expect(
        await tools.execute('browser_click', {'ref': 'e1'}),
        'Ditolak oleh pengguna.',
      );
      expect(permissionAsked, isTrue);
      expect(browser.clickedRefs, isEmpty);
    });

    test('upload dibatasi ke file workspace dan selalu eksplisit', () async {
      final root = await Directory.systemTemp.createTemp('younz-browser-');
      final outside = await Directory.systemTemp.createTemp(
        'younz-browser-outside-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      final insideFile = File(
        '${root.path}${Platform.pathSeparator}artifact.zip',
      );
      final outsideFile = File(
        '${outside.path}${Platform.pathSeparator}secret.txt',
      );
      await insideFile.writeAsString('artifact');
      await outsideFile.writeAsString('secret');
      final browser = _FakeBrowser();
      var approvalCount = 0;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          approvalCount++;
          return PermissionDecision.allowOnce;
        },
        allowWrite: true,
        allowTerminal: true,
        approvalMode: ApprovalMode.fullAccess,
        environment: const {},
        browser: browser,
      );

      await expectLater(
        tools.execute('browser_upload', {
          'ref': 'e2',
          'paths': [outsideFile.path],
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(approvalCount, 0);

      await tools.execute('browser_upload', {
        'ref': 'e2',
        'paths': ['artifact.zip'],
      });
      expect(approvalCount, 1);
      expect(
        browser.uploadedPaths.single,
        await insideFile.resolveSymbolicLinks(),
      );
    });
  });
}

WorkspaceTools _browserTools(Directory root, BrowserAutomation browser) {
  return WorkspaceTools(
    root: root.path,
    requestPermission: (_, _) async => PermissionDecision.allowOnce,
    allowWrite: true,
    allowTerminal: true,
    environment: const {},
    browser: browser,
  );
}

class _FakeBrowser implements BrowserAutomation {
  _FakeBrowser({
    this.element = const BrowserElementInfo(
      ref: 'e2',
      tag: 'input',
      text: 'Upload file',
      type: 'file',
      href: '',
      editable: true,
    ),
  });

  final BrowserElementInfo element;
  final List<String> clickedRefs = [];
  final List<String> uploadedPaths = [];
  int readCount = 0;

  @override
  String get currentUrl => 'https://example.com/project';

  @override
  bool get isInitialized => true;

  @override
  Future<String> click(String ref) async {
    clickedRefs.add(ref);
    return 'clicked';
  }

  @override
  Future<BrowserElementInfo> describeElement(String ref) async => element;

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> openUrl(String rawUrl, {String? downloadDirectory}) async {}

  @override
  Future<BrowserPageSnapshot> readPage({int maxCharacters = 12000}) async {
    readCount++;
    return const BrowserPageSnapshot(
      url: 'https://example.com/project',
      title: 'Project',
      text: 'Project content',
      elements: ['[ref=e1] <button> "Delete project"'],
    );
  }

  @override
  Future<void> reload() async {}

  @override
  Future<String> takeScreenshot(
    String outputDirectory, {
    bool fullPage = false,
  }) async {
    return '$outputDirectory${Platform.pathSeparator}browser.png';
  }

  @override
  Future<String> typeText(
    String ref,
    String text, {
    bool clear = true,
    bool submit = false,
  }) async {
    return 'typed';
  }

  @override
  Future<String> uploadFiles(String ref, List<String> filePaths) async {
    uploadedPaths.addAll(filePaths);
    return 'uploaded';
  }
}
