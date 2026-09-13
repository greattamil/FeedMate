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

  static const borderRadiusSm = BorderRadius.all(Radius.circular(radiusSm));
  static const borderRadiusMd = BorderRadius.all(Radius.circular(radiusMd));
  static const borderRadiusLg = BorderRadius.all(Radius.circular(radiusLg));
  static const borderRadiusXl = BorderRadius.all(Radius.circular(radiusXl));
  static const borderRadiusFull = BorderRadius.all(Radius.circular(radiusFull));

  // Layered Soft Shadows
  static const cardShadow = [
    BoxShadow(
      color: Color(0x080F172A),
      blurRadius: 16,
      offset: Offset(0, 4),
      spreadRadius: 0,
    ),
    BoxShadow(
      color: Color(0x040F172A),
      blurRadius: 4,
      offset: Offset(0, 1),
      spreadRadius: 0,
    ),
  ];

  static const floatingShadow = [
    BoxShadow(
      color: Color(0x140F172A),
      blurRadius: 24,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];

  static const modalShadow = [
    BoxShadow(
      color: Color(0x280F172A),
      blurRadius: 36,
      offset: Offset(0, 16),
      spreadRadius: -4,
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
