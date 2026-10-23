import CoreServices
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/register-debug-app.swift /path/to/ZashDock.app\n", stderr)
    exit(64)
}
let application = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
guard application.pathExtension == "app",
      let bundle = Bundle(url: application),
      bundle.bundleIdentifier == "app.zashdock.mac",
      bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
    fputs("Refusing to register a bundle that is not ZashDock.\n", stderr)
    exit(1)
}
// Register only the final copied development App. Do not clear global icon caches.
let status = LSRegisterURL(application as CFURL, true)
guard status == noErr else {
    fputs("Launch Services registration failed: \(status)\n", stderr)
    exit(1)
}
print("Registered Debug application: \(application.path)")
