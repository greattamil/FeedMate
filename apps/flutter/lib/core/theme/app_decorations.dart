import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Centralized radii, shadows, borders, and card decorations for FeedMate.
abstract final class AppDecorations {
  // Border Radii
  static const radiusXs = 6.0;
  static const radiusSm = 10.0;
  static const radiusMd = 14.0;
  static const radiusLg = 18.0;
  static const radiusXl = 24.0;
  static const radiusFull = 999.0;

  static const borderRadiusXs = BorderRadius.all(Radius.circular(radiusXs));
  static const borderRadiusSm = BorderRadius.all(Radius.circular(radiusSm));
  static const borderRadiusMd = BorderRadius.all(Radius.circular(radiusMd));
  static const borderRadiusLg = BorderRadius.all(Radius.circular(radiusLg));
  static const borderRadiusXl = BorderRadius.all(Radius.circular(radiusXl));
  static const borderRadiusFull = BorderRadius.all(Radius.circular(radiusFull));

  // Layered Soft Ambient Shadows (Material 3 & iOS inspired)
  static const cardShadow = [
    BoxShadow(
      color: Color(0x0A0F172A),
      blurRadius: 18,
      offset: Offset(0, 4),
      spreadRadius: 0,
    ),
    BoxShadow(
      color: Color(0x050F172A),
      blurRadius: 6,
      offset: Offset(0, 1),
      spreadRadius: 0,
    ),
  ];

  static const elevatedCardShadow = [
    BoxShadow(
      color: Color(0x120F172A),
      blurRadius: 24,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
    BoxShadow(
      color: Color(0x060F172A),
      blurRadius: 8,
      offset: Offset(0, 2),
      spreadRadius: 0,
    ),
  ];

  static const floatingShadow = [
    BoxShadow(
      color: Color(0x180F172A),
      blurRadius: 28,
      offset: Offset(0, 10),
      spreadRadius: -2,
    ),
  ];

  static const modalShadow = [
    BoxShadow(
      color: Color(0x300F172A),
      blurRadius: 40,
      offset: Offset(0, 18),
      spreadRadius: -4,
    ),
  ];

  // Vibrant Glow Shadows for High-Impact Cards & Buttons
  static const emeraldGlow = [
    BoxShadow(
      color: Color(0x350D9488),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const indigoGlow = [
    BoxShadow(
      color: Color(0x354F46E5),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const roseGlow = [
    BoxShadow(
      color: Color(0x35E11D48),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const amberGlow = [
    BoxShadow(
      color: Color(0x35F59E0B),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const cyanGlow = [
    BoxShadow(
      color: Color(0x350284C7),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const purpleGlow = [
    BoxShadow(
      color: Color(0x357C3AED),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  // Card Decoration
  static BoxDecoration card({
    Color? color,
    Border? border,
    BorderRadius? borderRadius,
    List<BoxShadow>? shadows,
    Gradient? gradient,
  }) {
    return BoxDecoration(
      color: gradient == null ? (color ?? AppColors.surface) : null,
      gradient: gradient,
      borderRadius: borderRadius ?? borderRadiusMd,
      border: border ?? Border.all(color: AppColors.border, width: 1),
      boxShadow: shadows ?? cardShadow,
    );
  }

  // Hover Card Decoration (Desktop / Web)
  static BoxDecoration hoverCard({
    Color? color,
    BorderRadius? borderRadius,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surfaceHover,
      borderRadius: borderRadius ?? borderRadiusMd,
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.3), width: 1.2),
      boxShadow: elevatedCardShadow,
    );
  }

  // Glassmorphic / Acrylic Container
  static BoxDecoration glass({
    Color? color,
    BorderRadius? borderRadius,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surface.withValues(alpha: 0.85),
      borderRadius: borderRadius ?? borderRadiusLg,
      border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
      boxShadow: cardShadow,
    );
  }

  // Pill Decoration
  static BoxDecoration pill({
    required Color color,
    Border? border,
  }) {
    return BoxDecoration(
      color: color,
      borderRadius: borderRadiusFull,
      border: border,
    );
  }
}
