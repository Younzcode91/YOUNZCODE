import 'package:flutter/material.dart';

@immutable
class AgentWorkingPalette {
  const AgentWorkingPalette({
    required this.background,
    required this.border,
    required this.accent,
    required this.activity,
    required this.primaryText,
    required this.secondaryText,
    required this.mutedText,
    required this.error,
    required this.orbit,
  });

  factory AgentWorkingPalette.fromTheme(ThemeData theme) {
    final colors = theme.colorScheme;
    if (theme.brightness == Brightness.light) {
      return AgentWorkingPalette(
        background: colors.surface,
        border: theme.dividerColor,
        accent: colors.primary,
        activity: colors.primary,
        primaryText: colors.onSurface,
        secondaryText: colors.onSurfaceVariant,
        mutedText: colors.onSurfaceVariant,
        error: colors.error,
        orbit: colors.outline,
      );
    }
    return const AgentWorkingPalette(
      background: Color(0xFF171A12),
      border: Color(0xFF3E4432),
      accent: Color(0xFFC6F269),
      activity: Color(0xFF79D6CD),
      primaryText: Color(0xFFE2E4D5),
      secondaryText: Color(0xFFC4C9B2),
      mutedText: Color(0xFF8E937F),
      error: Color(0xFFFF7B72),
      orbit: Color(0xFF444938),
    );
  }

  final Color background;
  final Color border;
  final Color accent;
  final Color activity;
  final Color primaryText;
  final Color secondaryText;
  final Color mutedText;
  final Color error;
  final Color orbit;
}
