import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/process_launch.dart';

void main() {
  test('executable .exe tidak diubah dan argumen tetap literal', () {
    final launch = resolveProcessLaunch(r'C:\tools\server.exe', ['a & b.py']);

    expect(launch.executable, r'C:\tools\server.exe');
    expect(launch.arguments, ['a & b.py']);
  });

  test('batch wrapper .bat diluncurkan via cmd tanpa parsing argumen', () {
    final launch = resolveProcessLaunch(
      r'C:\flutter\bin\flutter.bat',
      ['test', 'test/a & b_test.dart', '--concurrency=1'],
    );

    expect(launch.executable, 'cmd.exe');
    expect(launch.arguments, [
      '/d',
      '/c',
      r'C:\flutter\bin\flutter.bat',
      'test',
      'test/a & b_test.dart',
      '--concurrency=1',
    ]);
  });

  test('batch wrapper .cmd relatif diluncurkan via cmd dari working directory',
      () {
    final launch = resolveProcessLaunch('scripts/server.cmd', ['a & b.py']);

    expect(launch.executable, 'cmd.exe');
    expect(launch.arguments, ['/d', '/c', 'scripts/server.cmd', 'a & b.py']);
  });

  test('file PE tanpa ekstensi di PATH diluncurkan langsung',
      () async {
        final dir = await Directory.systemTemp.createTemp('younz-launch-');
        addTearDown(() => dir.delete(recursive: true));
        final bare = File(
          '${dir.path}${Platform.pathSeparator}my_tool',
        );
        await bare.writeAsBytes([0x4D, 0x5A, 0x90, 0x00]);

        final launch = resolveProcessLaunch('my_tool', ['x'], searchPath: dir.path);

        expect(launch.executable, bare.path);
      },
      skip: !Platform.isWindows);

  test('nama tanpa ekstensi di PATH memilih .exe sebelum .bat', () async {
    final dir = await Directory.systemTemp.createTemp('younz-launch-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = File('${dir.path}${Platform.pathSeparator}my_tool.exe');
    await exe.writeAsBytes([0x4D, 0x5A, 0x90, 0x00]);
    await File('${dir.path}${Platform.pathSeparator}my_tool.bat').writeAsString(
      '@echo off\r\n',
    );

    final launch = resolveProcessLaunch('my_tool', ['x'], searchPath: dir.path);

    expect(launch.executable, exe.path);
  }, skip: !Platform.isWindows);

  test('nama tanpa ekstensi di PATH: .bat dipilih dan dibungkus cmd', () async {
    final dir = await Directory.systemTemp.createTemp('younz-launch-');
    addTearDown(() => dir.delete(recursive: true));
    final bat = File('${dir.path}${Platform.pathSeparator}my_tool.bat');
    await bat.writeAsString('@echo off\r\n');

    final launch = resolveProcessLaunch(
      'my_tool',
      ['a & b.py'],
      searchPath: dir.path,
    );

    expect(launch.executable, 'cmd.exe');
    expect(launch.arguments, ['/d', '/c', bat.path, 'a & b.py']);
  }, skip: !Platform.isWindows);

  test('skrip shebang tanpa ekstensi dilewati, .bat di PATH dipakai', () async {
    final dir = await Directory.systemTemp.createTemp('younz-launch-');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}${Platform.pathSeparator}my_tool').writeAsString(
      '#!/usr/bin/env bash\n',
    );
    final bat = File('${dir.path}${Platform.pathSeparator}my_tool.bat');
    await bat.writeAsString('@echo off\r\n');

    final launch = resolveProcessLaunch('my_tool', ['x'], searchPath: dir.path);

    expect(launch.executable, 'cmd.exe');
    expect(launch.arguments, ['/d', '/c', bat.path, 'x']);
  }, skip: !Platform.isWindows);

  test('nama tidak ditemukan di PATH dikembalikan apa adanya', () {
    final launch = resolveProcessLaunch('definitely_missing_tool', ['x']);

    expect(launch.executable, 'definitely_missing_tool');
    expect(launch.arguments, ['x']);
  }, skip: !Platform.isWindows);
}
