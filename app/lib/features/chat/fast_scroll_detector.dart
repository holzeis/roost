import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// How fast the finger has to drag the message list, in logical pixels per
/// second, before the keyboard is hidden. An ordinary read-back scroll stays
/// well below this; a hard flick through the history goes well above it.
const fastScrollDismissVelocity = 2500.0;

/// Tells a very fast, finger-driven scroll apart from a slow one, so the
/// chat can hide the keyboard only for the former. Fed the list's drag
/// updates; scrolls without a finger on the screen (a programmatic jump to
/// a replied-to message) never count.
class FastScrollDetector {
  FastScrollDetector({this.threshold = fastScrollDismissVelocity});

  final double threshold;
  VelocityTracker? _tracker;
  double _offset = 0;

  /// Call when a drag starts: velocity is measured per drag.
  void start() {
    _tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
    _offset = 0;
  }

  /// Feeds one drag update; true once this drag is moving at [threshold] or
  /// faster.
  bool update(DragUpdateDetails details) {
    final timeStamp = details.sourceTimeStamp;
    if (timeStamp == null) return false;
    final tracker = _tracker ??= VelocityTracker.withKind(PointerDeviceKind.touch);
    _offset += details.primaryDelta ?? details.delta.dy;
    tracker.addPosition(timeStamp, Offset(0, _offset));
    final estimate = tracker.getVelocityEstimate();
    return estimate != null && estimate.pixelsPerSecond.dy.abs() >= threshold;
  }

  /// Feeds any scroll notification from the list.
  bool handle(ScrollNotification notification) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      start();
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      final details = notification.dragDetails;
      if (details != null) return update(details);
    }
    return false;
  }
}
