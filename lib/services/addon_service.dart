import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/addon.dart';

typedef PreferencesProvider = Future<SharedPreferences> Function();

class AddonImportException implements Exception {
  const AddonImportException(this.message);

  final String message;

  @override
  String toString() => 'AddonImportException: $message';
}

class AddonService {
  AddonService({
    String? addonRoot,
    PreferencesProvider? preferencesProvider,
    DateTime Function()? clock,
  }) : addonRoot = p.normalize(p.absolute(addonRoot ?? defaultAddonRoot())),
       _preferencesProvider =
           preferencesProvider ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static const preferencesKey = 'younzcode_addons_json_v1';

  final String addonRoot;
  final PreferencesProvider _preferencesProvider;
  final DateTime Function() _clock;
  int _sequence = 0;
  Future<void> _mutation = Future.value();

  // Serialize every read-modify-write of the persisted list so two concurrent
  // operations (e.g. import while toggling) cannot each load the same snapshot
  // and clobber each other's change.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.then((_) {}, onError: (_) {});
    return result;
  }

  static String defaultAddonRoot() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw const AddonImportException('LOCALAPPDATA is not available.');
    }
    return p.join(localAppData, 'YOUNZCODE', 'addons');
  }

  Future<List<Addon>> load() async {
    final preferences = await _preferencesProvider();
    final stored = preferences.getString(preferencesKey);
    if (stored == null || stored.isEmpty) return [];
    final List<dynamic> values;
    try {
      values = jsonDecode(stored) as List;
    } on Object catch (error) {
      throw AddonImportException('Stored addon data is invalid: $error');
    }
    final addons = <Addon>[];
    for (final value in values) {
      try {
        addons.add(Addon.fromJson(Map<String, dynamic>.from(value as Map)));
      } on Object {
        // Skip a single malformed record (e.g. an unrecognized addon kind from
        // a newer version) instead of hiding the entire add-on list.
      }
    }
    return addons;
  }

  Future<List<Addon>> ensureBundledSkills(String bundledRoot) async {
    var addons = await load();
    final directory = Directory(bundledRoot);
    if (!await directory.exists()) return addons;

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifest = File(p.join(entity.path, 'SKILL.md'));
      if (!await manifest.exists()) continue;
      final parsed = parseSkill(
        await manifest.readAsString(),
        fallbackName: p.basename(entity.path),
      );
      final existing = addons.where(
        (addon) =>
            addon.kind == AddonKind.skill &&
            addon.name.toLowerCase() == parsed.name.toLowerCase(),
      );
      if (existing.isNotEmpty) continue;
      await importLocal(entity.path);
      addons = await load();
    }
    return addons;
  }

  Future<Addon> importLocal(String selectedPath) async {
    final source = p.normalize(p.absolute(selectedPath));
    await _validateSource(source);
    final inspected = await _inspect(source);
    final importedAt = _clock().toUtc();
    final id = _makeId(inspected.kind, inspected.name, importedAt);
    final destination = p.join(addonRoot, inspected.kind.name, id);
    _requireWithinRoot(destination);

    await Directory(destination).create(recursive: true);
    String installedPath;
    try {
      final sourceType = await FileSystemEntity.type(
        source,
        followLinks: false,
      );
      if (sourceType == FileSystemEntityType.directory) {
        await _copyDirectory(Directory(source), Directory(destination));
        installedPath = destination;
      } else {
        installedPath = p.join(destination, p.basename(source));
        _requireWithinRoot(installedPath);
        await File(source).copy(installedPath);
      }

      final addon = Addon(
        id: id,
        kind: inspected.kind,
        name: inspected.name,
        description: inspected.description,
        sourcePath: source,
        installedPath: installedPath,
        importedAt: importedAt,
        metadata: inspected.metadata,
      );
      await _locked(() async {
        final addons = await load()
          ..add(addon);
        await _save(addons);
      });
      return addon;
    } on Object {
      try {
        await Directory(destination).delete(recursive: true);
      } on FileSystemException {
        // Preserve the original import or persistence error.
      }
      rethrow;
    }
  }

  Future<Addon> setEnabled(String id, bool enabled) {
    return _locked(() async {
      final addons = await load();
      final index = addons.indexWhere((addon) => addon.id == id);
      if (index < 0) throw StateError('Addon not found: $id');
      final updated = addons[index].copyWith(enabled: enabled);
      addons[index] = updated;
      await _save(addons);
      return updated;
    });
  }

  Future<void> remove(String id, {bool deleteFiles = true}) {
    return _locked(() async {
      final addons = await load();
      final index = addons.indexWhere((addon) => addon.id == id);
      if (index < 0) return;
      final addon = addons.removeAt(index);
      // Persist the removal before touching the files; if the delete then
      // fails, the stored list is already consistent and only harmless orphan
      // files remain, instead of an entry pointing at half-deleted files.
      await _save(addons);
      if (deleteFiles) {
        final installDirectory = p.join(addonRoot, addon.kind.name, addon.id);
        _requireWithinRoot(installDirectory);
        final directory = Directory(installDirectory);
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
  }

  static SkillParseResult parseSkill(
    String contents, {
    String fallbackName = 'Unnamed skill',
  }) {
    final normalized = contents
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    final frontmatter = <String, String>{};
    var bodyStart = 0;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      var index = 1;
      for (; index < lines.length && lines[index].trim() != '---'; index++) {
        final match = RegExp(
          r'^([A-Za-z][\w-]*):\s*(.*)$',
        ).firstMatch(lines[index]);
        if (match == null) continue;
        final key = match.group(1)!.toLowerCase();
        var value = match.group(2)!.trim();
        if (value == '>' || value == '|') {
          final parts = <String>[];
          while (index + 1 < lines.length &&
              RegExp(r'^\s+').hasMatch(lines[index + 1])) {
            parts.add(lines[++index].trim());
          }
          value = parts.join(value == '>' ? ' ' : '\n');
        }
        frontmatter[key] = _unquote(value);
      }
      if (index < lines.length) bodyStart = index + 1;
    }
    final body = lines.skip(bodyStart).toList();
    final heading = body
        .map((line) => RegExp(r'^#\s+(.+)$').firstMatch(line)?.group(1)?.trim())
        .whereType<String>()
        .firstOrNull;
    final paragraph = body
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .firstOrNull;
    return SkillParseResult(
      name: _nonEmpty(frontmatter['name']) ?? heading ?? fallbackName,
      description: _nonEmpty(frontmatter['description']) ?? paragraph ?? '',
    );
  }

  static NativePluginParseResult parsePluginManifest(String contents) {
    final manifest = _jsonObject(contents, 'plugin manifest');
    final name =
        _nonEmpty(manifest['displayName']?.toString()) ??
        _nonEmpty(manifest['name']?.toString());
    if (name == null) {
      throw const AddonImportException('Plugin manifest must contain a name.');
    }
    return NativePluginParseResult(
      name: name,
      description: manifest['description']?.toString() ?? '',
      metadata: NativePluginMetadata(
        manifest: manifest,
        version: _nonEmpty(manifest['version']?.toString()),
        entryPoint: _nonEmpty(
          (manifest['entryPoint'] ?? manifest['main'])?.toString(),
        ),
      ),
    );
  }

  static McpParseResult parseMcpConfig(String contents) {
    final root = _jsonObject(contents, 'MCP config');
    final Object? collection = root['mcpServers'] ?? root['mcp'];
    final entries = <MapEntry<String, dynamic>>[];
    if (collection is Map) {
      entries.addAll(
        collection.entries.map(
          (entry) => MapEntry(entry.key.toString(), entry.value),
        ),
      );
    } else if (root.containsKey('command') || root.containsKey('url')) {
      entries.add(MapEntry(root['name']?.toString() ?? 'MCP server', root));
    } else {
      throw const AddonImportException(
        'MCP config must contain mcpServers, mcp, command, or url.',
      );
    }
    if (entries.isEmpty) {
      throw const AddonImportException('MCP config contains no servers.');
    }

    final servers = entries.map((entry) {
      if (entry.value is! Map) {
        throw AddonImportException(
          'MCP server ${entry.key} must be an object.',
        );
      }
      final config = Map<String, dynamic>.from(entry.value as Map);
      final url = _nonEmpty(config['url']?.toString());
      if (url != null) {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw AddonImportException(
            'MCP server ${entry.key} has an invalid HTTP URL.',
          );
        }
        return McpServerConfig(
          name: entry.key,
          transport: McpTransport.http,
          url: url,
          headers: _toStringMap(config['headers'], 'headers'),
        );
      }

      final rawCommand = config['command'];
      String? command;
      final arguments = <String>[];
      if (rawCommand is List && rawCommand.isNotEmpty) {
        command = _nonEmpty(rawCommand.first.toString());
        arguments.addAll(rawCommand.skip(1).map((part) => part.toString()));
      } else {
        command = _nonEmpty(rawCommand?.toString());
      }
      if (command == null) {
        throw AddonImportException(
          'MCP server ${entry.key} has no command or URL.',
        );
      }
      final rawArguments = config['args'];
      if (rawArguments != null && rawArguments is! List) {
        throw AddonImportException(
          'MCP server ${entry.key} args must be a list.',
        );
      }
      arguments.addAll(
        (rawArguments as List? ?? const []).map(
          (argument) => argument.toString(),
        ),
      );
      return McpServerConfig(
        name: entry.key,
        transport: McpTransport.stdio,
        command: command,
        arguments: arguments,
        environment: _toStringMap(config['env'], 'env'),
      );
    }).toList();
    return McpParseResult(
      name: servers.length == 1 ? servers.first.name : 'MCP servers',
      description: '${servers.length} MCP server configuration(s)',
      metadata: McpMetadata(servers: servers),
    );
  }

  static VsixParseResult parseVsixFilename(String fileName) {
    final base = p.basename(fileName);
    if (p.extension(base).toLowerCase() != '.vsix') {
      throw const AddonImportException('VSIX import requires a .vsix file.');
    }
    final stem = p.basenameWithoutExtension(base);
    final versionMatch = RegExp(
      r'-(\d+(?:\.\d+)+(?:[-+][\w.-]+)?)$',
    ).firstMatch(stem);
    final version = versionMatch?.group(1);
    final identity = versionMatch == null
        ? stem
        : stem.substring(0, versionMatch.start);
    final separator = identity.indexOf('.');
    final publisher = separator > 0 ? identity.substring(0, separator) : null;
    final extensionName = separator > 0
        ? identity.substring(separator + 1)
        : identity;
    if (extensionName.trim().isEmpty) {
      throw const AddonImportException('VSIX filename has no extension name.');
    }
    return VsixParseResult(
      name: extensionName,
      description: version == null ? 'Imported VSIX' : 'Imported VSIX $version',
      metadata: VsixMetadata(
        extensionName: extensionName,
        publisher: publisher,
        version: version,
      ),
    );
  }

  Future<_InspectedAddon> _inspect(String source) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.file) return _inspectFile(File(source));
    if (type != FileSystemEntityType.directory) {
      throw const AddonImportException(
        'Only regular files and folders can be imported.',
      );
    }
    final directory = Directory(source);
    final children = await directory.list(followLinks: false).toList();
    File? namedFile(Iterable<String> names) {
      final lowerNames = names.map((name) => name.toLowerCase()).toSet();
      for (final child in children.whereType<File>()) {
        if (lowerNames.contains(p.basename(child.path).toLowerCase())) {
          return child;
        }
      }
      return null;
    }

    final skill = namedFile(const ['SKILL.md']);
    if (skill != null) return _inspectSkill(skill, source);
    final plugin = namedFile(const [
      'younzcode-plugin.json',
      'younzcode.plugin.json',
      'plugin.json',
      'manifest.json',
      'package.json',
    ]);
    if (plugin != null) return _inspectPlugin(plugin);
    final mcp = namedFile(const [
      'mcp.json',
      '.mcp.json',
      'mcp-config.json',
      'mcp_config.json',
    ]);
    if (mcp != null) return _inspectMcp(mcp);
    throw const AddonImportException(
      'Folder must contain SKILL.md, a plugin manifest, or an MCP config.',
    );
  }

  Future<_InspectedAddon> _inspectFile(File file) async {
    final extension = p.extension(file.path).toLowerCase();
    if (extension == '.vsix') {
      final parsed = parseVsixFilename(file.path);
      return _InspectedAddon(
        AddonKind.vsix,
        parsed.name,
        parsed.description,
        parsed.metadata,
      );
    }
    if (p.basename(file.path).toLowerCase() == 'skill.md') {
      return _inspectSkill(file, file.parent.path);
    }
    if (extension != '.json') {
      throw const AddonImportException(
        'Supported files are SKILL.md, JSON, and VSIX.',
      );
    }
    final contents = await file.readAsString();
    final object = _jsonObject(contents, 'JSON addon');
    if (object.containsKey('mcpServers') ||
        object.containsKey('mcp') ||
        object.containsKey('command') ||
        object.containsKey('url')) {
      return _inspectMcp(file, contents: contents);
    }
    return _inspectPlugin(file, contents: contents);
  }

  Future<_InspectedAddon> _inspectSkill(File file, String fallbackPath) async {
    final parsed = parseSkill(
      await file.readAsString(),
      fallbackName: p.basename(fallbackPath),
    );
    return _InspectedAddon(
      AddonKind.skill,
      parsed.name,
      parsed.description,
      SkillMetadata(fileName: p.basename(file.path)),
    );
  }

  Future<_InspectedAddon> _inspectPlugin(File file, {String? contents}) async {
    final parsed = parsePluginManifest(contents ?? await file.readAsString());
    return _InspectedAddon(
      AddonKind.nativePlugin,
      parsed.name,
      parsed.description,
      parsed.metadata,
    );
  }

  Future<_InspectedAddon> _inspectMcp(File file, {String? contents}) async {
    final parsed = parseMcpConfig(contents ?? await file.readAsString());
    return _InspectedAddon(
      AddonKind.mcpServer,
      parsed.name,
      parsed.description,
      parsed.metadata,
    );
  }

  Future<void> _validateSource(String source) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw AddonImportException('Selected path does not exist: $source');
    }
    if (type == FileSystemEntityType.link) {
      throw const AddonImportException('Symbolic links cannot be imported.');
    }
    if (_sameOrWithin(addonRoot, source) || _sameOrWithin(source, addonRoot)) {
      throw const AddonImportException(
        'Cannot import from or around the managed addon root.',
      );
    }
    if (type == FileSystemEntityType.directory) {
      await for (final entity in Directory(
        source,
      ).list(recursive: true, followLinks: false)) {
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw AddonImportException(
            'Folder contains a symbolic link: ${entity.path}',
          );
        }
      }
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      _requireWithinRoot(target);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(entity.path).copy(target);
      } else if (type == FileSystemEntityType.directory) {
        final targetDirectory = await Directory(target).create();
        await _copyDirectory(Directory(entity.path), targetDirectory);
      } else {
        throw AddonImportException('Unsupported folder entry: ${entity.path}');
      }
    }
  }

  Future<void> _save(List<Addon> addons) async {
    final preferences = await _preferencesProvider();
    final stored = jsonEncode(addons.map((addon) => addon.toJson()).toList());
    if (!await preferences.setString(preferencesKey, stored)) {
      throw const AddonImportException('Could not persist addon metadata.');
    }
  }

  String _makeId(AddonKind kind, String name, DateTime importedAt) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${kind.name}-${slug.isEmpty ? 'addon' : slug}-${importedAt.microsecondsSinceEpoch}-${_sequence++}';
  }

  void _requireWithinRoot(String candidate) {
    if (!_sameOrWithin(addonRoot, candidate) ||
        p.equals(addonRoot, candidate)) {
      throw AddonImportException('Path escapes managed addon root: $candidate');
    }
  }

  static bool _sameOrWithin(String parent, String child) {
    final normalizedParent = p.normalize(p.absolute(parent));
    final normalizedChild = p.normalize(p.absolute(child));
    return p.equals(normalizedParent, normalizedChild) ||
        p.isWithin(normalizedParent, normalizedChild);
  }

  static Map<String, dynamic> _jsonObject(String contents, String label) {
    try {
      final decoded = jsonDecode(contents);
      if (decoded is! Map) {
        throw FormatException('$label must be a JSON object.');
      }
      return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw AddonImportException('Invalid $label: ${error.message}');
    }
  }

  static Map<String, String> _toStringMap(Object? value, String label) {
    if (value == null) return {};
    if (value is! Map) {
      throw AddonImportException('MCP $label must be an object.');
    }
    return value.map((key, item) => MapEntry(key.toString(), item.toString()));
  }

  static String _unquote(String value) {
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class SkillParseResult {
  const SkillParseResult({required this.name, required this.description});

  final String name;
  final String description;
}

class NativePluginParseResult {
  const NativePluginParseResult({
    required this.name,
    required this.description,
    required this.metadata,
  });

  final String name;
  final String description;
  final NativePluginMetadata metadata;
}

class McpParseResult {
  const McpParseResult({
    required this.name,
    required this.description,
    required this.metadata,
  });

  final String name;
  final String description;
  final McpMetadata metadata;
}

class VsixParseResult {
  const VsixParseResult({
    required this.name,
    required this.description,
    required this.metadata,
  });

  final String name;
  final String description;
  final VsixMetadata metadata;
}

class _InspectedAddon {
  const _InspectedAddon(this.kind, this.name, this.description, this.metadata);

  final AddonKind kind;
  final String name;
  final String description;
  final AddonMetadata metadata;
}
