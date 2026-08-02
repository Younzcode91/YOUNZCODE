import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/interaction_flow_policy.dart';

void main() {
  group('BrowserTurnNavigationPolicy', () {
    test('kembali ke chat jika browser dibuka otomatis oleh tool', () {
      final policy = BrowserTurnNavigationPolicy();

      policy.beginTurn();
      policy.browserToolStarted(browserWasVisible: false);

      expect(policy.completeTurn(browserIsVisible: true), isTrue);
    });

    test('tetap di browser jika browser sudah dibuka manual', () {
      final policy = BrowserTurnNavigationPolicy();

      policy.beginTurn();
      policy.browserOpenedManually();
      policy.browserToolStarted(browserWasVisible: true);

      expect(policy.completeTurn(browserIsVisible: true), isFalse);
    });

    test('pilihan manual selama turn membatalkan auto-return', () {
      final policy = BrowserTurnNavigationPolicy();

      policy.beginTurn();
      policy.browserToolStarted(browserWasVisible: false);
      policy.browserOpenedManually();

      expect(policy.completeTurn(browserIsVisible: true), isFalse);
    });
  });

  test('peringatan branch utama hanya sekali per workspace dan branch', () {
    final policy = MainBranchWarningPolicy();

    expect(
      policy.shouldWarn(
        workspace: r'C:\project',
        branch: 'main',
        isMainBranch: true,
        planMode: false,
      ),
      isTrue,
    );
    policy.accept(workspace: r'C:\project', branch: 'main');
    expect(
      policy.shouldWarn(
        workspace: r'C:\project',
        branch: 'main',
        isMainBranch: true,
        planMode: false,
      ),
      isFalse,
    );
    expect(
      policy.shouldWarn(
        workspace: r'C:\other-project',
        branch: 'main',
        isMainBranch: true,
        planMode: false,
      ),
      isTrue,
    );
  });
}
