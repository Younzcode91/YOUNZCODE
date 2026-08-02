import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef MediaDownloadToolLocator = Future<MediaDownloadTool?> Function();
typedef MediaHostLookup = Future<List<InternetAddress>> Function(String host);

class MediaDownloadIntent {
  const MediaDownloadIntent(this.url);

  final Uri url;

  static final _downloadWords = RegExp(
    r'\b(download|unduh|simpan|ambil|save)\b',
    caseSensitive: false,
  );
  static final _urlPattern = RegExp(
    r'https://[^\s<>"`]+',
    caseSensitive: false,
  );

  static MediaDownloadIntent? tryParse(
    String input, {
    bool requireDownloadWord = true,
  }) {
    if (requireDownloadWord && !_downloadWords.hasMatch(input)) return null;
    final match = _urlPattern.firstMatch(input);
    if (match == null) return null;
    final cleaned = match.group(0)!.replaceFirst(RegExp(r'[\]\[),.;!?]+$'), '');
    final uri = Uri.tryParse(cleaned);
    if (uri == null) return null;
    return MediaDownloadIntent(uri);
  }
}

class MediaDownloadTool {
  const MediaDownloadTool({
    required this.executable,
    this.prefixArguments = const [],
  });

  final String executable;
  final List<String> prefixArguments;
}

class MediaDownloadProgress {
  const MediaDownloadProgress({
    required this.message,
    this.percent,
    this.speed,
    this.eta,
  });

  final String message;
  final double? percent;
  final String? speed;
  final String? eta;
}

class MediaDownloadResult {
  const MediaDownloadResult({
    required this.outputDirectory,
    required this.filePath,
    required this.log,
  });

  final String outputDirectory;
  final String? filePath;
  final String log;
}

class MediaDownloadException implements Exception {
  const MediaDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MediaDownloadCancelledException extends MediaDownloadException {
  const MediaDownloadCancelledException()
    : super('Unduhan dibatalkan oleh pengguna.');
}

class MediaDownloadService {
  MediaDownloadService({
    MediaDownloadToolLocator? toolLocator,
    MediaHostLookup? hostLookup,
    this.timeout = const Duration(minutes: 45),
  }) : _toolLocator = toolLocator ?? locateTool,
       _hostLookup = hostLookup ?? InternetAddress.lookup;

  final MediaDownloadToolLocator _toolLocator;
  final MediaHostLookup _hostLookup;
  final Duration timeout;

  Process? _activeProcess;
  bool _cancelRequested = false;

  bool get running => _activeProcess != null;

  static Future<MediaDownloadTool?> locateTool() async {
    final configured = Platform.environment['YOUNZCODE_YTDLP']?.trim();
    if (configured != null && configured.isNotEmpty) {
      final tool = MediaDownloadTool(executable: configured);
      if (await _probe(tool)) return tool;
    }

    final bundledTool = findBundledTool(Platform.resolvedExecutable);
    if (bundledTool != null) return bundledTool;

    if (Platform.isWindows) {
      try {
        final located = await Process.run('where.exe', const [
          'yt-dlp.exe',
        ]).timeout(const Duration(seconds: 5));
        if (located.exitCode == 0) {
          for (final line in '${located.stdout}'.split(RegExp(r'[\r\n]+'))) {
            final candidate = line.trim();
            if (candidate.isEmpty || !File(candidate).existsSync()) continue;
            final tool = MediaDownloadTool(executable: candidate);
            if (await _probe(tool)) return tool;
          }
        }
      } catch (_) {}
    }

    const direct = MediaDownloadTool(executable: 'yt-dlp');
    if (await _probe(direct)) return direct;

    final pythonCandidates = <MediaDownloadTool>[
      const MediaDownloadTool(
        executable: 'python',
        prefixArguments: ['-m', 'yt_dlp'],
      ),
      if (Platform.isWindows)
        const MediaDownloadTool(
          executable: 'py',
          prefixArguments: ['-3', '-m', 'yt_dlp'],
        ),
    ];
    for (final tool in pythonCandidates) {
      if (await _probe(tool)) return tool;
    }
    return null;
  }

  static Future<bool> _probe(MediaDownloadTool tool) async {
    try {
      final result = await Process.run(tool.executable, [
        ...tool.prefixArguments,
        '--version',
      ]).timeout(const Duration(seconds: 15));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static MediaDownloadTool? findBundledTool(String appExecutablePath) {
    final bundledExecutable = p.join(
      File(appExecutablePath).parent.path,
      'tools',
      Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp',
    );
    if (!File(bundledExecutable).existsSync()) return null;
    return MediaDownloadTool(executable: bundledExecutable);
  }

  static List<String> buildArguments({
    required MediaDownloadTool tool,
    required Uri url,
    required String outputDirectory,
    String? ffmpegLocation,
  }) {
    return [
      ...tool.prefixArguments,
      '--newline',
      '--no-playlist',
      '--restrict-filenames',
      '--windows-filenames',
      '--no-overwrites',
      '--no-part',
      '--paths',
      outputDirectory,
      '--output',
      '%(title).180B [%(id)s].%(ext)s',
      '--format',
      'bestvideo*+bestaudio/best',
      '--merge-output-format',
      'mp4',
      '--progress-template',
      'download:__YOUNZ_PROGRESS__:%(progress._percent_str)s|'
          '%(progress._speed_str)s|%(progress._eta_str)s',
      '--print',
      'after_move:__YOUNZ_FILE__:%(filepath)s',
      if (ffmpegLocation != null && ffmpegLocation.trim().isNotEmpty) ...[
        '--ffmpeg-location',
        ffmpegLocation.trim(),
      ],
      url.toString(),
    ];
  }

  Future<MediaDownloadResult> download({
    required Uri url,
    required String workspace,
    void Function(MediaDownloadProgress progress)? onProgress,
  }) async {
    if (running) {
      throw const MediaDownloadException(
        'Masih ada unduhan media yang berjalan.',
      );
    }
    await validatePublicHttpsUrl(url, hostLookup: _hostLookup);
    final workspaceDirectory = Directory(workspace);
    if (!await workspaceDirectory.exists()) {
      throw const MediaDownloadException('Workspace tidak valid.');
    }

    final tool = await _toolLocator();
    if (tool == null) {
      throw const MediaDownloadException(
        'yt-dlp belum tersedia. Instal yt-dlp dan FFmpeg, atau isi environment '
        'variable YOUNZCODE_YTDLP dengan lokasi yt-dlp.exe.',
      );
    }

    final outputDirectory = p.join(workspace, 'downloads');
    await Directory(outputDirectory).create(recursive: true);
    final configuredFfmpeg = Platform.environment['YOUNZCODE_FFMPEG']?.trim();
    final bundledToolsDirectory = p.join(
      File(Platform.resolvedExecutable).parent.path,
      'tools',
    );
    final bundledFfmpeg = p.join(
      bundledToolsDirectory,
      Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
    );
    final ffmpegLocation =
        configuredFfmpeg != null && configuredFfmpeg.isNotEmpty
        ? configuredFfmpeg
        : File(bundledFfmpeg).existsSync()
        ? bundledToolsDirectory
        : null;
    final arguments = buildArguments(
      tool: tool,
      url: url,
      outputDirectory: outputDirectory,
      ffmpegLocation: ffmpegLocation,
    );

    _cancelRequested = false;
    final logLines = <String>[];
    String? downloadedFile;
    try {
      final process = await Process.start(
        tool.executable,
        arguments,
        workingDirectory: workspace,
        runInShell: false,
      );
      _activeProcess = process;

      void consumeLine(String line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        if (trimmed.startsWith('__YOUNZ_FILE__:')) {
          final candidate = trimmed.substring('__YOUNZ_FILE__:'.length).trim();
          final normalizedOutput = p.canonicalize(outputDirectory);
          final normalizedCandidate = p.canonicalize(candidate);
          if (p.equals(normalizedCandidate, normalizedOutput) ||
              p.isWithin(normalizedOutput, normalizedCandidate)) {
            downloadedFile = normalizedCandidate;
          }
          return;
        }
        if (trimmed.startsWith('__YOUNZ_PROGRESS__:')) {
          final values = trimmed
              .substring('__YOUNZ_PROGRESS__:'.length)
              .split('|');
          final rawPercent = values.isEmpty
              ? ''
              : values.first.replaceAll('%', '').trim();
          final percent = double.tryParse(rawPercent);
          onProgress?.call(
            MediaDownloadProgress(
              message: percent == null
                  ? 'Mengunduh media'
                  : 'Mengunduh media ${percent.toStringAsFixed(1)}%',
              percent: percent,
              speed: values.length > 1 ? values[1].trim() : null,
              eta: values.length > 2 ? values[2].trim() : null,
            ),
          );
          return;
        }
        logLines.add(trimmed);
        if (logLines.length > 80) logLines.removeAt(0);
      }

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(consumeLine);
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(consumeLine);
      late final int exitCode;
      try {
        exitCode = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        await cancel();
        throw MediaDownloadException(
          'Unduhan melewati batas waktu ${timeout.inMinutes} menit.',
        );
      }
      await Future.wait([stdoutDone, stderrDone]);
      if (_cancelRequested) throw const MediaDownloadCancelledException();
      if (exitCode != 0) {
        final detail = logLines.take(12).join('\n');
        throw MediaDownloadException(
          'yt-dlp berhenti dengan kode $exitCode.'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
      }
      onProgress?.call(
        const MediaDownloadProgress(message: 'Unduhan selesai', percent: 100),
      );
      return MediaDownloadResult(
        outputDirectory: outputDirectory,
        filePath: downloadedFile,
        log: logLines.join('\n'),
      );
    } on MediaDownloadException {
      rethrow;
    } on ProcessException catch (error) {
      throw MediaDownloadException(
        'Gagal menjalankan yt-dlp: ${error.message}',
      );
    } finally {
      _activeProcess = null;
    }
  }

  Future<void> cancel() async {
    final process = _activeProcess;
    if (process == null) return;
    _cancelRequested = true;
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 8));
      } catch (_) {
        process.kill();
      }
    } else {
      process.kill(ProcessSignal.sigterm);
    }
  }

  Future<void> dispose() => cancel();

  static Future<void> validatePublicHttpsUrl(
    Uri url, {
    MediaHostLookup? hostLookup,
  }) async {
    if (url.scheme.toLowerCase() != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw const MediaDownloadException(
        'Hanya URL HTTPS publik tanpa username/password yang diizinkan.',
      );
    }
    final host = url.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      throw const MediaDownloadException('URL jaringan lokal tidak diizinkan.');
    }

    final literal = InternetAddress.tryParse(host);
    if (literal != null && _isPrivateAddress(literal)) {
      throw const MediaDownloadException(
        'Alamat IP lokal/private tidak diizinkan.',
      );
    }

    final lookup = hostLookup ?? InternetAddress.lookup;
    List<InternetAddress> addresses;
    try {
      addresses = await lookup(host).timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const MediaDownloadException(
        'Nama host URL tidak dapat diverifikasi.',
      );
    }
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw const MediaDownloadException(
        'URL mengarah ke jaringan lokal/private dan ditolak.',
      );
    }
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return bytes[0] == 0 ||
          bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 169 && bytes[1] == 254) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
          bytes[0] >= 224;
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      return bytes.every((value) => value == 0) ||
          (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) ||
          (bytes[0] & 0xfe) == 0xfc ||
          (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
    }
    return true;
  }
}
