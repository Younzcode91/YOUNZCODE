import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

class ImageGenerationRequest {
  const ImageGenerationRequest({
    required this.model,
    required this.prompt,
    this.referenceImageUrl = '',
    this.size = 'auto',
    this.quality = 'auto',
    this.background = 'auto',
    this.imageDetail = 'high',
    this.outputFormat = 'png',
  });

  final String model;
  final String prompt;
  final String referenceImageUrl;
  final String size;
  final String quality;
  final String background;
  final String imageDetail;
  final String outputFormat;

  Map<String, dynamic> toJson() => {
    'model': model,
    'prompt': prompt,
    'n': 1,
    'size': size,
    'quality': quality,
    'background': background,
    'image_detail': imageDetail,
    'output_format': outputFormat,
    if (referenceImageUrl.trim().isNotEmpty)
      'image_url': referenceImageUrl.trim(),
  };
}

class ImageGenerationResult {
  const ImageGenerationResult({
    required this.responsePreview,
    this.imageBytes,
    this.imageUrl,
    this.revisedPrompt,
  });

  final Uint8List? imageBytes;
  final String? imageUrl;
  final String? revisedPrompt;
  final String responsePreview;

  bool get hasImage => imageBytes != null || imageUrl != null;
}

class ImageGenerationException implements Exception {
  const ImageGenerationException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

String imageGenerationEndpoint(String baseUrl) {
  final normalized = normalizeProviderBaseUrl(baseUrl);
  if (normalized.endsWith('/images/generations')) return normalized;
  return '$normalized/images/generations';
}

class ImageGenerationService {
  ImageGenerationService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<ImageGenerationResult> generate({
    required String baseUrl,
    required String apiKey,
    required ImageGenerationRequest request,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final response = await _client
        .post(
          Uri.parse(imageGenerationEndpoint(baseUrl)),
          headers: {
            ...headers,
            if (apiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${apiKey.trim()}',
            'Accept': 'application/json, image/*',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(request.toJson()),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ImageGenerationException(
        _readError(response),
        statusCode: response.statusCode,
      );
    }

    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.startsWith('image/')) {
      return ImageGenerationResult(
        imageBytes: response.bodyBytes,
        responsePreview:
            '{\n  "status": ${response.statusCode},\n'
            '  "content_type": "$contentType",\n'
            '  "bytes": ${response.bodyBytes.length}\n}',
      );
    }

    late final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ImageGenerationException(
        'Provider tidak mengembalikan JSON atau data gambar yang valid.',
      );
    }

    if (decoded is! Map) {
      throw const ImageGenerationException(
        'Format respons provider tidak dikenali.',
      );
    }

    final root = Map<String, dynamic>.from(decoded);
    final rawData = root['data'];
    final first = rawData is List && rawData.isNotEmpty && rawData.first is Map
        ? Map<String, dynamic>.from(rawData.first as Map)
        : root;
    final base64Value =
        first['b64_json'] ?? first['base64'] ?? first['image_base64'];
    final imageUrlValue = first['url'] ?? first['image_url'];

    Uint8List? bytes;
    if (base64Value is String && base64Value.trim().isNotEmpty) {
      try {
        final encoded = base64Value.contains(',')
            ? base64Value.substring(base64Value.indexOf(',') + 1)
            : base64Value;
        bytes = base64Decode(encoded);
      } on FormatException {
        throw const ImageGenerationException(
          'Data Base64 gambar dari provider tidak valid.',
        );
      }
    }
    final imageUrl = imageUrlValue is String && imageUrlValue.trim().isNotEmpty
        ? imageUrlValue.trim()
        : null;

    if (bytes == null && imageUrl == null) {
      throw ImageGenerationException(
        _messageFromDecoded(root) ??
            'Respons berhasil tetapi tidak berisi gambar Base64 atau URL.',
        statusCode: response.statusCode,
      );
    }

    return ImageGenerationResult(
      imageBytes: bytes,
      imageUrl: imageUrl,
      revisedPrompt: first['revised_prompt'] is String
          ? first['revised_prompt'] as String
          : null,
      responsePreview: const JsonEncoder.withIndent(
        '  ',
      ).convert(_summarizeResponse(root)),
    );
  }

  Future<Uint8List> download(String url) async {
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ImageGenerationException(
        'Gagal mengunduh gambar (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

String _readError(http.Response response) {
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) {
      final message = _messageFromDecoded(Map<String, dynamic>.from(decoded));
      if (message != null) {
        return 'Provider menolak request (HTTP ${response.statusCode}): '
            '$message';
      }
    }
  } on FormatException {
    // Fall through to the generic HTTP message.
  }
  return 'Provider menolak request (HTTP ${response.statusCode}).';
}

String? _messageFromDecoded(Map<String, dynamic> decoded) {
  final error = decoded['error'];
  if (error is Map && error['message'] is String) {
    return error['message'] as String;
  }
  if (error is String && error.trim().isNotEmpty) return error;
  if (decoded['message'] is String) return decoded['message'] as String;
  return null;
}

Map<String, dynamic> _summarizeResponse(Map<String, dynamic> decoded) {
  dynamic summarize(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}':
              {'b64_json', 'base64', 'image_base64'}.contains('${entry.key}')
              ? '<base64 image omitted>'
              : summarize(entry.value),
      };
    }
    if (value is List) return value.map(summarize).toList();
    return value;
  }

  return Map<String, dynamic>.from(summarize(decoded) as Map);
}
