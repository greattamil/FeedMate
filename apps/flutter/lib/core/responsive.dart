import 'package:flutter/material.dart';

/// Centralized responsive design breakpoints and layout helpers for FeedMate.
/// Supports Mobile (Handheld), Tablet (Counter POS), Windows Desktop, and Web.
abstract final class ResponsiveBreakpoints {
  /// Handheld mobile devices (< 768px)
  static const double mobileMax = 767;

  /// Tablets & compact POS terminals (768px - 1099px)
  static const double tabletMin = 768;
  static const double tabletMax = 1099;

  /// Desktop (Windows, macOS, Linux) & Wide Web POS (>= 1100px)
  static const double desktopMin = 1100;

  /// Maximum container width for forms and settings to prevent over-stretching on wide monitors
  static const double maxContentWidth = 1200;
  static const double maxFormWidth = 680;
}

/// Extension on [BuildContext] for ergonomic, zero-boilerplate responsive checks.
extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  bool get isMobile => screenWidth < ResponsiveBreakpoints.tabletMin;
  bool get isTablet =>
      screenWidth >= ResponsiveBreakpoints.tabletMin &&
      screenWidth < ResponsiveBreakpoints.desktopMin;
  bool get isDesktop => screenWidth >= ResponsiveBreakpoints.desktopMin;
  bool get isWide => screenWidth >= ResponsiveBreakpoints.tabletMin;

  /// Returns value based on screen breakpoint.
  T responsive<T>({
    required T mobile,
    T? tablet,
    T? desktop,
  }) {
    if (isDesktop && desktop != null) return desktop;
    if (isTablet && tablet != null) return tablet;
    return mobile;
  }
}

/// A widget builder that adapts automatically to mobile, tablet, and desktop viewports.
class ResponsiveLayout extends StatelessWidget {
  final Widget Function(BuildContext context) mobile;
  final Widget Function(BuildContext context)? tablet;
  final Widget Function(BuildContext context)? desktop;

  const ResponsiveLayout({
    super.key,
    required this.mobile,
    this.tablet,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= ResponsiveBreakpoints.desktopMin &&
            desktop != null) {
          return desktop!(context);
        }
        if (constraints.maxWidth >= ResponsiveBreakpoints.tabletMin &&
            tablet != null) {
          return tablet!(context);
        }
        return mobile(context);
      },
    );
  }
}

/// Constrains centered content (like forms, detail cards, settings)
/// to maintain readability and avoid visual stretching on wide displays.
class ResponsiveContainer extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const ResponsiveContainer({
    super.key,
    required this.child,
    this.maxWidth = ResponsiveBreakpoints.maxContentWidth,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
