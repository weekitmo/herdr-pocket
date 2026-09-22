import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // THIS APP'S OWN CHANNEL, registered next to the plugins rather than as one.
    //
    // It is not a plugin: it exists for one screen of one app, it has no
    // Android counterpart to share a package with, and `pluginRegistry` is the
    // wrong place for something only this app can use. The APPLICATION
    // registrar is the right venue, and it is reachable here only because the
    // implicit engine bridge exposes it — see `FlutterImplicitEngineBridge`.
    LocalStorageChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
