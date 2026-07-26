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

  // Derived entirely from the theme so the agent-working card lives in the
  // same calm, single-blue-accent world as the rest of the app — no separate
  // lime/teal palette competing with the accent.
  factory AgentWorkingPalette.fromTheme(ThemeData theme) {
    final colors = theme.colorScheme;
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
