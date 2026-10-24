// Web's actual foreground-notification display. flutter_local_notifications
// (used on Android — see notification_service.dart) has no web support at
// all, so foreground pushes on web go through the browser's native
// Notification API directly instead. Background/tab-closed delivery is
// handled entirely by web/firebase-messaging-sw.js, a plain JS service
// worker outside the Flutter/Dart runtime — this file only covers the
// "tab is open and focused" case, mirroring Android's onMessage path.
import 'dart:html' as html;

typedef WebNotificationTapCallback = void Function(Map<String, String> data);

WebNotificationTapCallback? _tapHandler;

void setWebNotificationTapHandler(WebNotificationTapCallback handler) {
  _tapHandler = handler;
}

void showWebNotification({
  required String title,
  required String body,
  required Map<String, String> data,
}) {
  if (html.Notification.permission != 'granted') return;
  final notification = html.Notification(title, body: body, tag: data['invoice_id'] ?? data['product_id'] ?? title);
  notification.onClick.listen((_) {
    notification.close();
    _tapHandler?.call(data);
  });
}
