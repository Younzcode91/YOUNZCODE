import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class AgentCancelledException implements Exception {
  const AgentCancelledException([
    this.message = 'Tugas dibatalkan oleh pengguna.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class AgentStepLimitException implements Exception {
  const AgentStepLimitException(this.maxSteps);

  final int maxSteps;

  @override
  String toString() =>
      'Agent mencapai batas $maxSteps langkah. Checkpoint telah disimpan; '
      'lanjutkan dari checkpoint untuk meneruskan.';
}

class AgentTurnTimeoutException extends TimeoutException {
  AgentTurnTimeoutException(this.limit)
    : super(
        'Tugas melewati batas waktu total ${limit.inMinutes} menit.',
        limit,
      );

  final Duration limit;
}

class AgentEmptyResponseException implements Exception {
  const AgentEmptyResponseException([
    this.message =
        'Provider tidak memberikan isi jawaban setelah dicoba ulang.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class AgentCompletionStoppedException implements Exception {
  const AgentCompletionStoppedException();
}

class AgentHttpException implements Exception {
  const AgentHttpException(this.message, {this.statusCode});

  factory AgentHttpException.fromResponse(http.Response response) {
    return AgentHttpException.fromParts(response.statusCode, response.body);
  }

  factory AgentHttpException.fromParts(int statusCode, String responseBody) {
    try {
      final body = jsonDecode(responseBody) as Map<String, dynamic>;
      final error = body['error'];
      if (error is Map && error['message'] is String) {
        return AgentHttpException(
          '$statusCode: ${error['message']}',
          statusCode: statusCode,
        );
      }
      if (error is String) {
        return AgentHttpException(
          '$statusCode: $error',
          statusCode: statusCode,
        );
      }
      if (body['message'] is String) {
        return AgentHttpException(
          '$statusCode: ${body['message']}',
          statusCode: statusCode,
        );
      }
    } catch (_) {
      // Use the raw body when a provider does not send a JSON error.
    }
    final detail = responseBody.trim();
    final lowerDetail = detail.toLowerCase();
    final looksLikeHtml =
        lowerDetail.startsWith('<!doctype html') ||
        lowerDetail.startsWith('<html');
    if (looksLikeHtml) {
      return AgentHttpException(
        'HTTP $statusCode: endpoint API provider tidak ditemukan. '
        'Periksa Base URL; endpoint OpenAI-compatible biasanya berakhir /v1.',
        statusCode: statusCode,
      );
    }
    final safeDetail = detail.length > 500
        ? '${detail.substring(0, 500)}…'
        : detail;
    return AgentHttpException(
      safeDetail.isEmpty ? 'HTTP $statusCode' : '$statusCode: $safeDetail',
      statusCode: statusCode,
    );
  }

  final String message;
  final int? statusCode;

  bool get isRetryable => const {
    408,
    425,
    429,
    502,
    503,
    504,
    520,
    522,
    524,
    529,
  }.contains(statusCode);

  @override
  String toString() => message;
}
