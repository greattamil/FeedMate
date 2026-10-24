import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../features/customers/customer_list_screen.dart';
import '../features/pos/invoice_detail_screen.dart';
import '../features/reports/stock_management_screen.dart';
import 'web_notifier_stub.dart' if (dart.library.html) 'web_notifier_web.dart' as web_notifier;

/// Three Android notification channels, one per urgency/category, created
/// once at startup. Channel IDs must match exactly what
/// internal/domain/notify.Service (Go backend) sends as both
/// android.notification.channel_id and data.channel_id — the two
/// definitions are kept in sync by hand, there is no shared source of
/// truth across the Go/Dart boundary.
class NotificationChannels {
  static const salesBilling = AndroidNotificationChannel(
    'sales_billing',
    'Sales & Billing',
    description: 'Completed and credit sales.',
    importance: Importance.defaultImportance,
  );
  static const creditAlerts = AndroidNotificationChannel(
    'credit_alerts',
    'Credit Alerts',
    description: 'Credit limit exceeded and overdue payment reminders.',
    importance: Importance.high,
  );
  static const stockAlerts = AndroidNotificationChannel(
    'stock_alerts',
    'Stock Alerts',
    description: 'Low stock and out-of-stock notices.',
    importance: Importance.high,
  );

  static const all = [salesBilling, creditAlerts, stockAlerts];

  static AndroidNotificationChannel byId(String? id) =>
      all.firstWhere((c) => c.id == id, orElse: () => salesBilling);
}

/// Required by the firebase_messaging plugin contract: a background-message
/// handler must be a top-level (or static) function annotated
/// vm:entry-point, since FCM runs it in its own isolate when the app isn't
/// in the foreground. System-tray display for a background/terminated-state
/// message is already handled automatically by Android's own FCM
/// integration (see AndroidManifest.xml's default_notification_channel_id
/// meta-data) — this handler exists to satisfy the plugin's registration
/// requirement, not to do any extra display work itself.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundMessageHandler(RemoteMessage message) async {
  debugPrint('Background FCM message received: ${message.messageId}');
}

/// Owns FCM display and tap-routing end to end. Before this, a push
/// landing while the app was open showed nothing at all (FCM's
/// "notification" payload only auto-displays via the system tray when
/// backgrounded/killed — a deliberate v1 gap when push was first built).
/// This closes that gap by showing a real system notification through
/// flutter_local_notifications on every foreground message, and routes a
/// tap — foreground, background, or a cold start from a fully terminated
/// state — to the screen the event is actually about.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _localNotifications = FlutterLocalNotificationsPlugin();
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _initialized = false;

  Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_initialized) return;
    _initialized = true;
    _navigatorKey = navigatorKey;

    if (kIsWeb) {
      // flutter_local_notifications has no web support at all — foreground
      // display there goes through the browser's native Notification API
      // instead (web_notifier_web.dart), wired up here only for tap
      // routing; showWebNotification() builds/shows the notification
      // itself when a message arrives.
      web_notifier.setWebNotificationTapHandler(_handleTap);
    } else {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _localNotifications.initialize(
        const InitializationSettings(android: androidInit),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null || payload.isEmpty) return;
          try {
            final decoded = jsonDecode(payload) as Map<String, dynamic>;
            _handleTap(decoded.map((k, v) => MapEntry(k, v.toString())));
          } catch (_) {
            // A malformed/stale payload must never crash a notification tap.
          }
        },
      );

      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      for (final channel in NotificationChannels.all) {
        await androidPlugin?.createNotificationChannel(channel);
      }
    }

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleTap(_stringData(message)));

    // Covers a cold start: the app was fully terminated and the user
    // tapped a notification to launch it, rather than onMessageOpenedApp
    // firing (which only fires for background-not-terminated).
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _handleTap(_stringData(initialMessage));
    }
  }

  Map<String, String> _stringData(RemoteMessage message) =>
      message.data.map((key, value) => MapEntry(key, value.toString()));

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    if (kIsWeb) {
      web_notifier.showWebNotification(
        title: notification.title ?? 'FeedMate',
        body: notification.body ?? '',
        data: _stringData(message),
      );
      return;
    }
    final channel = NotificationChannels.byId(message.data['channel_id']);
    await _localNotifications.show(
      message.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  /// Switches on data['type'] (set by the Go backend's notify.Service call
  /// sites — see pos.Service.FinalizeInvoice and the overdue-sweep cron
  /// handler) and pushes the matching screen. Unknown/missing types are a
  /// deliberate no-op rather than an error: a push whose data the app
  /// can't route must never crash or show a broken screen.
  void _handleTap(Map<String, String> data) {
    final navigator = _navigatorKey?.currentState;
    if (navigator == null) return;
    switch (data['type']) {
      case 'invoice':
        final invoiceId = data['invoice_id'];
        if (invoiceId != null) {
          navigator.push(MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: invoiceId)));
        }
        break;
      case 'product':
        navigator.push(MaterialPageRoute(builder: (_) => const StockManagementScreen()));
        break;
      case 'overdue_summary':
        navigator.push(MaterialPageRoute(builder: (_) => const CustomerListScreen()));
        break;
    }
  }
}
