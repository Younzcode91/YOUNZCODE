import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/agent_working_palette.dart';

void main() {
  test('light mode memakai warna ThemeData', () {
    final theme = ThemeData(
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF5B2A86),
        surface: Color(0xFFFFF7FF),
        onSurface: Color(0xFF1D1B20),
        onSurfaceVariant: Color(0xFF49454F),
        outline: Color(0xFF79747E),
        error: Color(0xFFBA1A1A),
      ),
      dividerColor: const Color(0xFFCBC4D2),
    );

    final palette = AgentWorkingPalette.fromTheme(theme);

    expect(palette.background, theme.colorScheme.surface);
    expect(palette.border, theme.dividerColor);
    expect(palette.accent, theme.colorScheme.primary);
    expect(palette.activity, theme.colorScheme.primary);
    expect(palette.primaryText, theme.colorScheme.onSurface);
    expect(palette.secondaryText, theme.colorScheme.onSurfaceVariant);
    expect(palette.mutedText, theme.colorScheme.onSurfaceVariant);
    expect(palette.error, theme.colorScheme.error);
    expect(palette.orbit, theme.colorScheme.outline);
  });

  test('dark mode mempertahankan warna kartu agent', () {
    final palette = AgentWorkingPalette.fromTheme(
      ThemeData(brightness: Brightness.dark),
    );

    expect(palette.background, const Color(0xFF171A12));
    expect(palette.border, const Color(0xFF3E4432));
    expect(palette.accent, const Color(0xFFC6F269));
  });
}
