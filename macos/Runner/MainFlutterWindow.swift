import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var activeSecurityScopedURLs: [String: URL] = [:]

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let securityScopeChannel = FlutterMethodChannel(
      name: "ru.kotdath.domovoy/project_security_scope",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    securityScopeChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleSecurityScopeCall(call, result: result)
    }

    super.awakeFromNib()
  }

  private func handleSecurityScopeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
      return
    }
    switch call.method {
    case "createBookmark":
      guard let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_path", message: nil, details: nil))
        return
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          result(FlutterError(code: "not_directory", message: nil, details: nil))
          return
        }
        let bookmark = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(bookmark.base64EncodedString())
      } catch {
        result(FlutterError(code: "bookmark_failed", message: nil, details: nil))
      }
    case "restoreBookmark":
      guard
        let encoded = arguments["bookmark"] as? String,
        let bookmark = Data(base64Encoded: encoded)
      else {
        result(["status": "corrupt"])
        return
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &stale)
        if stale {
          result(["status": "requiresRegrant"])
          return
        }
        guard url.startAccessingSecurityScopedResource() else {
          result(["status": "revoked"])
          return
        }
        activeSecurityScopedURLs[encoded] = url
        result(["status": "active", "path": url.path])
      } catch {
        result(["status": "unverifiable"])
      }
    case "revokeBookmark":
      if let encoded = arguments["bookmark"] as? String,
         let url = activeSecurityScopedURLs.removeValue(forKey: encoded) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
