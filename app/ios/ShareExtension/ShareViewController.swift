import share_handler_ios_models

/// The share-sheet extension (App Store: "Share to Roost"). It shows no UI
/// of its own: share_handler's base class copies the shared photos/videos
/// into the App Group container, notes which Roost chat was picked (when the
/// user tapped a suggested conversation), and opens the Roost app, whose
/// Dart side (lib/services/share_intake.dart) takes it from there.
class ShareViewController: ShareHandlerIosViewController {}
