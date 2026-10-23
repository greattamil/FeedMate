import 'package:flutter/material.dart';

/// Semantic chromatic color palette for FeedMate.
/// Inspired by modern agricultural fintech and high-contrast retail POS systems.
abstract final class AppColors {
  // Brand / Emerald Primary (Vibrant Mint to Deep Forest)
  static const primary = Color(0xFF0D9488); // Modern Bright Teal / Emerald
  static const primaryLight = Color(0xFF10B981); // Vivid Mint Green
  static const primaryDark = Color(0xFF042F2E); // Rich Deep Pine
  static const primaryContainer = Color(0xFFCCFBF1); // Soft Fresh Mint Surface Tint
  static const onPrimaryContainer = Color(0xFF0F766E);

  // Secondary / Electric Indigo & Royal Blue
  static const secondary = Color(0xFF4F46E5); // Royal Indigo
  static const secondaryLight = Color(0xFF6366F1); // Vivid Lavender Indigo
  static const secondaryDark = Color(0xFF312E81);
  static const secondaryContainer = Color(0xFFEEF2FF);
  static const onSecondaryContainer = Color(0xFF3730A3);

  // Accent / Electric Cyan & Sky
  static const accent = Color(0xFF0284C7); // Vivid Sky Blue
  static const accentLight = Color(0xFF38BDF8);
  static const accentContainer = Color(0xFFE0F2FE);
  static const onAccentContainer = Color(0xFF0369A1);

  // Semantic Status Colors
  static const success = Color(0xFF059669); // Emerald: Cash Inflow, Paid, Received
  static const successLight = Color(0xFF34D399);
  static const successContainer = Color(0xFFD1FAE5);
  static const onSuccessContainer = Color(0xFF065F46);

  // Danger & Alerts (Rose & Crimson)
  static const danger = Color(0xFFE11D48); // Rose Ruby: Over-limit debt, short variance
  static const dangerLight = Color(0xFFFB7185);
  static const dangerContainer = Color(0xFFFFE4E6);
  static const onDangerContainer = Color(0xFF9F1239);

  // Warning & Drawer Floats (Warm Amber & Tangerine)
  static const warning = Color(0xFFD97706); // Amber: Near-expiry, drawer float, pending
  static const warningLight = Color(0xFFFBBF24);
  static const warningContainer = Color(0xFFFEF3C7);
  static const onWarningContainer = Color(0xFF92400E);

  // Info & Sync (Cobalt & Sapphire)
  static const info = Color(0xFF2563EB); // Informational, Cloud Sync, Reports
  static const infoLight = Color(0xFF60A5FA);
  static const infoContainer = Color(0xFFDBEAFE);
  static const onInfoContainer = Color(0xFF1E40AF);

  // Neutral Canvas & Surfaces
  static const background = Color(0xFFF8FAFC); // Subtle slate-tinted canvas
  static const surface = Color(0xFFFFFFFF); // Pure white card
  static const surfaceSecondary = Color(0xFFF1F5F9); // Input fills, chip backgrounds
  static const surfaceTertiary = Color(0xFFE2E8F0); // Subtle dividers, inactive lines
  static const surfaceElevated = Color(0xFFFFFFFF); // High-elevation cards
  static const surfaceHover = Color(0xFFF8FAFC); // Desktop mouse hover state

  // Border & Hairlines
  static const border = Color(0xFFE2E8F0);
  static const borderFocused = Color(0xFF0D9488);
  static const borderSubtle = Color(0xFFF1F5F9);

  // Text Colors
  static const textPrimary = Color(0xFF0F172A); // High-contrast Slate 900
  static const textSecondary = Color(0xFF64748B); // Slate 500
  static const textTertiary = Color(0xFF94A3B8); // Slate 400
  static const textOnPrimary = Color(0xFFFFFFFF);

  // Gradients
  static const gradientEmerald = LinearGradient(
    colors: [Color(0xFF0D9488), Color(0xFF059669)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientIndigo = LinearGradient(
    colors: [Color(0xFF4F46E5), Color(0xFF2563EB)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientAmber = LinearGradient(
    colors: [Color(0xFFF59E0B), Color(0xFFEA580C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientRose = LinearGradient(
    colors: [Color(0xFFE11D48), Color(0xFFBE123C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientCyan = LinearGradient(
    colors: [Color(0xFF0284C7), Color(0xFF06B6D4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientPurple = LinearGradient(
    colors: [Color(0xFF7C3AED), Color(0xFF9333EA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientTealCyan = LinearGradient(
    colors: [Color(0xFF0F766E), Color(0xFF0284C7)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientSunset = LinearGradient(
    colors: [Color(0xFFF43F5E), Color(0xFFFB923C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientHeroMesh = LinearGradient(
    colors: [Color(0xFF042F2E), Color(0xFF0F766E), Color(0xFF0E7490)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientCard = LinearGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFF8FAFC)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const gradientDark = LinearGradient(
    colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
