import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/main.dart';
import 'package:kode_agent_desktop/lottie_support.dart';
import 'package:kode_agent_desktop/models/chat_entry.dart';
import 'package:kode_agent_desktop/models/chat_session.dart';
import 'package:kode_agent_desktop/models/agent_goal.dart';
import 'package:kode_agent_desktop/services/chat_session_store.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpLoaded(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int attempts = 20,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _setMockPreferences(Map<String, Object> values) {
  SharedPreferences.setMockInitialValues({
    'onboarding_complete': true,
    ...values,
  });
}

void main() {
  testWidgets('aset loader Lottie dapat didekode', (tester) async {
    final assetData = await rootBundle.load(
      'assets/younzcode_cat_loading.lottie',
    );
    final composition = await decodeDotLottie(
      assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      ),
    );

    expect(composition, isNotNull);
    expect(composition!.bounds.width, 280);
    expect(composition.bounds.height, 200);
    expect(composition.layers, hasLength(11));

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('test-lottie-loader'),
            child: SizedBox(
              width: 280,
              height: 200,
              child: Lottie.asset(
                'assets/younzcode_cat_loading.lottie',
                decoder: decodeDotLottie,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('test-lottie-loader')), findsOneWidget);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('test-lottie-loader')),
    );
    final pixels = await tester.runAsync(() async {
      final renderedImage = await boundary.toImage();
      final byteData = await renderedImage.toByteData();
      renderedImage.dispose();
      return byteData!.buffer.asUint8List();
    });
    final renderedPixels = pixels!;
    var paintedPixels = 0;
    for (
      var alphaIndex = 3;
      alphaIndex < renderedPixels.length;
      alphaIndex += 4
    ) {
      if (renderedPixels[alphaIndex] > 0) paintedPixels++;
    }
    expect(paintedPixels, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('menampilkan layar utama agent', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(find.text('YOUNZCODE'), findsOneWidget);
    expect(find.byKey(const ValueKey('command-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('top-workspace-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-explorer')), findsOneWidget);
    expect(find.textContaining('Build: v1.3.6'), findsOneWidget);
    expect(find.text('AGENT SESSION'), findsNothing);
    expect(find.text('YOUNZCODE DESKTOP'), findsNothing);
    expect(find.byKey(const ValueKey('model-selector')), findsOneWidget);
    expect(find.text('MANAGE MODELS'), findsOneWidget);
    expect(find.text('WORKSPACE'), findsWidgets);
    expect(find.text('What are we building?'), findsOneWidget);
    expect(find.text('Explain Codebase'), findsOneWidget);
    expect(find.text('ACTIVITY'), findsOneWidget);
  });

  testWidgets('membuka playground Image Generation dari command rail', (
    tester,
  ) async {
    _setMockPreferences({
      'base_url': 'http://localhost:20128',
      'model': 'cx/gpt-5.5-image',
      'models': ['cx/gpt-5.5-image'],
    });
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.byKey(const ValueKey('rail-images')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('image-generation-view')), findsOneWidget);
    expect(find.text('IMAGE GENERATION'), findsOneWidget);
    expect(
      find.text('http://127.0.0.1:20128/v1/images/generations'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('image-run')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('image-prompt')),
      'A cute cat wearing a hat',
    );
    await tester.pump();
    final runButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('image-run')),
    );
    expect(runButton.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing persisted workspace does not leave startup loading', (
    tester,
  ) async {
    _setMockPreferences({
      'workspace':
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'missing-younzcode-workspace',
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('prompt-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('membuka project settings lengkap', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.byKey(const ValueKey('rail-settings')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECT SETTINGS'), findsOneWidget);
    expect(find.text('GENERAL'), findsWidgets);
    expect(find.text('ENV VARIABLES'), findsOneWidget);
    expect(find.text('PERMISSIONS'), findsOneWidget);
    expect(find.text('SECURITY'), findsOneWidget);
    expect(find.text('API'), findsOneWidget);
  });

  testWidgets('Enter mengirim dan Shift+Enter membuat baris baru', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final field = find.byKey(const ValueKey('prompt-field'));
    await tester.tap(field);
    await tester.enterText(field, 'baris pertama');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.enterText(field, 'baris pertama\nbaris kedua');

    final input = tester.widget<TextField>(field);
    expect(input.controller!.text, 'baris pertama\nbaris kedua');
    expect(
      find.text('Pilih folder workspace yang valid terlebih dahulu.'),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      find.text('Pilih folder workspace yang valid terlebih dahulu.'),
      findsOneWidget,
    );
  });

  testWidgets('tombol kirim berada di dalam area prompt', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final promptRect = tester.getRect(
      find.byKey(const ValueKey('prompt-field')),
    );
    final sendRect = tester.getRect(find.byKey(const ValueKey('send-agent')));

    expect(promptRect.contains(sendRect.center), isTrue);
    expect(sendRect.height, closeTo(44, 0.5));
    expect(
      find.text('Enter to send · Shift+Enter for new line'),
      findsOneWidget,
    );
  });

  testWidgets('slash command menu menampilkan bantuan lokal', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final field = find.byKey(const ValueKey('prompt-field'));
    await tester.enterText(field, '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
    for (final command in const [
      '/graphify',
      '/mcp',
      '/review',
      '/fork',
      '/model',
      '/share',
      '/open',
      '/skill',
    ]) {
      expect(find.text(command), findsOneWidget);
    }
    expect(find.text('/help'), findsOneWidget);
    expect(find.text('/terminal'), findsOneWidget);

    final helpCommand = find.byKey(const ValueKey('slash-command-help'));
    await tester.ensureVisible(helpCommand);
    await tester.pumpAndSettle();
    await tester.tap(helpCommand);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Slash commands:'), findsOneWidget);
    expect(
      find.text('Pilih folder workspace yang valid terlebih dahulu.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command review dan fork berfungsi lokal', (tester) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-command-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'command-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 25),
        entries: const [ChatEntry(role: ChatRole.user, content: 'Pesan awal')],
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final field = find.byKey(const ValueKey('prompt-field'));
    await tester.tap(field);
    await tester.enterText(field, '/review');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Tidak ada perubahan agent'), findsOneWidget);

    await tester.enterText(field, '/fork');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Chat di-fork'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command model mcp dan skill membuka manager', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);
    final field = find.byKey(const ValueKey('prompt-field'));

    await tester.tap(field);
    await tester.enterText(field, '/model');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MODEL CONNECTION'), findsOneWidget);
    await tester.tap(find.byTooltip('Tutup'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(field);
    await tester.enterText(field, '/mcp');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ADD-ON MANAGER'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-addon-manager')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(field);
    await tester.enterText(field, '/skill');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ADD-ON MANAGER'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command share menyalin percakapan', (tester) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-command-share-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'share-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 25),
        entries: const [ChatEntry(role: ChatRole.user, content: 'Bagikan ini')],
      ),
    ]);
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);
    final field = find.byKey(const ValueKey('prompt-field'));

    await tester.tap(field);
    await tester.enterText(field, '/share');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(copiedText, contains('Bagikan ini'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command graphify memvalidasi workspace', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);
    final field = find.byKey(const ValueKey('prompt-field'));

    await tester.tap(field);
    await tester.enterText(field, '/graphify');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.text('Pilih workspace sebelum menjalankan Graphify.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command plan dieksekusi tanpa dikirim ke model', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final field = find.byKey(const ValueKey('prompt-field'));
    await tester.tap(field);
    await tester.enterText(field, '/plan');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.textContaining('READ-ONLY'), findsOneWidget);
    expect(
      find.text('Pilih folder workspace yang valid terlebih dahulu.'),
      findsNothing,
    );
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash command goal tanpa objective menampilkan bantuan', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final field = find.byKey(const ValueKey('prompt-field'));
    await tester.tap(field);
    await tester.enterText(field, '/goal');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      find.textContaining(
        'Belum ada goal. Gunakan "/goal tujuan yang ingin diselesaikan".',
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'goal tersimpan dipulihkan sebagai banner yang dapat dilanjutkan',
    (tester) async {
      final workspace = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('younzcode-goal-'),
      ))!;
      addTearDown(
        () => tester.runAsync(() => workspace.delete(recursive: true)),
      );
      _setMockPreferences({'workspace': workspace.path});
      await ChatSessionStore().save([
        ChatSession(
          id: 'goal-session',
          workspace: workspace.path,
          updatedAt: DateTime(2026, 7, 29),
          entries: const [
            ChatEntry(
              role: ChatRole.user,
              content: '/goal selesaikan aplikasi',
            ),
          ],
          goal: AgentGoal(
            objective: 'Selesaikan aplikasi sampai seluruh test lulus',
            status: AgentGoalStatus.paused,
            turnCount: 2,
            updatedAt: DateTime(2026, 7, 29),
          ),
        ),
      ]);
      await tester.binding.setSurfaceSize(const Size(1400, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const KodeAgentApp());
      await _pumpLoaded(tester);

      expect(find.byKey(const ValueKey('goal-banner')), findsOneWidget);
      expect(find.text('GOAL PAUSED · 2 TURN'), findsOneWidget);
      expect(
        find.text('Selesaikan aplikasi sampai seluruh test lulus'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('goal-resume')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('workspace tree memiliki folder dan file yang dapat dibaca', () async {
    final workspace = await Directory.systemTemp.createTemp('younzcode-tree-');
    await Directory('${workspace.path}${Platform.pathSeparator}lib').create();
    await File(
      '${workspace.path}${Platform.pathSeparator}README.md',
    ).writeAsString('# Project');
    await File(
      '${workspace.path}${Platform.pathSeparator}lib${Platform.pathSeparator}main.dart',
    ).writeAsString('void main() {}');
    addTearDown(() => workspace.delete(recursive: true));

    final rootEntries = await Directory(workspace.path).list().toList();
    final libEntries = await Directory(
      '${workspace.path}${Platform.pathSeparator}lib',
    ).list().toList();
    expect(
      rootEntries.any((entry) => entry.path.endsWith('README.md')),
      isTrue,
    );
    expect(rootEntries.any((entry) => entry.path.endsWith('lib')), isTrue);
    expect(libEntries.single.path.endsWith('main.dart'), isTrue);
  });

  testWidgets('model manager dapat menambahkan model baru', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);
    expect(tester.takeException(), isNull, reason: 'main layout');

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'model dialog');
    expect(find.text('MODEL CONNECTION'), findsOneWidget);
    expect(find.text('gpt-4.1-mini'), findsWidgets);

    await tester.enterText(
      find.widgetWithText(TextField, 'Model ID, contoh gpt-4.1'),
      'gpt-4.1',
    );
    final addModel = find.text('ADD MODEL');
    await tester.ensureVisible(addModel);
    await tester.pumpAndSettle();
    await tester.tap(addModel);
    await tester.pump();
    expect(find.text('gpt-4.1'), findsOneWidget);
  });

  testWidgets('preset provider mengisi Base URL dan model contoh', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();
    expect(find.text('MODEL CONNECTION'), findsOneWidget);
    expect(find.byKey(const ValueKey('provider-preset')), findsOneWidget);
    expect(find.byKey(const ValueKey('fetch-models-button')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('model-api-key-field'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('fetch-models-button'))).dy,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('provider-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Gemini (OpenAI-compatible)').last);
    await tester.pumpAndSettle();

    // Base URL auto-filled and example models loaded.
    expect(
      find.text('https://generativelanguage.googleapis.com/v1beta/openai'),
      findsOneWidget,
    );
    expect(find.text('gemini-2.5-pro'), findsWidgets);
  });

  testWidgets('preset Anthropic native mengisi Base URL dan model native', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic Claude (native)').last);
    await tester.pumpAndSettle();

    expect(find.text('https://api.anthropic.com'), findsOneWidget);
    expect(find.text('claude-opus-4-8'), findsWidgets);
  });

  testWidgets('preset AgentRouter memakai endpoint milik akun pengguna', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AgentRouter (OpenAI-compatible)').last);
    await tester.pumpAndSettle();

    expect(find.text('https://agentrouter.org/v1'), findsOneWidget);
    expect(find.text('gpt-5.5'), findsWidgets);
  });

  testWidgets(
    'fetch provider internet tanpa API key dihentikan sebelum request',
    (tester) async {
      _setMockPreferences({});
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const KodeAgentApp());
      await _pumpLoaded(tester);

      await _pumpUntilFound(tester, find.text('MANAGE MODELS'));
      await tester.tap(find.text('MANAGE MODELS'));
      await tester.pumpAndSettle();
      final fetchButton = find.byKey(const ValueKey('fetch-models-button'));
      await tester.ensureVisible(fetchButton);
      await tester.tap(fetchButton);
      await tester.pump();

      expect(
        find.textContaining('Isi API KEY terlebih dahulu'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'preset 9router mengisi Base URL loopback tanpa menghapus model',
    (tester) async {
      _setMockPreferences({});
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const KodeAgentApp());
      await _pumpLoaded(tester);

      await _pumpUntilFound(tester, find.text('MANAGE MODELS'));
      await tester.tap(find.text('MANAGE MODELS'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9router (lokal)').last);
      await tester.pumpAndSettle();

      expect(find.text('http://127.0.0.1:20128/v1'), findsWidgets);
      // Preset with no example models keeps the existing model list.
      expect(find.text('gpt-4.1-mini'), findsWidgets);
    },
  );

  testWidgets('Cancel menutup model manager tanpa error', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(find.text('MODEL CONNECTION'), findsNothing);
    expect(find.text('YOUNZCODE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('X menutup model manager tanpa black screen', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Tutup'));
    await tester.pumpAndSettle();

    expect(find.text('MODEL CONNECTION'), findsNothing);
    expect(find.text('YOUNZCODE'), findsOneWidget);
    final layoutError = tester.takeException();
    if (layoutError != null) throw layoutError;
  });

  testWidgets('model manager dapat discroll pada jendela pendek', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(900, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();

    expect(find.text('MODEL CONNECTION'), findsOneWidget);
    expect(find.text('SAVE MODELS'), findsOneWidget);
    final dialogScroll = find.byKey(const ValueKey('model-dialog-scroll'));
    expect(dialogScroll, findsOneWidget);
    await tester.drag(dialogScroll, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'model dialog scroll');
    expect(find.byKey(const ValueKey('model-api-key-field')), findsOneWidget);
    expect(find.text('API KEY'), findsOneWidget);
  });

  testWidgets('model manager mengikuti tinggi konten pada jendela tinggi', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('model-dialog-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).height, lessThan(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool activity dapat disembunyikan dan ditampilkan kembali', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(find.text('NO ACTIVITY DETECTED'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hide-activity-panel')));
    await tester.pumpAndSettle();

    expect(find.text('NO ACTIVITY DETECTED'), findsNothing);
    expect(find.byKey(const ValueKey('show-activity-panel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('show-activity-panel')));
    await tester.pumpAndSettle();
    expect(find.text('NO ACTIVITY DETECTED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel explorer dan inspector dapat diubah ukurannya', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final explorer = find.byKey(const ValueKey('workspace-explorer'));
    final inspector = find.byKey(const ValueKey('activity-panel'));
    final explorerBefore = tester.getSize(explorer).width;
    final inspectorBefore = tester.getSize(inspector).width;

    await tester.drag(
      find.byKey(const ValueKey('explorer-resize-handle')),
      const Offset(60, 0),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('inspector-resize-handle')),
      const Offset(-40, 0),
    );
    await tester.pump();

    expect(tester.getSize(explorer).width, greaterThan(explorerBefore));
    expect(tester.getSize(inspector).width, greaterThan(inspectorBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('explorer dapat disembunyikan dan ditampilkan kembali', (
    tester,
  ) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final explorer = find.byKey(const ValueKey('workspace-explorer'));
    expect(explorer, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hide-explorer-panel')));
    await tester.pump();
    expect(explorer, findsNothing);

    await tester.tap(find.text('Explorer'));
    await tester.pump();
    expect(explorer, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notification dapat dibuka dan dihapus', (tester) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-notification-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.byKey(const ValueKey('restricted-mode-action')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('trust-current-workspace')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('notifications-button')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Workspace trusted'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notification-item-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('notification-detail')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-notification-0')));
    await tester.pump();
    expect(find.text('No notifications.'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification-detail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('.env dapat dibuka lokal setelah konfirmasi', (tester) async {
    final workspace = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('younzcode-env-');
      await File(
        '${directory.path}${Platform.pathSeparator}.env',
      ).writeAsString('SECRET=local-only');
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final environmentFile = find.text('.env');
    await _pumpUntilFound(tester, environmentFile);
    await tester.tap(environmentFile);
    await tester.pumpAndSettle();
    expect(find.text('Buka file environment?'), findsOneWidget);
    expect(find.text('BUKA LOKAL'), findsOneWidget);

    await tester.tap(find.text('BUKA LOKAL'));
    final editor = find.byKey(const ValueKey('workspace-editor'));
    await _pumpUntilFound(tester, editor);
    expect(editor, findsOneWidget);
    expect(find.text('LOCAL ONLY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('riwayat chat tersimpan dapat dibuka kembali', (tester) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-chat-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'saved-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 23, 10),
        entries: const [
          ChatEntry(role: ChatRole.user, content: 'Percakapan tersimpan'),
          ChatEntry(role: ChatRole.assistant, content: 'Masih tersedia'),
        ],
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(find.text('Percakapan tersimpan'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rail-history')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('CHAT HISTORY'), findsOneWidget);
    expect(find.text('Percakapan tersimpan'), findsWidgets);
    expect(find.textContaining('2 pesan'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-session-saved-chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Masih tersedia'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('respons agent dapat disalin dalam format yang terlihat', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-copy-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'copy-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 24, 10),
        entries: const [
          ChatEntry(role: ChatRole.user, content: 'Tolong periksa'),
          ChatEntry(
            role: ChatRole.assistant,
            content: '## Hasil\n```text\n- Semua lulus\n```',
          ),
        ],
      ),
    ]);
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(find.byKey(const ValueKey('copy-agent-response')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('copy-agent-response-bottom')),
      findsOneWidget,
    );
    expect(find.text('COPY RESPONSE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-agent-response-bottom')));
    await tester.pump();

    expect(copiedText, 'Hasil\n\n- Semua lulus');
    expect(find.text('Respons disalin.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kartu percakapan tetap rapat dan terpusat pada layar lebar', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-chat-lane-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'wide-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 27),
        entries: const [
          ChatEntry(role: ChatRole.user, content: 'Lanjutkan'),
          ChatEntry(
            role: ChatRole.assistant,
            content: 'Saya akan melanjutkan pekerjaan.',
          ),
        ],
      ),
    ]);
    const surfaceSize = Size(1920, 1080);
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final userRect = tester.getRect(
      find.byKey(const ValueKey('user-message-card')),
    );
    final agentRect = tester.getRect(
      find.byKey(const ValueKey('agent-message-card')),
    );
    final combinedCenter = (userRect.center.dx + agentRect.center.dx) / 2;

    expect(userRect.width, lessThanOrEqualTo(760));
    expect(agentRect.width, lessThanOrEqualTo(760));
    expect((combinedCenter - surfaceSize.width / 2).abs(), lessThan(180));
    expect(userRect.left, lessThan(agentRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('riwayat panjang otomatis menampilkan respons terbaru', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-scroll-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await ChatSessionStore().save([
      ChatSession(
        id: 'scroll-chat',
        workspace: workspace.path,
        updatedAt: DateTime(2026, 7, 24, 11),
        entries: [
          for (var index = 0; index < 24; index++)
            ChatEntry(
              role: index.isEven ? ChatRole.user : ChatRole.assistant,
              content: index == 23 ? 'RESPONS PALING BARU' : 'Pesan $index',
            ),
        ],
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('RESPONS PALING BARU'), findsOneWidget);
    final conversation = tester.widget<ListView>(
      find.byKey(const ValueKey('conversation-list')),
    );
    expect(conversation.reverse, isTrue);
    expect(
      conversation.controller?.offset,
      conversation.controller?.position.minScrollExtent,
    );
    expect(
      tester.getBottomRight(find.text('RESPONS PALING BARU')).dy,
      lessThan(700),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('light mode dapat diaktifkan dan disimpan', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('light_mode'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light mode memakai teks dan popup dengan kontras terang', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('younzcode-light-theme-'),
    ))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    final canonicalWorkspace = (await tester.runAsync(
      workspace.resolveSymbolicLinks,
    ))!;
    _setMockPreferences({
      'light_mode': true,
      'workspace': workspace.path,
      'trusted_workspaces': [canonicalWorkspace],
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final context = tester.element(find.byType(Scaffold).first);
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.light);
    final workspaceLabel = tester.widget<Text>(find.text('WORKSPACE').first);
    expect(workspaceLabel.style?.color, theme.colorScheme.onSurfaceVariant);
    final statusBar = tester.widget<Container>(
      find.byKey(const ValueKey('status-bar')),
    );
    final statusDecoration = statusBar.decoration! as BoxDecoration;
    expect(statusDecoration.color, theme.colorScheme.surface);

    await tester.tap(find.byKey(const ValueKey('rail-terminal')));
    await tester.pump(const Duration(milliseconds: 300));
    final terminal = tester.widget<Container>(
      find.byKey(const ValueKey('integrated-terminal')),
    );
    final terminalDecoration = terminal.decoration! as BoxDecoration;
    expect(terminalDecoration.color, theme.colorScheme.surface);

    await tester.tap(find.text('MANAGE MODELS'));
    await tester.pump(const Duration(milliseconds: 300));
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, theme.colorScheme.surface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file tree light mode memakai warna tema yang kontras', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'younzcode-light-tree-',
      );
      await Directory('${directory.path}${Platform.pathSeparator}lib').create();
      await File(
        '${directory.path}${Platform.pathSeparator}visible.txt',
      ).writeAsString('visible');
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({
      'workspace': workspace.path,
      'light_mode': true,
      'onboarding_complete': true,
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await _pumpUntilFound(tester, find.text('visible.txt'));
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    final folder = tester.widget<Text>(find.text('lib'));
    final file = tester.widget<Text>(find.text('visible.txt'));
    expect(folder.style?.color, theme.colorScheme.onSurface);
    expect(file.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor file light mode memakai kanvas dan teks terang', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'younzcode-light-editor-',
      );
      await File(
        '${directory.path}${Platform.pathSeparator}sample.txt',
      ).writeAsString('Isi file terlihat');
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({
      'workspace': workspace.path,
      'light_mode': true,
      'onboarding_complete': true,
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final fileName = find.text('sample.txt');
    await _pumpUntilFound(tester, fileName);
    await tester.tap(fileName);
    final editorFinder = find.byKey(const ValueKey('workspace-editor'));
    await _pumpUntilFound(tester, editorFinder);

    final theme = Theme.of(tester.element(editorFinder));
    final editor = tester.widget<TextField>(editorFinder);
    expect(editor.style?.color, theme.colorScheme.onSurface);
    expect(editor.decoration?.fillColor, const Color(0xFFFFFFFF));
    expect(editor.controller?.text, 'Isi file terlihat');

    await tester.tap(find.byTooltip('Back to Chat'));
    await tester.pumpAndSettle();
    expect(editorFinder, findsNothing);

    await tester.tap(find.text('Editor'));
    await tester.pumpAndSettle();
    expect(editorFinder, findsOneWidget);
    await tester.tap(editorFinder);
    await tester.enterText(editorFinder, 'Isi file telah diedit');
    expect(
      tester.widget<TextField>(editorFinder).controller?.text,
      'Isi file telah diedit',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('restricted editor blocks analyze and debug execution', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'younzcode-restricted-editor-',
      );
      await File(
        '${directory.path}${Platform.pathSeparator}sample.dart',
      ).writeAsString('void main() {}');
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await _pumpUntilFound(tester, find.text('sample.dart'));
    await tester.tap(find.text('sample.dart'));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('workspace-editor')),
    );

    final analyze = tester.widget<IconButton>(
      find.byKey(const ValueKey('analyze-editor-file')),
    );
    final debug = tester.widget<IconButton>(
      find.byKey(const ValueKey('start-debugger')),
    );
    expect(analyze.onPressed, isNull);
    expect(debug.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(find.text('DEBUG CONSOLE'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('root file tree dapat dibuka dan ditutup', (tester) async {
    final workspace = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'younzcode-root-',
      );
      await File(
        '${directory.path}${Platform.pathSeparator}visible.txt',
      ).writeAsString('visible');
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({'workspace': workspace.path});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final visibleFile = find.text('visible.txt');
    await _pumpUntilFound(tester, visibleFile);
    expect(visibleFile, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-tree-root-toggle')));
    await tester.pumpAndSettle();
    expect(visibleFile, findsNothing);
    await tester.tap(find.byKey(const ValueKey('workspace-tree-root-toggle')));
    await _pumpUntilFound(tester, visibleFile);
    expect(visibleFile, findsOneWidget);
  });

  testWidgets('restricted workspace dapat dipercaya dari status bar', (
    tester,
  ) async {
    final workspace = (await tester.runAsync(() async {
      return Directory.systemTemp.createTemp('younzcode-trust-');
    }))!;
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));
    _setMockPreferences({
      'workspace': workspace.path,
      'onboarding_complete': true,
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    final restricted = find.byKey(const ValueKey('restricted-mode-action'));
    expect(restricted, findsOneWidget);
    await tester.tap(restricted);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('trust-current-workspace')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(restricted, findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('trusted_workspaces'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan mode dapat dipilih dari composer', (tester) async {
    _setMockPreferences({});
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const KodeAgentApp());
    await _pumpLoaded(tester);

    await tester.tap(find.byKey(const ValueKey('agent-mode-selector')));
    await tester.pumpAndSettle();
    expect(find.textContaining('READ-ONLY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
