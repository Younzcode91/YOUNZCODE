import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/media_download_service.dart';

void main() {
  test('detects an Indonesian download request with a public URL', () {
    final intent = MediaDownloadIntent.tryParse(
      'tolong download https://www.youtube.com/watch?v=abc123.',
    );

    expect(intent, isNotNull);
    expect(intent!.url.host, 'www.youtube.com');
    expect(intent.url.queryParameters['v'], 'abc123');
  });

  test('does not intercept a URL without a download instruction', () {
    expect(
      MediaDownloadIntent.tryParse('jelaskan https://example.com/video'),
      isNull,
    );
  });

  test('rejects HTTP and private network destinations', () async {
    await expectLater(
      MediaDownloadService.validatePublicHttpsUrl(
        Uri.parse('http://example.com/video'),
      ),
      throwsA(isA<MediaDownloadException>()),
    );
    await expectLater(
      MediaDownloadService.validatePublicHttpsUrl(
        Uri.parse('https://media.example/video'),
        hostLookup: (_) async => [InternetAddress('192.168.1.10')],
      ),
      throwsA(isA<MediaDownloadException>()),
    );
  });

  test('accepts a public HTTPS destination after DNS validation', () async {
    await MediaDownloadService.validatePublicHttpsUrl(
      Uri.parse('https://media.example/video'),
      hostLookup: (_) async => [InternetAddress('93.184.216.34')],
    );
  });

  test('builds yt-dlp arguments without a command shell', () {
    final arguments = MediaDownloadService.buildArguments(
      tool: const MediaDownloadTool(
        executable: 'python',
        prefixArguments: ['-m', 'yt_dlp'],
      ),
      url: Uri.parse('https://example.com/video?id=1'),
      outputDirectory: r'C:\workspace\downloads',
      ffmpegLocation: r'C:\tools\ffmpeg.exe',
    );

    expect(arguments.take(3), ['-m', 'yt_dlp', '--newline']);
    expect(arguments, contains('--no-playlist'));
    expect(arguments, contains('--ffmpeg-location'));
    expect(arguments.last, 'https://example.com/video?id=1');
  });

  test('finds a bundled yt-dlp without executing a slow probe', () async {
    final root = await Directory.systemTemp.createTemp(
      'younzcode_bundled_media_',
    );
    addTearDown(() => root.delete(recursive: true));
    final appExecutable = File(
      '${root.path}${Platform.pathSeparator}YOUNZCODE.exe',
    );
    await appExecutable.writeAsBytes(const [0]);
    final tools = Directory('${root.path}${Platform.pathSeparator}tools');
    await tools.create();
    final bundled = File(
      '${tools.path}${Platform.pathSeparator}'
      '${Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'}',
    );
    await bundled.writeAsBytes(const [0]);

    final tool = MediaDownloadService.findBundledTool(appExecutable.path);

    expect(tool, isNotNull);
    expect(tool!.executable, bundled.path);
  });

  test('reports a clear error when yt-dlp is unavailable', () async {
    final workspace = await Directory.systemTemp.createTemp('younzcode_media_');
    addTearDown(() => workspace.delete(recursive: true));
    final service = MediaDownloadService(
      toolLocator: () async => null,
      hostLookup: (_) async => [InternetAddress('93.184.216.34')],
    );

    await expectLater(
      service.download(
        url: Uri.parse('https://media.example/video'),
        workspace: workspace.path,
      ),
      throwsA(
        isA<MediaDownloadException>().having(
          (error) => error.message,
          'message',
          contains('yt-dlp'),
        ),
      ),
    );
  });
}
