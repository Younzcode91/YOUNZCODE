import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('bundles i-have-adhd and Open Generative AI integrations', () {
    final adhd = File(p.join('skills', 'i-have-adhd', 'SKILL.md'));
    final openGen = File(
      p.join('skills', 'open-generative-ai', 'SKILL.md'),
    );

    expect(adhd.existsSync(), isTrue);
    expect(openGen.existsSync(), isTrue);
    expect(adhd.readAsStringSync(), contains('name: i-have-adhd'));
    expect(
      openGen.readAsStringSync(),
      contains('name: open-generative-ai'),
    );
  });

  test('Open Generative AI installer is pinned and hash verified', () {
    final script = File(
      p.join(
        'skills',
        'open-generative-ai',
        'scripts',
        'install-windows.ps1',
      ),
    ).readAsStringSync();

    expect(script, contains(r'$Version = "1.0.9"'));
    expect(
      script,
      contains(
        'f445033534e59332ca9a46310dbc4230acf282c42b3d0bfe11fbe09a6985c144',
      ),
    );
    expect(script, contains('Get-FileHash'));
    expect(script, contains('SHA256 mismatch'));
    expect(script, isNot(contains('Invoke-Expression')));
    expect(
      script.indexOf('Invoke-WebRequest'),
      lessThan(script.indexOf('Get-FileHash')),
    );
    expect(
      script.indexOf('Get-FileHash'),
      lessThan(script.indexOf('Start-Process')),
    );
    expect(
      script,
      contains(
        'releases/download/v\$Version/\$AssetName',
      ),
    );
  });

  test('release and Windows installer package all bundled skills', () {
    final releaseWorkflow = File(
      p.join('.github', 'workflows', 'release.yml'),
    ).readAsStringSync();
    final installer = File(
      p.join('installer', 'YOUNZCODE.iss'),
    ).readAsStringSync();

    expect(releaseWorkflow, contains('cp -r skills release/skills'));
    expect(installer, contains('Source: "..\\skills\\*"'));
    expect(installer, contains('DestDir: "{app}\\skills"'));
    expect(installer, contains('recursesubdirs createallsubdirs'));
    expect(
      releaseWorkflow,
      contains('test/bundled_integrations_test.dart'),
    );
  });

  test('bundled integrations record source commit and license', () {
    final adhdSkill = File(
      p.join('skills', 'i-have-adhd', 'SKILL.md'),
    ).readAsStringSync();
    final adhdSource = File(
      p.join('skills', 'i-have-adhd', 'SOURCE.md'),
    ).readAsStringSync();
    final openGenSource = File(
      p.join('skills', 'open-generative-ai', 'SOURCE.md'),
    ).readAsStringSync();

    expect(
      adhdSource,
      contains('2ed064090711586e0c97a2fbbf15465fe8f1808b'),
    );
    expect(
      openGenSource,
      contains('81a179ed168504562d01f2d95f91cc9798ccaabd'),
    );
    expect(
      openGenSource,
      contains('9a742f6645a336295e74bce7d7153145dc48fd5d'),
    );
    expect(
      adhdSkill,
      contains(r'Authorization: Bearer ${token}`'),
    );
    final adhdLicense = File(
      p.join('skills', 'i-have-adhd', 'LICENSE'),
    ).readAsStringSync();
    expect(adhdLicense, contains('Copyright (c) 2026 Ayoub Ghriss'));
    expect(
      File(
        p.join('skills', 'open-generative-ai', 'LICENSE'),
      ).readAsStringSync(),
      contains('Copyright (c) 2026 Open Generative AI Contributors'),
    );
  });
}
