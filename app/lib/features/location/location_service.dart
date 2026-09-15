import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:geolocator/geolocator.dart';

/// Thrown by [LocationService.requestPermission] when the user has denied
/// location access (including "denied forever", where the OS won't show the
/// prompt again and the user has to grant it from system settings) — kept as
/// a distinct type so callers can show a specific "open settings" message
/// instead of a generic error.
class LocationPermissionDeniedException implements Exception {
  const LocationPermissionDeniedException(this.deniedForever);
  final bool deniedForever;
}

/// Thin wrapper around `package:geolocator`, kept as a small seam (like
/// ApiClient/WsClient) so the sharing logic in LocationShareController can
/// be tested against a fake without real GPS or platform permission
/// dialogs.
///
/// Background behavior (FR3.1-3.4's "true background tracking" — see the
/// plan this was built from): AndroidSettings.foregroundNotificationConfig
/// raises the app's process priority via a foreground service notification
/// so it's far less likely to be killed while backgrounded/screen-locked,
/// and AppleSettings.allowBackgroundLocationUpdates keeps iOS delivering
/// updates while backgrounded. Neither survives the user force-quitting the
/// app from the app switcher — the geolocator_android docs are explicit
/// that a foreground notification "does not run your service in the
/// background" independent of the app process; that would need a separate
/// native background-service architecture, out of scope here.
class LocationService {
  /// Requests "always" location permission, walking through the
  /// When-In-Use -> Always upgrade iOS expects (Android has no such
  /// two-step distinction at the permission-dialog level, though the user
  /// separately grants "Allow all the time" via system settings on Android
  /// 10+ — geolocator surfaces that as part of the same `always` result
  /// once granted). Throws [LocationPermissionDeniedException] if the user
  /// doesn't end up granting at least `whileInUse`.
  Future<void> requestPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationPermissionDeniedException(true);
    }
    if (permission == LocationPermission.denied) {
      throw const LocationPermissionDeniedException(false);
    }
    if (permission == LocationPermission.whileInUse) {
      // Prompts the iOS "upgrade to Always" dialog; on Android this is a
      // no-op re-check (background access there is granted separately, not
      // through a second call to this method).
      await Geolocator.requestPermission();
    }
  }

  Future<Position> getCurrentPosition() =>
      Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));

  /// A continuous stream of position updates, configured to keep running
  /// while backgrounded per the doc comment above. [distanceFilterMeters] is
  /// the minimum movement between updates — movement-driven rather than
  /// purely time-driven, so a stationary share doesn't spam pointless
  /// identical updates.
  Stream<Position> watchPosition({int distanceFilterMeters = 30}) {
    return Geolocator.getPositionStream(locationSettings: _platformSettings(distanceFilterMeters));
  }

  /// AndroidSettings/AppleSettings each carry the platform-specific knobs
  /// needed for background delivery (see the class doc comment) — a plain
  /// LocationSettings has neither, so this must pick the right subclass for
  /// the running platform, same as geolocator's own getCurrentPosition does
  /// internally (it branches on defaultTargetPlatform too).
  LocationSettings _platformSettings(int distanceFilterMeters) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Sharing your location',
            notificationText: 'Roost is sharing your live location in a chat.',
          ),
        );
      case TargetPlatform.iOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
          allowBackgroundLocationUpdates: true,
          pauseLocationUpdatesAutomatically: false,
        );
      default:
        return LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: distanceFilterMeters);
    }
  }
}
