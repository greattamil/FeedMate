import 'package:flutter/material.dart';

/// Semantic chromatic color palette for FeedMate.
/// Inspired by modern agricultural fintech and high-contrast retail POS systems.
abstract final class AppColors {
  // Brand / Emerald Primary
  static const primary = Color(0xFF0F766E); // Deep Teal Emerald
  static const primaryLight = Color(0xFF10B981); // Vibrant Mint Green
  static const primaryDark = Color(0xFF064E3B); // Deep Forest Pine
  static const primaryContainer = Color(0xFFE6F4EA); // Soft Mint Surface Tint
  static const onPrimaryContainer = Color(0xFF064E3B);

  // Secondary / Royal Indigo
  static const secondary = Color(0xFF4F46E5); // Royal Indigo
  static const secondaryLight = Color(0xFF6366F1);
  static const secondaryContainer = Color(0xFFEEF2FF);
  static const onSecondaryContainer = Color(0xFF312E81);

  // Accent / Cyan & Sky
  static const accent = Color(0xFF0EA5E9);
  static const accentContainer = Color(0xFFE0F2FE);

  // Semantic Status Colors
  static const success = Color(0xFF059669); // Cash Inflow, Paid, Received
  static const successContainer = Color(0xFFD1FAE5);
  static const onSuccessContainer = Color(0xFF065F46);

  static const danger = Color(0xFFE11D48); // Over-limit debt, short variance, rejection
  static const dangerLight = Color(0xFFFB7185);
  static const dangerContainer = Color(0xFFFFE4E6);
  static const onDangerContainer = Color(0xFF9F1239);

  static const warning = Color(0xFFD97706); // Offline mode, near-expiry, pending
  static const warningLight = Color(0xFFF59E0B);
  static const warningContainer = Color(0xFFFEF3C7);
  static const onWarningContainer = Color(0xFF92400E);

  static const info = Color(0xFF2563EB); // Informational, Cloud Sync, Reports
  static const infoContainer = Color(0xFFDBEAFE);
  static const onInfoContainer = Color(0xFF1E40AF);

  // Neutral Canvas & Surfaces
  static const background = Color(0xFFF8FAFC); // Ultra-clean subtle slate tint
  static const surface = Color(0xFFFFFFFF); // Pure white card
  static const surfaceSecondary = Color(0xFFF1F5F9); // Input fills, chip backgrounds
  static const surfaceTertiary = Color(0xFFE2E8F0); // Subtle dividers, inactive lines

  // Border & Hairlines
  static const border = Color(0xFFE2E8F0);
  static const borderFocused = Color(0xFF0F766E);
  static const borderSubtle = Color(0xFFF1F5F9);

  // Text Colors
  static const textPrimary = Color(0xFF0F172A); // High-contrast Slate 900
  static const textSecondary = Color(0xFF64748B); // Slate 500
  static const textTertiary = Color(0xFF94A3B8); // Slate 400
  static const textOnPrimary = Color(0xFFFFFFFF);

  // Gradients
  static const gradientEmerald = LinearGradient(
    colors: [Color(0xFF0F766E), Color(0xFF059669)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientIndigo = LinearGradient(
    colors: [Color(0xFF4F46E5), Color(0xFF3B82F6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientAmber = LinearGradient(
    colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientRose = LinearGradient(
    colors: [Color(0xFFE11D48), Color(0xFFBE123C)],
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
