part of '../main.dart';

extension _BrowserWorkflow on _AgentHomePageState {
  void _openBrowser([String? url]) {
    final requestedUrl = url?.trim();
    _browserTurnNavigation.browserOpenedManually();
    _updateState(() {
      _activeFile = null;
      _searchMode = false;
      _imageGenerationMode = false;
      _browserMode = true;
      if (requestedUrl != null && requestedUrl.isNotEmpty) {
        _browserInitialUrl = requestedUrl;
      }
    });
  }
}
