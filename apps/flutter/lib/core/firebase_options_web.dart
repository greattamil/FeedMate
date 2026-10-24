import 'package:firebase_core/firebase_core.dart';

/// Explicit Firebase config for web — unlike Android (auto-configured from
/// google-services.json at build time), web has no equivalent build-time
/// file, so Firebase.initializeApp() needs these values passed directly.
/// All of them (including apiKey) are meant to be public — Firebase's web
/// security model relies on Firebase Security Rules / App Check, not on
/// keeping this config secret; this is the same config
/// `firebase apps:sdkconfig WEB` prints, safe to commit.
///
/// Registered via `firebase apps:create WEB "FeedMate Web"` against the
/// same Firebase project the Android app already uses
/// (project-29fdd88b-c856-4839-907) — one project, two registered apps.
const webFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyBvLwrWjMJFDnzw3-TQRgVieP39DhdiBwA',
  appId: '1:794548234279:web:12fc1deb2d1acc1f424602',
  messagingSenderId: '794548234279',
  projectId: 'project-29fdd88b-c856-4839-907',
  authDomain: 'project-29fdd88b-c856-4839-907.firebaseapp.com',
  storageBucket: 'project-29fdd88b-c856-4839-907.firebasestorage.app',
);

/// Web Push certificate key (VAPID) for this Firebase project — generated
/// once via Firebase Console → Project Settings → Cloud Messaging → Web
/// Push certificates (no public API exposes this, only the console UI).
/// Passed to FirebaseMessaging.getToken() on web only; Android ignores it.
const webVapidKey = 'BITTzPMsno4AmaDEeYrsvyZzrRbzNoWoWZRhh1Z_UMRIDN3xhphIU7HS-tzV3YX59Q6-Ul2tKZrhrUyGDrPW-7I';
