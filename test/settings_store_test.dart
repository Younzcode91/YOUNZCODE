import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/settings_store.dart';
import 'package:kode_agent_desktop/services/approval_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('settings lama dimigrasikan menjadi daftar model', () async {
    SharedPreferences.setMockInitialValues({'model': 'legacy-model'});
    final settings = await SettingsStore().load();
    expect(settings.model, 'legacy-model');
    expect(settings.models, ['legacy-model']);
  });

  test('daftar model dan pilihan aktif disimpan', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    await store.save(
      const AppSettings(
        baseUrl: 'https://example.test/v1',
        model: 'model-b',
        models: ['model-a', 'model-b'],
        workspace: '',
      ),
    );
    final settings = await store.load();
    expect(settings.model, 'model-b');
    expect(settings.models, ['model-b', 'model-a']);
  });

  test('alamat 9router dimigrasikan tanpa mengubah tingkat thinking', () async {
    SharedPreferences.setMockInitialValues({
      'base_url': 'http://localhost:20128/v1.',
      'model': 'cx/gpt-5.6-sol(max)',
      'models': <String>[
        'cx/gpt-5.6-sol(max)',
        'cx/gpt-5.6-sol',
        'cx/gpt-5.6-terra(high)',
      ],
    });

    final settings = await SettingsStore().load();

    expect(settings.baseUrl, 'http://127.0.0.1:20128/v1');
    expect(settings.model, 'cx/gpt-5.6-sol(max)');
    expect(settings.models, [
      'cx/gpt-5.6-sol(max)',
      'cx/gpt-5.6-sol',
      'cx/gpt-5.6-terra(high)',
    ]);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('base_url'), settings.baseUrl);
    expect(preferences.getString('model'), settings.model);
  });

  test('alamat 9router tanpa path API dikoreksi menjadi v1', () {
    expect(
      normalizeProviderBaseUrl('http://127.0.0.1:20128'),
      'http://127.0.0.1:20128/v1',
    );
  });

  test('hanya HTTPS dan HTTP loopback yang diterima', () {
    expect(
      normalizeProviderBaseUrl('https://example.test/v1'),
      'https://example.test/v1',
    );
    expect(
      normalizeProviderBaseUrl('http://127.23.4.5:8080/v1'),
      'http://127.23.4.5:8080/v1',
    );
    expect(
      normalizeProviderBaseUrl('http://[::1]:8080/v1'),
      'http://[::1]:8080/v1',
    );
    expect(
      normalizeProviderBaseUrl('http://localhost:8080/v1'),
      'http://localhost:8080/v1',
    );
    expect(
      () => normalizeProviderBaseUrl('http://provider.example/v1'),
      throwsFormatException,
    );
  });

  test(
    'save menolak HTTP non-loopback dan load memigrasikan nilai lama',
    () async {
      SharedPreferences.setMockInitialValues({
        'base_url': 'http://provider.example/v1',
      });
      final store = SettingsStore();

      expect((await store.load()).baseUrl, defaultProviderBaseUrl);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('base_url'), defaultProviderBaseUrl);
      await expectLater(
        store.save(
          const AppSettings(
            baseUrl: 'http://provider.example/v1',
            model: 'model',
            workspace: '',
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test('dap timeout disimpan, default 30 detik, dan di-clamp saat save',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();

    // Default when nothing is stored.
    expect((await store.load()).dapTimeoutMs, 30000);

    // Round-trip a custom value.
    await store.save(
      const AppSettings(
        baseUrl: 'https://example.test/v1',
        model: 'model',
        workspace: '',
        dapTimeoutMs: 60000,
      ),
    );
    expect((await store.load()).dapTimeoutMs, 60000);

    // Out-of-range values are clamped to [5000, 600000] on save.
    await store.save(
      const AppSettings(
        baseUrl: 'https://example.test/v1',
        model: 'model',
        workspace: '',
        dapTimeoutMs: 100,
      ),
    );
    expect((await store.load()).dapTimeoutMs, 5000);
  });

  test('mode approval disimpan dan nilai lama memakai default aman', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    expect((await store.load()).approvalMode, ApprovalMode.askForApproval);

    await store.save(
      const AppSettings(
        baseUrl: 'https://example.test/v1',
        model: 'model',
        workspace: '',
        approvalMode: ApprovalMode.fullAccess,
      ),
    );
    expect((await store.load()).approvalMode, ApprovalMode.fullAccess);
  });
}
