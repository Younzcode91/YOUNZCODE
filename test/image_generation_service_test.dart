import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/services/image_generation_service.dart';

void main() {
  test('mengirim request image generation dan membaca Base64', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'http://127.0.0.1:20128/v1/images/generations',
      );
      expect(request.headers['authorization'], 'Bearer secret');
      expect(request.headers['x-provider'], '9router');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'cx/gpt-5.5-image');
      expect(body['prompt'], 'Seekor kucing memakai topi');
      expect(body['output_format'], 'png');
      expect(body['image_url'], 'https://example.com/reference.png');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'b64_json': base64Encode([1, 2, 3, 4]),
              'revised_prompt': 'A cute cat wearing a hat',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = ImageGenerationService(client: client);

    final result = await service.generate(
      baseUrl: 'http://localhost:20128',
      apiKey: 'secret',
      headers: const {'x-provider': '9router'},
      request: const ImageGenerationRequest(
        model: 'cx/gpt-5.5-image',
        prompt: 'Seekor kucing memakai topi',
        referenceImageUrl: 'https://example.com/reference.png',
      ),
    );

    expect(result.imageBytes, [1, 2, 3, 4]);
    expect(result.revisedPrompt, 'A cute cat wearing a hat');
    expect(result.responsePreview, contains('<base64 image omitted>'));
    expect(result.responsePreview, isNot(contains('AQIDBA==')));
  });

  test('mendukung respons URL gambar', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'data': [
            {'url': 'https://cdn.example.test/image.png'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = ImageGenerationService(client: client);

    final result = await service.generate(
      baseUrl: 'https://api.example.test/v1',
      apiKey: '',
      request: const ImageGenerationRequest(
        model: 'gpt-image-1',
        prompt: 'A mountain',
      ),
    );

    expect(result.imageUrl, 'https://cdn.example.test/image.png');
    expect(result.hasImage, isTrue);
  });

  test('menampilkan pesan error provider tanpa membocorkan body mentah', () {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'message': 'Model tidak mendukung image generation'},
        }),
        400,
      ),
    );
    final service = ImageGenerationService(client: client);

    expect(
      () => service.generate(
        baseUrl: 'https://api.example.test/v1',
        apiKey: '',
        request: const ImageGenerationRequest(
          model: 'text-model',
          prompt: 'test',
        ),
      ),
      throwsA(
        isA<ImageGenerationException>()
            .having((error) => error.statusCode, 'statusCode', 400)
            .having(
              (error) => error.message,
              'message',
              contains('Model tidak mendukung image generation'),
            ),
      ),
    );
  });
}
