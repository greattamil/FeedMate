// Handles push delivery while the FeedMate tab isn't open/focused — the
// browser equivalent of Android's automatic system-tray display when the
// app is backgrounded. Auto-discovered and registered by the
// firebase_messaging Flutter web plugin (no manual registration call
// needed); must live at the site root, so this file ships from
// apps/flutter/web/ unmodified by the Flutter build.
//
// Deliberately minimal: just initializing the SDK here is enough. The
// compat library's own default behavior already auto-displays a
// background "notification" payload AND wires up click-to-focus/open,
// which is what makes FirebaseMessaging.onMessageOpenedApp /
// getInitialMessage() fire correctly on the Dart side (see
// lib/core/notification_service.dart) — adding a custom
// onBackgroundMessage/notificationclick handler here would replace that
// built-in routing, not add to it, so this intentionally does neither.
//
// Config here is duplicated from lib/core/firebase_options_web.dart — this
// file runs as a plain JS service worker, outside the Flutter/Dart bundle
// entirely, so it can't import that Dart constant. Keep the two in sync by
// hand if the Firebase project/app ever changes.
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBvLwrWjMJFDnzw3-TQRgVieP39DhdiBwA',
  appId: '1:794548234279:web:12fc1deb2d1acc1f424602',
  messagingSenderId: '794548234279',
  projectId: 'project-29fdd88b-c856-4839-907',
  authDomain: 'project-29fdd88b-c856-4839-907.firebaseapp.com',
  storageBucket: 'project-29fdd88b-c856-4839-907.firebasestorage.app',
});

firebase.messaging();
