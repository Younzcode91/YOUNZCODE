import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ToolPermissionPolicy { ask, allow, deny }

class ToolPermissionStore {
  ToolPermissionStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _storageKey = 'tool_permission_policies_v1';
  final Future<SharedPreferences> Function() _preferences;

  Future<Map<String, ToolPermissionPolicy>> load(String workspace) async {
    if (workspace.isEmpty) return {};
    final preferences = await _preferences();
    final all = _decode(preferences.getString(_storageKey));
    final raw = all[workspace];
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (ToolPermissionPolicy.values.any(
          (policy) => policy.name == entry.value,
        ))
          '${entry.key}': ToolPermissionPolicy.values.byName('${entry.value}'),
    };
  }

  Future<void> set(
    String workspace,
    String pattern,
    ToolPermissionPolicy policy,
  ) async {
    if (workspace.isEmpty || pattern.isEmpty) return;
    final preferences = await _preferences();
    final all = _decode(preferences.getString(_storageKey));
    final policies = Map<String, dynamic>.from(
      all[workspace] as Map? ?? const {},
    );
    if (policy == ToolPermissionPolicy.ask) {
      policies.remove(pattern);
    } else {
      policies[pattern] = policy.name;
    }
    all[workspace] = policies;
    await preferences.setString(_storageKey, jsonEncode(all));
  }

  static Map<String, dynamic> _decode(String? value) {
    if (value == null || value.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } on FormatException {
      return {};
    }
  }
}
