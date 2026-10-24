// No-op implementation used on every platform except web (see the
// conditional import in notification_service.dart) — dart:html doesn't
// exist outside a web build, so this stub keeps the app compiling
// everywhere else while web gets the real browser-Notification-API
// implementation in web_notifier_web.dart.
typedef WebNotificationTapCallback = void Function(Map<String, String> data);

void setWebNotificationTapHandler(WebNotificationTapCallback handler) {}

void showWebNotification({
  required String title,
  required String body,
  required Map<String, String> data,
}) {}
