import 'package:shared_preferences/shared_preferences.dart';

import 'approval_mode.dart';

const defaultProviderBaseUrl = 'https://api.openai.com/v1';

String normalizeProviderBaseUrl(String value) {
  final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !_isSecureProviderUri(uri)) {
    throw const FormatException(
      'Provider Base URL must use HTTPS, except for HTTP loopback addresses.',
    );
  }
  if (uri.scheme.toLowerCase() == 'http' &&
      {'localhost', '127.0.0.1'}.contains(uri.host.toLowerCase()) &&
      uri.port == 20128) {
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: 20128,
      path: '/v1',
    ).toString();
  }
  return trimmed;
}

bool _isSecureProviderUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return true;
  if (scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '::1') return true;
  final octets = host.split('.');
  if (octets.length != 4 || octets.first != '127') return false;
  return octets.every((octet) {
    final value = int.tryParse(octet);
    return value != null && value >= 0 && value <= 255;
  });
}

String normalizeProviderModel(String value, {required String baseUrl}) {
  return value.trim();
}

class AppSettings {
  const AppSettings({
    required this.baseUrl,
    required this.model,
    required this.workspace,
    this.allowWrite = true,
    this.allowTerminal = true,
    this.approvalMode = ApprovalMode.askForApproval,
    this.timeoutMs = 120000,
    this.models = const [],
  });

  final String baseUrl;
  final String model;
  final String workspace;
  final bool allowWrite;
  final bool allowTerminal;
  final ApprovalMode approvalMode;
  final int timeoutMs;
  final List<String> models;
}

class SettingsStore {
  static const _baseUrlKey = 'base_url';
  static const _modelKey = 'model';
  static const _workspaceKey = 'workspace';
  static const _allowWriteKey = 'allow_write';
  static const _allowTerminalKey = 'allow_terminal';
  static const _approvalModeKey = 'approval_mode';
  static const _timeoutMsKey = 'timeout_ms';
  static const _modelsKey = 'models';

  Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    final storedBaseUrl =
        preferences.getString(_baseUrlKey) ?? defaultProviderBaseUrl;
    String baseUrl;
    try {
      baseUrl = normalizeProviderBaseUrl(storedBaseUrl);
    } on FormatException {
      baseUrl = defaultProviderBaseUrl;
    }
    final storedModel = preferences.getString(_modelKey) ?? 'gpt-4.1-mini';
    final model = normalizeProviderModel(storedModel, baseUrl: baseUrl);
    final storedModels = preferences.getStringList(_modelsKey) ?? const [];
    final models = {
      model,
      for (final stored in storedModels)
        normalizeProviderModel(stored, baseUrl: baseUrl),
    }.where((item) => item.isNotEmpty).toList();
    if (baseUrl != storedBaseUrl ||
        model != storedModel ||
        models.length != storedModels.length ||
        !models.every(storedModels.contains)) {
      await Future.wait([
        preferences.setString(_baseUrlKey, baseUrl),
        preferences.setString(_modelKey, model),
        preferences.setStringList(_modelsKey, models),
      ]);
    }
    return AppSettings(
      baseUrl: baseUrl,
      model: model,
      models: models,
      workspace: preferences.getString(_workspaceKey) ?? '',
      allowWrite: preferences.getBool(_allowWriteKey) ?? true,
      allowTerminal: preferences.getBool(_allowTerminalKey) ?? true,
      approvalMode: ApprovalMode.fromStorage(
        preferences.getString(_approvalModeKey),
      ),
      timeoutMs: preferences.getInt(_timeoutMsKey) ?? 120000,
    );
  }

  Future<void> save(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    final baseUrl = normalizeProviderBaseUrl(settings.baseUrl);
    final model = normalizeProviderModel(settings.model, baseUrl: baseUrl);
    final models = {
      model,
      for (final stored in settings.models)
        normalizeProviderModel(stored, baseUrl: baseUrl),
    }.where((item) => item.isNotEmpty).toList();
    await Future.wait([
      preferences.setString(_baseUrlKey, baseUrl),
      preferences.setString(_modelKey, model),
      preferences.setString(_workspaceKey, settings.workspace),
      preferences.setBool(_allowWriteKey, settings.allowWrite),
      preferences.setBool(_allowTerminalKey, settings.allowTerminal),
      preferences.setString(_approvalModeKey, settings.approvalMode.name),
      preferences.setInt(_timeoutMsKey, settings.timeoutMs),
      preferences.setStringList(_modelsKey, models),
    ]);
  }
}
