class BrowserTurnNavigationPolicy {
  bool _openedAutomatically = false;

  void beginTurn() {
    _openedAutomatically = false;
  }

  void browserToolStarted({required bool browserWasVisible}) {
    if (!browserWasVisible) {
      _openedAutomatically = true;
    }
  }

  void browserOpenedManually() {
    _openedAutomatically = false;
  }

  bool completeTurn({required bool browserIsVisible}) {
    final shouldReturnToChat = _openedAutomatically && browserIsVisible;
    _openedAutomatically = false;
    return shouldReturnToChat;
  }
}

class MainBranchWarningPolicy {
  final Set<String> _acceptedBranches = <String>{};

  bool shouldWarn({
    required String workspace,
    required String branch,
    required bool isMainBranch,
    required bool planMode,
  }) {
    if (planMode || !isMainBranch) return false;
    return !_acceptedBranches.contains(_key(workspace, branch));
  }

  void accept({required String workspace, required String branch}) {
    _acceptedBranches.add(_key(workspace, branch));
  }

  String _key(String workspace, String branch) => '$workspace::$branch';
}
