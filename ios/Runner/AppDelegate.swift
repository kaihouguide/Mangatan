import UIKit
import Flutter
import Libmtorrentserver

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let ankiMobilePasteboardType = "net.ankimobile.json"
  private var ankiMobileMediaBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var embeddedMihonRequested = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    let mChannel = FlutterMethodChannel(
      name: "com.kodjodevf.mangayomi.libmtorrentserver",
      binaryMessenger: messenger)
    mChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "start":
        let args = call.arguments as? Dictionary<String, Any>
        let config = args?["config"] as? String
        var error: NSError?
        let mPort = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { mPort.deallocate() }
        if LibmtorrentserverStart(config, mPort, &error) {
          result(mPort.pointee)
        } else {
          result(FlutterError(
            code: "ERROR",
            message: error.debugDescription,
            details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    })

    let ankiMobileChannel = FlutterMethodChannel(
      name: "com.selxo.mangatan.ankimobile",
      binaryMessenger: messenger)
    ankiMobileChannel.setMethodCallHandler({ [weak self]
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "consumeInfoForAddingPasteboard":
        if let data = UIPasteboard.general.data(
          forPasteboardType: Self.ankiMobilePasteboardType
        ) {
          UIPasteboard.general.setData(
            Data(),
            forPasteboardType: Self.ankiMobilePasteboardType)
          result(String(data: data, encoding: .utf8))
        } else {
          result(nil)
        }
      case "beginMediaImportBackgroundTask":
        self?.beginAnkiMobileMediaBackgroundTask()
        result(nil)
      case "endMediaImportBackgroundTask":
        self?.endAnkiMobileMediaBackgroundTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    })

    let embeddedMihonChannel = FlutterMethodChannel(
      name: "com.selxo.mangatan.embedded_mihon",
      binaryMessenger: messenger)
    embeddedMihonChannel.setMethodCallHandler({ [weak self]
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        // Int32(_:) traps on overflow. Treat anything that is not a TCP port
        // as a request for an ephemeral one instead of crashing the app.
        let requestedPort = args?["port"] as? Int ?? 0
        let port: Int32 =
          (0...65535).contains(requestedPort) ? Int32(requestedPort) : 0
        self?.embeddedMihonRequested = true
        MangatanEmbeddedMihonStart(port) { startedPort, error in
          if let error = error {
            result(FlutterError(
              code: "EMBEDDED_MIHON_START",
              message: error.localizedDescription,
              details: nil))
          } else {
            result([
              "port": Int(startedPort),
              "baseUrl": "http://127.0.0.1:\(startedPort)",
            ])
          }
        }
      case "pause":
        MangatanEmbeddedMihonPause { error in
          if let error = error {
            result(FlutterError(
              code: "EMBEDDED_MIHON_PAUSE",
              message: error.localizedDescription,
              details: nil))
          } else {
            result(nil)
          }
        }
      case "stop":
        self?.embeddedMihonRequested = false
        MangatanEmbeddedMihonStop { error in
          if let error = error {
            result(FlutterError(
              code: "EMBEDDED_MIHON_STOP",
              message: error.localizedDescription,
              details: nil))
          } else {
            result(nil)
          }
        }
      case "status":
        MangatanEmbeddedMihonIsRunning { isRunning, error in
          if let error = error {
            result(FlutterError(
              code: "EMBEDDED_MIHON_STATUS",
              message: error.localizedDescription,
              details: nil))
          } else {
            result(isRunning)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    })

    AppleVisionOcrPlugin.register(binaryMessenger: messenger)
  }

  func sceneWillResignActive() {
    // The scene delegate calls this before Flutter notifies Dart. Starting the
    // pause here prevents iOS from suspending OpenJDK in a blocking accept().
    if embeddedMihonRequested {
      MangatanEmbeddedMihonPause { _ in }
    }
  }

  private func beginAnkiMobileMediaBackgroundTask() {
    endAnkiMobileMediaBackgroundTask()
    ankiMobileMediaBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "AnkiMobile media import"
    ) { [weak self] in
      self?.endAnkiMobileMediaBackgroundTask()
    }
  }

  private func endAnkiMobileMediaBackgroundTask() {
    guard ankiMobileMediaBackgroundTask != .invalid else { return }
    let task = ankiMobileMediaBackgroundTask
    ankiMobileMediaBackgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }
}

@objc class MihonSceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    (UIApplication.shared.delegate as? AppDelegate)?.sceneWillResignActive()
    super.sceneWillResignActive(scene)
  }
}
