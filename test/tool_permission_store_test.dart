import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/tool_permission_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('menyimpan kebijakan izin tool per workspace', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ToolPermissionStore();

    await store.set(
      r'C:\repo-a',
      'mcp:server/search',
      ToolPermissionPolicy.allow,
    );
    await store.set(
      r'C:\repo-b',
      'mcp:server/search',
      ToolPermissionPolicy.deny,
    );

    expect(
      (await store.load(r'C:\repo-a'))['mcp:server/search'],
      ToolPermissionPolicy.allow,
    );
    expect(
      (await store.load(r'C:\repo-b'))['mcp:server/search'],
      ToolPermissionPolicy.deny,
    );

    await store.set(
      r'C:\repo-a',
      'mcp:server/search',
      ToolPermissionPolicy.ask,
    );
    expect(await store.load(r'C:\repo-a'), isEmpty);
  });
}
