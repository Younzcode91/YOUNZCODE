import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:webview_windows/webview_windows.dart';

typedef BrowserHostLookup = Future<List<InternetAddress>> Function(String host);

class BrowserAgentException implements Exception {
  const BrowserAgentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BrowserUrlPolicyException extends BrowserAgentException {
  const BrowserUrlPolicyException(super.message);
}

class BrowserPageSnapshot {
  const BrowserPageSnapshot({
    required this.url,
    required this.title,
    required this.text,
    required this.elements,
  });

  final String url;
  final String title;
  final String text;
  final List<String> elements;

  String toToolText() {
    final buffer = StringBuffer()
      ..writeln('URL: $url')
      ..writeln('Title: $title')
      ..writeln()
      ..writeln('PAGE TEXT')
      ..writeln(text.isEmpty ? '(tidak ada teks yang dapat dibaca)' : text);
    if (elements.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('INTERACTIVE ELEMENTS');
      for (final element in elements) {
        buffer.writeln(element);
      }
    }
    return buffer.toString().trim();
  }
}

class BrowserElementInfo {
  const BrowserElementInfo({
    required this.ref,
    required this.tag,
    required this.text,
    required this.type,
    required this.href,
    required this.editable,
  });

  final String ref;
  final String tag;
  final String text;
  final String type;
  final String href;
  final bool editable;

  String get description {
    final details = <String>[
      '<$tag>',
      if (type.isNotEmpty) 'type=$type',
      if (text.isNotEmpty) '"$text"',
      if (href.isNotEmpty) href,
    ];
    return details.join(' ');
  }
}

class BrowserAgentState {
  const BrowserAgentState({
    this.initialized = false,
    this.loading = false,
    this.url = '',
    this.title = '',
    this.canGoBack = false,
    this.canGoForward = false,
    this.error,
  });

  final bool initialized;
  final bool loading;
  final String url;
  final String title;
  final bool canGoBack;
  final bool canGoForward;
  final String? error;

  BrowserAgentState copyWith({
    bool? initialized,
    bool? loading,
    String? url,
    String? title,
    bool? canGoBack,
    bool? canGoForward,
    String? error,
    bool clearError = false,
  }) {
    return BrowserAgentState(
      initialized: initialized ?? this.initialized,
      loading: loading ?? this.loading,
      url: url ?? this.url,
      title: title ?? this.title,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      error: clearError ? null : error ?? this.error,
    );
  }
}

abstract interface class BrowserAutomation {
  bool get isInitialized;
  String get currentUrl;

  Future<void> openUrl(String rawUrl, {String? downloadDirectory});
  Future<BrowserPageSnapshot> readPage({int maxCharacters = 12000});
  Future<BrowserElementInfo> describeElement(String ref);
  Future<String> click(String ref);
  Future<String> typeText(String ref, String text, {bool clear, bool submit});
  Future<String> uploadFiles(String ref, List<String> filePaths);
  Future<String> takeScreenshot(
    String outputDirectory, {
    bool fullPage = false,
  });
  Future<void> goBack();
  Future<void> goForward();
  Future<void> reload();
}

class BrowserAgentService extends ChangeNotifier implements BrowserAutomation {
  BrowserAgentService({BrowserHostLookup? hostLookup})
    : _hostLookup = hostLookup ?? InternetAddress.lookup;

  final BrowserHostLookup _hostLookup;
  BrowserAgentState _state = const BrowserAgentState();
  BrowserAgentState get state => _state;

  WebviewController? _controller;
  WebviewController? get controller => _controller;
  _CdpClient? _cdp;
  Future<void>? _initializing;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  bool _blockingNavigation = false;

  @override
  bool get isInitialized => _state.initialized;

  @override
  String get currentUrl => _state.url;

  static Future<Uri> normalizeAndValidateUrl(
    String rawUrl, {
    BrowserHostLookup? hostLookup,
  }) async {
    var value = rawUrl.trim();
    if (value.isEmpty) {
      throw const BrowserUrlPolicyException('URL browser tidak boleh kosong.');
    }
    if (!value.contains('://')) {
      final authority = value.split('/').first;
      final hostCandidate =
          Uri.tryParse('http://$authority')?.host.toLowerCase() ??
          authority.toLowerCase();
      value = '${_isLoopbackHost(hostCandidate) ? 'http' : 'https'}://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const BrowserUrlPolicyException(
        'Browser hanya menerima URL HTTP/HTTPS tanpa username atau password.',
      );
    }

    final host = uri.host.toLowerCase();
    if (_isLoopbackHost(host)) return uri;
    if (uri.scheme.toLowerCase() != 'https') {
      throw const BrowserUrlPolicyException(
        'Situs publik harus menggunakan HTTPS. HTTP hanya diizinkan untuk '
        'preview localhost.',
      );
    }
    if (host.endsWith('.local') || host.endsWith('.internal')) {
      throw const BrowserUrlPolicyException(
        'Alamat jaringan lokal atau internal tidak diizinkan.',
      );
    }

    final literal = InternetAddress.tryParse(host);
    if (literal != null && _isPrivateAddress(literal)) {
      throw const BrowserUrlPolicyException(
        'Alamat IP lokal/private tidak diizinkan.',
      );
    }

    final lookup = hostLookup ?? InternetAddress.lookup;
    List<InternetAddress> addresses;
    try {
      addresses = await lookup(host).timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const BrowserUrlPolicyException(
        'Nama host URL tidak dapat diverifikasi.',
      );
    }
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw const BrowserUrlPolicyException(
        'URL mengarah ke jaringan lokal/private dan ditolak.',
      );
    }
    return uri;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host
        .replaceFirst(RegExp(r'^\['), '')
        .replaceFirst(RegExp(r'\]$'), '');
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    return InternetAddress.tryParse(normalized)?.isLoopback ?? false;
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

  Future<void> initialize() {
    if (_state.initialized) return Future.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    if (_disposed) {
      throw const BrowserAgentException('Sesi browser sudah ditutup.');
    }
    if (!Platform.isWindows) {
      throw const BrowserAgentException(
        'Browser agent terintegrasi saat ini hanya tersedia di Windows.',
      );
    }
    _setState(_state.copyWith(loading: true, clearError: true));
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        throw const BrowserAgentException(
          'Microsoft Edge WebView2 Runtime belum terpasang.',
        );
      }

      final profileDirectory = Directory(_profileDirectory());
      await profileDirectory.create(recursive: true);
      final debugPort = await _reserveLoopbackPort();
      final origin = 'http://127.0.0.1:$debugPort';
      try {
        await WebviewController.initializeEnvironment(
          userDataPath: profileDirectory.path,
          additionalArguments:
              '--remote-debugging-port=$debugPort '
              '--remote-allow-origins=$origin',
        );
      } on PlatformException catch (error) {
        if (error.code != 'environment_already_initialized') rethrow;
      }

      final controller = WebviewController();
      await controller.initialize();
      _controller = controller;
      await controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.sameWindow,
      );
      await controller.setUserAgent('YOUNZCODE-AgentBrowser/1.3 WebView2');
      await controller.addScriptToExecuteOnDocumentCreated(
        _navigationGuardScript,
      );
      _listenToController(controller);
      _cdp = await _connectToCdp(debugPort, origin: origin);
      await _cdp?.command('Page.enable');
      await _cdp?.command('Runtime.enable');
      await _cdp?.command('DOM.enable');
      await controller.loadStringContent(_startPageHtml);
      _setState(
        _state.copyWith(
          initialized: true,
          loading: false,
          title: 'YOUNZCODE Agent Browser',
          clearError: true,
        ),
      );
    } catch (error) {
      _initializing = null;
      _setState(
        _state.copyWith(initialized: false, loading: false, error: '$error'),
      );
      rethrow;
    }
  }

  String _profileDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return path.join(base, 'YOUNZCODE', 'AgentBrowser', 'Profile');
  }

  static Future<int> _reserveLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void _listenToController(WebviewController controller) {
    _subscriptions.addAll([
      controller.url.listen((url) {
        _setState(_state.copyWith(url: url, clearError: true));
        unawaited(_validateNavigationAfterChange(url));
      }),
      controller.title.listen(
        (title) => _setState(_state.copyWith(title: title)),
      ),
      controller.loadingState.listen(
        (loading) => _setState(
          _state.copyWith(loading: loading == LoadingState.loading),
        ),
      ),
      controller.historyChanged.listen(
        (history) => _setState(
          _state.copyWith(
            canGoBack: history.canGoBack,
            canGoForward: history.canGoForward,
          ),
        ),
      ),
      controller.onLoadError.listen(
        (error) => _setState(
          _state.copyWith(loading: false, error: 'Gagal memuat: $error'),
        ),
      ),
    ]);
  }

  Future<void> _validateNavigationAfterChange(String value) async {
    if (_blockingNavigation || value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null || {'about', 'data'}.contains(uri.scheme.toLowerCase())) {
      return;
    }
    try {
      await normalizeAndValidateUrl(value, hostLookup: _hostLookup);
    } on BrowserUrlPolicyException catch (error) {
      _blockingNavigation = true;
      try {
        await _controller?.stop();
        await _controller?.loadStringContent(_blockedPageHtml(error.message));
        _setState(_state.copyWith(loading: false, error: error.message));
      } finally {
        _blockingNavigation = false;
      }
    }
  }

  @override
  Future<void> openUrl(String rawUrl, {String? downloadDirectory}) async {
    await initialize();
    final uri = await normalizeAndValidateUrl(rawUrl, hostLookup: _hostLookup);
    if (downloadDirectory != null && downloadDirectory.trim().isNotEmpty) {
      await Directory(downloadDirectory).create(recursive: true);
      try {
        await _cdp?.command('Browser.setDownloadBehavior', {
          'behavior': 'allow',
          'downloadPath': path.canonicalize(downloadDirectory),
          'eventsEnabled': true,
        });
      } catch (_) {
        // Some WebView2 builds do not expose browser-wide download behavior.
      }
    }
    _setState(_state.copyWith(loading: true, clearError: true));
    await _controller!.loadUrl(uri.toString());
  }

  @override
  Future<BrowserPageSnapshot> readPage({int maxCharacters = 12000}) async {
    await initialize();
    final limit = maxCharacters.clamp(1000, 30000);
    final raw = await _controller!.executeScript(_snapshotScript(limit));
    final data = _asMap(raw, action: 'membaca halaman');
    return BrowserPageSnapshot(
      url: '${data['url'] ?? _state.url}',
      title: '${data['title'] ?? _state.title}',
      text: '${data['text'] ?? ''}',
      elements:
          (data['elements'] as List?)
              ?.map((value) => '$value')
              .where((value) => value.trim().isNotEmpty)
              .toList() ??
          const [],
    );
  }

  @override
  Future<BrowserElementInfo> describeElement(String ref) async {
    await initialize();
    final raw = await _controller!.executeScript(_describeScript(ref));
    final data = _asMap(raw, action: 'memeriksa elemen $ref');
    if (data['found'] != true) {
      throw BrowserAgentException(
        'Elemen "$ref" tidak ditemukan. Jalankan browser_read lagi.',
      );
    }
    return BrowserElementInfo(
      ref: ref,
      tag: '${data['tag'] ?? ''}'.toLowerCase(),
      text: '${data['text'] ?? ''}'.trim(),
      type: '${data['type'] ?? ''}'.toLowerCase(),
      href: '${data['href'] ?? ''}',
      editable: data['editable'] == true,
    );
  }

  @override
  Future<String> click(String ref) async {
    final element = await describeElement(ref);
    final raw = await _controller!.executeScript(_clickScript(ref));
    if (raw != true) {
      throw BrowserAgentException(
        'Elemen "$ref" tidak dapat diklik. Jalankan browser_read lagi.',
      );
    }
    return 'Elemen $ref diklik: ${element.description}.';
  }

  @override
  Future<String> typeText(
    String ref,
    String text, {
    bool clear = true,
    bool submit = false,
  }) async {
    final element = await describeElement(ref);
    if (!element.editable) {
      throw BrowserAgentException(
        'Elemen "$ref" bukan kolom yang dapat diisi.',
      );
    }
    final raw = await _controller!.executeScript(
      _typeScript(ref, text, clear: clear, submit: submit),
    );
    if (raw != true) {
      throw BrowserAgentException(
        'Gagal mengetik ke "$ref". Jalankan browser_read lagi.',
      );
    }
    return 'Teks sepanjang ${text.length} karakter ditulis ke $ref'
        '${submit ? ' lalu Enter ditekan' : ''}.';
  }

  @override
  Future<String> uploadFiles(String ref, List<String> filePaths) async {
    await initialize();
    if (filePaths.isEmpty) {
      throw const BrowserAgentException('Daftar file upload kosong.');
    }
    final cdp = _cdp;
    if (cdp == null) {
      throw const BrowserAgentException(
        'Automation bridge browser belum tersedia untuk upload.',
      );
    }
    final selector = jsonEncode('[data-younz-ref="${_jsAttribute(ref)}"]');
    final evaluated = await cdp.command('Runtime.evaluate', {
      'expression': 'document.querySelector($selector)',
      'returnByValue': false,
    });
    final objectId = ((evaluated['result'] as Map?)?['objectId']) as String?;
    if (objectId == null) {
      throw BrowserAgentException(
        'Elemen "$ref" tidak ditemukan. Jalankan browser_read lagi.',
      );
    }
    final node = await cdp.command('DOM.requestNode', {'objectId': objectId});
    final nodeId = node['nodeId'];
    if (nodeId is! int) {
      throw const BrowserAgentException('Input file browser tidak valid.');
    }
    await cdp.command('DOM.setFileInputFiles', {
      'nodeId': nodeId,
      'files': filePaths.map(path.canonicalize).toList(),
    });
    return '${filePaths.length} file dipilih pada input $ref: '
        '${filePaths.map(path.basename).join(', ')}.';
  }

  @override
  Future<String> takeScreenshot(
    String outputDirectory, {
    bool fullPage = false,
  }) async {
    await initialize();
    final cdp = _cdp;
    if (cdp == null) {
      throw const BrowserAgentException(
        'Automation bridge browser belum tersedia untuk screenshot.',
      );
    }
    final parameters = <String, dynamic>{
      'format': 'png',
      'fromSurface': true,
      'captureBeyondViewport': fullPage,
    };
    if (fullPage) {
      final metrics = await cdp.command('Page.getLayoutMetrics');
      final size = metrics['cssContentSize'] ?? metrics['contentSize'];
      if (size is Map) {
        final width = (size['width'] as num?)?.toDouble() ?? 1280;
        final height = (size['height'] as num?)?.toDouble() ?? 720;
        parameters['clip'] = {
          'x': 0,
          'y': 0,
          'width': width.clamp(1, 20000),
          'height': height.clamp(1, 20000),
          'scale': 1,
        };
      }
    }
    final result = await cdp.command('Page.captureScreenshot', parameters);
    final encoded = result['data'];
    if (encoded is! String || encoded.isEmpty) {
      throw const BrowserAgentException('WebView2 tidak mengirim screenshot.');
    }
    final directory = Directory(outputDirectory);
    await directory.create(recursive: true);
    final timestamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final file = File(path.join(directory.path, 'browser-$timestamp.png'));
    await file.writeAsBytes(
      Uint8List.fromList(base64Decode(encoded)),
      flush: true,
    );
    return path.canonicalize(file.path);
  }

  @override
  Future<void> goBack() async {
    await initialize();
    await _controller!.goBack();
  }

  @override
  Future<void> goForward() async {
    await initialize();
    await _controller!.goForward();
  }

  @override
  Future<void> reload() async {
    await initialize();
    await _controller!.reload();
  }

  Future<void> openDevTools() async {
    await initialize();
    await _controller!.openDevTools();
  }

  Future<void> clearBrowserData() async {
    await initialize();
    await _controller!.clearCookies();
    await _controller!.clearCache();
    _setState(_state.copyWith(clearError: true));
  }

  void _setState(BrowserAgentState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _cdp?.close();
    _cdp = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }

  static Map<String, dynamic> _asMap(Object? value, {required String action}) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on FormatException {
        // The result was not a second layer of JSON encoding.
      }
    }
    throw BrowserAgentException('Browser gagal $action.');
  }

  static String _jsAttribute(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  static String _snapshotScript(int limit) =>
      '''
(() => {
  const limit = $limit;
  const isVisible = (element) => {
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.visibility !== 'hidden' && style.display !== 'none' &&
      rect.width > 0 && rect.height > 0;
  };
  document.querySelectorAll('[data-younz-ref]').forEach(
    (element) => element.removeAttribute('data-younz-ref')
  );
  const selector = [
    'a[href]', 'button', 'input', 'textarea', 'select', 'summary',
    '[role="button"]', '[role="link"]', '[role="menuitem"]',
    '[contenteditable="true"]', '[tabindex]'
  ].join(',');
  const elements = [];
  let index = 0;
  for (const element of document.querySelectorAll(selector)) {
    if (!isVisible(element) || index >= 250) continue;
    const ref = `e\${++index}`;
    element.setAttribute('data-younz-ref', ref);
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute('role') || '';
    const type = element.getAttribute('type') || '';
    const name = (
      element.getAttribute('aria-label') ||
      element.getAttribute('title') ||
      element.getAttribute('placeholder') ||
      element.innerText ||
      element.value ||
      ''
    ).replace(/\\s+/g, ' ').trim().slice(0, 180);
    const href = element.href || '';
    elements.push(
      `[ref=\${ref}] <\${tag}>` +
      (role ? ` role=\${role}` : '') +
      (type ? ` type=\${type}` : '') +
      (name ? ` "\${name}"` : '') +
      (href ? ` -> \${href}` : '')
    );
  }
  const bodyText = (document.body?.innerText || '')
    .replace(/\\n{3,}/g, '\\n\\n')
    .trim()
    .slice(0, limit);
  return {
    url: location.href,
    title: document.title,
    text: bodyText,
    elements
  };
})()
''';

  static String _describeScript(String ref) =>
      '''
(() => {
  const element = document.querySelector(
    ${jsonEncode('[data-younz-ref="${_jsAttribute(ref)}"]')}
  );
  if (!element) return {found: false};
  return {
    found: true,
    tag: element.tagName.toLowerCase(),
    type: element.getAttribute('type') || '',
    text: (
      element.getAttribute('aria-label') ||
      element.getAttribute('title') ||
      element.getAttribute('placeholder') ||
      element.innerText ||
      element.value ||
      ''
    ).replace(/\\s+/g, ' ').trim().slice(0, 240),
    href: element.href || '',
    editable: element.matches('input, textarea, [contenteditable="true"]')
  };
})()
''';

  static String _clickScript(String ref) =>
      '''
(() => {
  const element = document.querySelector(
    ${jsonEncode('[data-younz-ref="${_jsAttribute(ref)}"]')}
  );
  if (!element) return false;
  element.scrollIntoView({block: 'center', inline: 'center'});
  element.focus();
  element.click();
  return true;
})()
''';

  static String _typeScript(
    String ref,
    String text, {
    required bool clear,
    required bool submit,
  }) =>
      '''
(() => {
  const element = document.querySelector(
    ${jsonEncode('[data-younz-ref="${_jsAttribute(ref)}"]')}
  );
  if (!element) return false;
  const text = ${jsonEncode(text)};
  element.scrollIntoView({block: 'center', inline: 'center'});
  element.focus();
  if (element.isContentEditable) {
    element.textContent = ${clear ? 'text' : '(element.textContent || "") + text'};
  } else {
    const next = ${clear ? 'text' : '(element.value || "") + text'};
    const prototype = element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    if (setter) setter.call(element, next); else element.value = next;
  }
  element.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: text}));
  element.dispatchEvent(new Event('change', {bubbles: true}));
  if (${submit ? 'true' : 'false'}) {
    element.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true}));
    element.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', bubbles: true}));
    if (element.form?.requestSubmit) element.form.requestSubmit();
  }
  return true;
})()
''';

  static const _navigationGuardScript = '''
(() => {
  const allowedScheme = (value) => {
    try {
      const url = new URL(value, location.href);
      return url.protocol === 'https:' ||
        (url.protocol === 'http:' &&
          (url.hostname === 'localhost' ||
           url.hostname.endsWith('.localhost') ||
           url.hostname === '127.0.0.1' ||
           url.hostname === '::1'));
    } catch (_) {
      return false;
    }
  };
  document.addEventListener('click', (event) => {
    const anchor = event.target?.closest?.('a[href]');
    if (anchor && !allowedScheme(anchor.href)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
})()
''';

  static const _startPageHtml = '''
<!doctype html>
<html lang="id">
<meta charset="utf-8">
<title>YOUNZCODE Agent Browser</title>
<style>
  :root { color-scheme: dark; font-family: "Segoe UI", sans-serif; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: #0d1117; color: #e7ecf3; }
  main { max-width: 620px; padding: 36px; border: 1px solid #263142;
    border-radius: 16px; background: #111822; }
  h1 { font-size: 24px; margin: 0 0 12px; }
  p { color: #aeb9c9; line-height: 1.6; }
  code { color: #75aaff; }
</style>
<main>
  <h1>Agent Browser siap</h1>
  <p>Buka URL HTTPS atau preview proyek di <code>localhost</code>.
  Agent dapat membaca halaman, mengisi form, upload file workspace, dan
  mengambil screenshot sesuai kebijakan izin YOUNZCODE.</p>
</main>
</html>
''';

  static String _blockedPageHtml(String message) =>
      '''
<!doctype html>
<html lang="id">
<meta charset="utf-8">
<title>Navigasi diblokir</title>
<style>
  :root { color-scheme: dark; font-family: "Segoe UI", sans-serif; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: #0d1117; color: #e7ecf3; }
  main { max-width: 620px; padding: 36px; border: 1px solid #59352f;
    border-radius: 16px; background: #1d1413; }
  p { color: #e8b4aa; line-height: 1.6; }
</style>
<main><h1>Navigasi diblokir</h1><p>${const HtmlEscape().convert(message)}</p></main>
</html>
''';

  static Future<_CdpClient?> _connectToCdp(
    int port, {
    required String origin,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 25; attempt++) {
      try {
        final httpClient = HttpClient();
        httpClient.findProxy = (_) => 'DIRECT';
        httpClient.connectionTimeout = const Duration(seconds: 2);
        try {
          final request = await httpClient.getUrl(
            Uri.parse('http://127.0.0.1:$port/json/list'),
          );
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException('CDP HTTP ${response.statusCode}');
          }
          final targets = jsonDecode(body) as List;
          final target = targets.whereType<Map>().firstWhere(
            (item) =>
                item['type'] == 'page' &&
                item['webSocketDebuggerUrl'] is String,
            orElse: () => const {},
          );
          final socketUrl = target['webSocketDebuggerUrl'];
          if (socketUrl is String && socketUrl.isNotEmpty) {
            return _CdpClient.connect(socketUrl, origin: origin);
          }
        } finally {
          httpClient.close(force: true);
        }
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw BrowserAgentException(
      'Tidak dapat terhubung ke automation bridge WebView2'
      '${lastError == null ? '.' : ': $lastError'}',
    );
  }
}

class _CdpClient {
  _CdpClient._(this._socket) {
    _subscription = _socket.listen(
      _handleMessage,
      onError: _closeWithError,
      onDone: () => _closeWithError(
        const BrowserAgentException('Koneksi automation browser terputus.'),
      ),
    );
  }

  static Future<_CdpClient> connect(
    String socketUrl, {
    required String origin,
  }) async {
    final socket = await WebSocket.connect(
      socketUrl,
      headers: {'Origin': origin},
    );
    return _CdpClient._(socket);
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, dynamic> parameters = const {},
  ]) {
    if (_closed) {
      throw const BrowserAgentException('Automation bridge sudah ditutup.');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': parameters}));
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(id);
        throw BrowserAgentException('CDP "$method" melewati batas waktu.');
      },
    );
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = decoded['error'];
    if (error is Map) {
      completer.completeError(
        BrowserAgentException(
          'CDP error ${error['code'] ?? ''}: ${error['message'] ?? error}',
        ),
      );
      return;
    }
    completer.complete(
      Map<String, dynamic>.from(decoded['result'] as Map? ?? const {}),
    );
  }

  void _closeWithError(Object error) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const BrowserAgentException('Automation bridge ditutup.'),
        );
      }
    }
    _pending.clear();
    await _socket.close();
  }
}
