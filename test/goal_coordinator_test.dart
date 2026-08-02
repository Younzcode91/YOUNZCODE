import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/agent_goal.dart';
import 'package:kode_agent_desktop/services/goal_coordinator.dart';

void main() {
  const coordinator = GoalCoordinator();

  test('prompt goal meminta status eksplisit untuk auto-continue', () {
    final prompt = coordinator.initialPrompt('Selesaikan seluruh test');

    expect(prompt, contains('Selesaikan seluruh test'));
    expect(prompt, contains('[[YOUNZCODE_GOAL:continue]]'));
    expect(prompt, contains('[[YOUNZCODE_GOAL:complete]]'));
    expect(prompt, contains('[[YOUNZCODE_GOAL:blocked]]'));
  });

  test('marker complete disembunyikan dari jawaban pengguna', () {
    final result = coordinator.parseAnswer(
      'Semua test lulus.\n[[YOUNZCODE_GOAL:complete]]',
    );

    expect(result.decision, GoalTurnDecision.complete);
    expect(result.answer, 'Semua test lulus.');
    expect(result.answer, isNot(contains('YOUNZCODE_GOAL')));
  });

  test('jawaban tanpa marker dilanjutkan secara konservatif', () {
    final result = coordinator.parseAnswer('Masih memeriksa build.');

    expect(result.decision, GoalTurnDecision.continueWorking);
    expect(result.answer, 'Masih memeriksa build.');
  });

  test('resume prompt membawa objective dan nomor turn berikutnya', () {
    final goal = AgentGoal(
      objective: 'Perbaiki seluruh regresi',
      status: AgentGoalStatus.paused,
      turnCount: 4,
      updatedAt: DateTime(2026, 7, 29),
    );

    expect(coordinator.resumePrompt(goal), contains(goal.objective));
    expect(coordinator.continuationPrompt(goal), contains('turn goal ke-5'));
  });
}
