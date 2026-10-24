import 'package:flutter/foundation.dart';

/// A tiny shared channel for surfacing push-notification setup failures to
/// the user, without main.dart and auth_session.dart needing to import
/// each other (main.dart already imports auth_session.dart). Push failures
/// are deliberately never fatal anywhere in this app (see
/// AuthSession._registerPushToken's doc comment), but "never fatal" had
/// come to mean "never visible to anyone without DevTools open" — which
/// made a real production bug (a browser silently never showing the
/// permission prompt at all) undiagnosable from the outside. This exists
/// so the same failure instead shows up as a plain on-screen message.
class PushDiagnostics {
  PushDiagnostics._();

  /// Fires once per failure; main.dart's _SessionGate listens and shows it
  /// via the global SnackBar mechanism once a ScaffoldMessenger exists.
  static final ValueNotifier<String?> lastError = ValueNotifier(null);

  static void report(String context, Object error) {
    lastError.value = '$context: $error';
  }
}
