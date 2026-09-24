// PLACEHOLDER — regenerate this file once a real Firebase project exists.
//
// FR5.1 (push-woken incoming calls) uses Firebase Cloud Messaging on
// Android only (iOS's call-wake path goes through flutter_callkit_incoming's
// own PushKit registration — no Firebase involved there at all; see
// lib/services/push_service.dart). These values are placeholders so the app
// keeps compiling and analyzing before a real Firebase project exists —
// FirebaseMessaging.instance.getToken() will simply fail at runtime with
// this configuration, which is expected until it's replaced.
//
// To replace it for real:
//   1. Create a free Firebase project at https://console.firebase.google.com
//   2. `dart pub global activate flutterfire_cli`
//   3. `flutterfire configure` from the app/ directory, selecting that
//      project — it overwrites this file with your project's real values.
//
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('DefaultFirebaseOptions have not been configured for web.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        // FR5.1's iOS path never calls Firebase.initializeApp() at all —
        // see push_service.dart's PushService._initIOS.
        throw UnsupportedError(
          'DefaultFirebaseOptions.currentPlatform is only used on Android in this app.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'REPLACE_ME',
    storageBucket: 'REPLACE_ME',
  );
}
