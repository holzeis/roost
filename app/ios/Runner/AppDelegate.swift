import Flutter
import GoogleMaps
import PushKit
import UIKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // FR3.7: Maps SDK for iOS key, substituted into Info.plist's GMSApiKey
    // from Config.xcconfig (gitignored, per-developer — see
    // Config.xcconfig.example and README.md's "Google Maps API keys"
    // section). Never hardcoded or committed here.
    if let mapsApiKey = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
      !mapsApiKey.isEmpty
    {
      GMSServices.provideAPIKey(mapsApiKey)
    }
    GeneratedPluginRegistrant.register(with: self)

    // FR5.1: PushKit is the only way iOS reliably wakes a backgrounded/
    // killed app for CallKit — a plain remote notification can't do it.
    // flutter_callkit_incoming reads its own token/incoming-push handling
    // through the delegate methods below; the Dart side (push_service.dart)
    // picks up the resulting token and accept/decline events entirely
    // through its own event stream, so nothing else is needed here (see
    // the installed package's PUSHKIT.md).
    let voipRegistry = PKPushRegistry(queue: .main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let deviceToken = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void
  ) {
    guard type == .voIP else { return }

    let id = payload.dictionaryPayload["id"] as? String ?? ""
    let nameCaller = payload.dictionaryPayload["nameCaller"] as? String ?? ""
    let handle = payload.dictionaryPayload["handle"] as? String ?? ""
    let isVideo = payload.dictionaryPayload["isVideo"] as? Bool ?? false

    let data = flutter_callkit_incoming.Data(id: id, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
    // roomId/messageId/callId/callerId (see server/internal/push's
    // APNsSender) — carried through to Dart via CallKitParams.extra, read
    // by push_service.dart's routeForAcceptedCall/callIdToDecline once the
    // user accepts or declines from the native CallKit UI.
    data.extra = [
      "roomId": payload.dictionaryPayload["roomId"] as? String ?? "",
      "messageId": payload.dictionaryPayload["messageId"] as? String ?? "",
      "callId": payload.dictionaryPayload["callId"] as? String ?? "",
      "callerId": payload.dictionaryPayload["callerId"] as? String ?? "",
    ]

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }
}
