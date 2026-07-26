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

  test(
    'dark mode juga memakai warna ThemeData (bukan palet lime terpisah)',
    () {
      final theme = ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5B9DFF),
          surface: Color(0xFF10151D),
          onSurface: Color(0xFFE7ECF3),
          onSurfaceVariant: Color(0xFF9AA7B8),
          outline: Color(0xFF232C39),
          error: Color(0xFFEC6A55),
        ),
        dividerColor: const Color(0xFF232C39),
      );

      final palette = AgentWorkingPalette.fromTheme(theme);

      // The agent-working card now lives in the same theme world as the app —
      // a single blue accent, not a separate lime/teal palette.
      expect(palette.background, theme.colorScheme.surface);
      expect(palette.border, theme.dividerColor);
      expect(palette.accent, theme.colorScheme.primary);
      expect(palette.activity, theme.colorScheme.primary);
      expect(palette.primaryText, theme.colorScheme.onSurface);
      expect(palette.orbit, theme.colorScheme.outline);
    },
  );
}
