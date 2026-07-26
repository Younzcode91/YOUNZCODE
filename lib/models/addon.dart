enum AddonKind { nativePlugin, skill, mcpServer, vsix }

enum McpTransport { stdio, http }

sealed class AddonMetadata {
  const AddonMetadata();

  Map<String, dynamic> toJson();
}

class NativePluginMetadata extends AddonMetadata {
  const NativePluginMetadata({
    required this.manifest,
    this.version,
    this.entryPoint,
  });

  final Map<String, dynamic> manifest;
  final String? version;
  final String? entryPoint;

  @override
  Map<String, dynamic> toJson() => {
    'manifest': manifest,
    if (version != null) 'version': version,
    if (entryPoint != null) 'entryPoint': entryPoint,
  };
}

class SkillMetadata extends AddonMetadata {
  const SkillMetadata({required this.fileName});

  final String fileName;

  @override
  Map<String, dynamic> toJson() => {'fileName': fileName};
}

class McpServerConfig {
  const McpServerConfig({
    required this.name,
    required this.transport,
    this.command,
    this.arguments = const [],
    this.environment = const {},
    this.url,
    this.headers = const {},
  });

  factory McpServerConfig.fromJson(Map<String, dynamic> json) =>
      McpServerConfig(
        name: json['name'] as String,
        transport: McpTransport.values.byName(json['transport'] as String),
        command: json['command'] as String?,
        arguments: _stringList(json['arguments']),
        environment: _stringMap(json['environment']),
        url: json['url'] as String?,
        headers: _stringMap(json['headers']),
      );

  final String name;
  final McpTransport transport;
  final String? command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? url;
  final Map<String, String> headers;

  Map<String, dynamic> toJson() => {
    'name': name,
    'transport': transport.name,
    if (command != null) 'command': command,
    if (arguments.isNotEmpty) 'arguments': arguments,
    if (environment.isNotEmpty) 'environment': environment,
    if (url != null) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
  };
}

class McpMetadata extends AddonMetadata {
  const McpMetadata({required this.servers});

  final List<McpServerConfig> servers;

  @override
  Map<String, dynamic> toJson() => {
    'servers': servers.map((server) => server.toJson()).toList(),
  };
}

class VsixMetadata extends AddonMetadata {
  const VsixMetadata({
    required this.extensionName,
    this.publisher,
    this.version,
  });

  final String extensionName;
  final String? publisher;
  final String? version;

  @override
  Map<String, dynamic> toJson() => {
    'extensionName': extensionName,
    if (publisher != null) 'publisher': publisher,
    if (version != null) 'version': version,
  };
}

class Addon {
  const Addon({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.sourcePath,
    required this.installedPath,
    required this.importedAt,
    required this.metadata,
    this.enabled = true,
  });

  factory Addon.fromJson(Map<String, dynamic> json) {
    final kind = AddonKind.values.byName(json['kind'] as String);
    final metadata = Map<String, dynamic>.from(json['metadata'] as Map);
    return Addon(
      id: json['id'] as String,
      kind: kind,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      sourcePath: json['sourcePath'] as String,
      installedPath: json['installedPath'] as String,
      importedAt: DateTime.parse(json['importedAt'] as String),
      enabled: json['enabled'] as bool? ?? true,
      metadata: switch (kind) {
        AddonKind.nativePlugin => NativePluginMetadata(
          manifest: Map<String, dynamic>.from(metadata['manifest'] as Map),
          version: metadata['version'] as String?,
          entryPoint: metadata['entryPoint'] as String?,
        ),
        AddonKind.skill => SkillMetadata(
          fileName: metadata['fileName'] as String,
        ),
        AddonKind.mcpServer => McpMetadata(
          servers: (metadata['servers'] as List)
              .map(
                (server) => McpServerConfig.fromJson(
                  Map<String, dynamic>.from(server as Map),
                ),
              )
              .toList(),
        ),
        AddonKind.vsix => VsixMetadata(
          extensionName: metadata['extensionName'] as String,
          publisher: metadata['publisher'] as String?,
          version: metadata['version'] as String?,
        ),
      },
    );
  }

  final String id;
  final AddonKind kind;
  final String name;
  final String description;
  final String sourcePath;
  final String installedPath;
  final DateTime importedAt;
  final AddonMetadata metadata;
  final bool enabled;

  Addon copyWith({bool? enabled}) => Addon(
    id: id,
    kind: kind,
    name: name,
    description: description,
    sourcePath: sourcePath,
    installedPath: installedPath,
    importedAt: importedAt,
    metadata: metadata,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'description': description,
    'sourcePath': sourcePath,
    'installedPath': installedPath,
    'importedAt': importedAt.toIso8601String(),
    'enabled': enabled,
    'metadata': metadata.toJson(),
  };
}

List<String> _stringList(Object? value) =>
    (value as List? ?? const []).map((item) => item.toString()).toList();

Map<String, String> _stringMap(Object? value) => (value as Map? ?? const {})
    .map((key, item) => MapEntry(key.toString(), item.toString()));
