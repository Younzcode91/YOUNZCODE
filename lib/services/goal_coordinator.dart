import '../models/agent_goal.dart';

enum GoalTurnDecision { continueWorking, complete, blocked }

class GoalTurnResult {
  const GoalTurnResult({required this.answer, required this.decision});

  final String answer;
  final GoalTurnDecision decision;
}

class GoalCoordinator {
  const GoalCoordinator();

  static const maxAutoContinuations = 8;
  static const _marker = '[[YOUNZCODE_GOAL:';
  static final RegExp _markerPattern = RegExp(
    r'\[\[\s*YOUNZCODE_GOAL\s*:\s*(continue|complete|completed|blocked)\s*\]\]',
    caseSensitive: false,
  );

  String initialPrompt(String objective) =>
      '''
PERSISTENT GOAL MODE AKTIF.

Tujuan utama:
<goal>
${objective.trim()}
</goal>

Kerjakan tujuan ini secara otonom dan bertahap. Periksa proyek, lakukan
perubahan yang diperlukan, lalu verifikasi hasilnya dengan test atau build
yang relevan. Jangan berhenti hanya karena satu tahap atau satu tool selesai.

Pada baris terakhir setiap jawaban, tulis tepat satu penanda:
${_marker}continue]] bila masih ada pekerjaan yang dapat dilakukan;
${_marker}complete]] bila tujuan sudah benar-benar selesai dan terverifikasi;
${_marker}blocked]] hanya bila membutuhkan keputusan pengguna atau perubahan
eksternal yang tidak dapat Anda lakukan.

Jangan menyebutkan protokol penanda ini di bagian jawaban lain.
''';

  String continuationPrompt(AgentGoal goal) =>
      '''
Lanjutkan persistent goal berikut dari checkpoint terakhir:
<goal>
${goal.objective}
</goal>

Ini turn goal ke-${goal.turnCount + 1}. Tinjau pekerjaan dan hasil tool yang
sudah ada, lalu kerjakan langkah tersisa. Jangan mengulang pekerjaan yang
sudah terverifikasi.

Akhiri jawaban dengan tepat satu penanda:
${_marker}continue]], ${_marker}complete]], atau ${_marker}blocked]].
''';

  String resumePrompt(AgentGoal goal) =>
      '''
Lanjutkan kembali persistent goal berikut dari checkpoint yang tersimpan:
<goal>
${goal.objective}
</goal>

Periksa progres sebelumnya dan selesaikan langkah yang masih tertunda.
Akhiri jawaban dengan tepat satu penanda:
${_marker}continue]], ${_marker}complete]], atau ${_marker}blocked]].
''';

  GoalTurnResult parseAnswer(String rawAnswer) {
    final matches = _markerPattern.allMatches(rawAnswer).toList();
    final marker = matches.isEmpty
        ? 'continue'
        : (matches.last.group(1) ?? 'continue').toLowerCase();
    final decision = switch (marker) {
      'complete' || 'completed' => GoalTurnDecision.complete,
      'blocked' => GoalTurnDecision.blocked,
      _ => GoalTurnDecision.continueWorking,
    };
    final answer = rawAnswer
        .replaceAll(_markerPattern, '')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .trim();
    return GoalTurnResult(
      answer: answer.isEmpty ? 'Goal masih berjalan.' : answer,
      decision: decision,
    );
  }
}
