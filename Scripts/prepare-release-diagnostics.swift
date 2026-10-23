#!/usr/bin/swift
import CryptoKit
import Foundation

/// Whitelist-only release diagnostics. It never reads a key, credentials, or an environment dictionary.
enum DiagnosticFailure: Error { case stopped(String) }
func process(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    // These read-only tools need no signing credentials inherited from the release step.
    task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let stdout = Pipe(), stderr = Pipe()
    task.standardOutput = stdout; task.standardError = stderr
    try task.run()
    let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw DiagnosticFailure.stopped("required build tool failed") }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func regularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DiagnosticFailure.stopped("expected a regular non-symlink build file") }
}
func directory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw DiagnosticFailure.stopped("expected a non-symlink archive directory") }
}
func propertyList(_ url: URL) throws -> [String: Any] {
    try regularFile(url)
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else { throw DiagnosticFailure.stopped("invalid build Info.plist") }
    return value
}
func digest(_ url: URL) throws -> String {
    try regularFile(url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func uuid(_ url: URL) throws -> String {
    try regularFile(url)
    let output = try process("/usr/bin/xcrun", ["dwarfdump", "--uuid", url.path])
    let lines = output.split(separator: "\n")
    guard lines.count == 1 else { throw DiagnosticFailure.stopped("exactly one arm64 UUID is required") }
    let fields = lines[0].split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 4, fields[0] == "UUID:", fields[2] == "(arm64)",
          let id = UUID(uuidString: String(fields[1])) else { throw DiagnosticFailure.stopped("symbols must contain the arm64 executable UUID") }
    return id.uuidString
}
func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }

do {
    let tokens = Array(CommandLine.arguments.dropFirst())
    guard tokens.count % 2 == 0 else { throw DiagnosticFailure.stopped("arguments must be named pairs") }
    var options: [String: String] = [:]
    let names: Set<String> = ["--archive", "--output", "--source-commit", "--version", "--build-number", "--workflow-run-id", "--workflow-run-attempt"]
    for offset in stride(from: 0, to: tokens.count, by: 2) {
        guard names.contains(tokens[offset]), options[tokens[offset]] == nil else { throw DiagnosticFailure.stopped("unknown or duplicate argument") }
        options[tokens[offset]] = tokens[offset + 1]
    }
    guard let archivePath = options["--archive"], let outputPath = options["--output"],
          let commit = options["--source-commit"], matches(commit, "^[a-f0-9]{40}$"),
          let version = options["--version"], matches(version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"),
          let build = options["--build-number"], matches(build, "^[1-9][0-9]{0,8}$") else {
        throw DiagnosticFailure.stopped("archive, output, 40-character source commit, stable version and positive build number are required")
    }
    let archive = URL(fileURLWithPath: archivePath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
    let manager = FileManager.default
    var didCreateOutput = false
    var completed = false
    defer { if didCreateOutput && !completed { try? manager.removeItem(at: output) } }

    try directory(archive)
    guard archive.pathExtension == "xcarchive", !output.path.hasPrefix(archive.path + "/"),
          output != archive, !manager.fileExists(atPath: output.path) else { throw DiagnosticFailure.stopped("output must be a fresh directory outside the archive") }
    let app = archive.appendingPathComponent("Products/Applications/ZashDock.app", isDirectory: true)
    let symbols = archive.appendingPathComponent("dSYMs/ZashDock.app.dSYM", isDirectory: true)
    try directory(app); try directory(symbols)
    // Check every path component; a selected leaf may not escape through a symlinked parent.
    for relative in ["Products", "Products/Applications", "Products/Applications/ZashDock.app/Contents", "Products/Applications/ZashDock.app/Contents/MacOS", "dSYMs", "dSYMs/ZashDock.app.dSYM/Contents", "dSYMs/ZashDock.app.dSYM/Contents/Resources", "dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF"] {
        try directory(archive.appendingPathComponent(relative))
    }
    let info = try propertyList(app.appendingPathComponent("Contents/Info.plist"))
    guard info["CFBundleIdentifier"] as? String == "app.zashdock.mac",
          info["CFBundleExecutable"] as? String == "ZashDock",
          info["CFBundleShortVersionString"] as? String == version,
          info["CFBundleVersion"] as? String == build,
          info["LSMinimumSystemVersion"] as? String == "26.0" else { throw DiagnosticFailure.stopped("archived App identity/version does not match the release") }
    let symbolInfo = try propertyList(symbols.appendingPathComponent("Contents/Info.plist"))
    guard symbolInfo["CFBundlePackageType"] as? String == "dSYM",
          symbolInfo["CFBundleIdentifier"] as? String == "com.apple.xcode.dsym.app.zashdock.mac",
          symbolInfo["CFBundleShortVersionString"] as? String == version,
          symbolInfo["CFBundleVersion"] as? String == build else { throw DiagnosticFailure.stopped("invalid dSYM bundle identity/version") }
    let executable = app.appendingPathComponent("Contents/MacOS/ZashDock")
    let dwarf = symbols.appendingPathComponent("Contents/Resources/DWARF/ZashDock")
    let executableUUID = try uuid(executable)
    guard try uuid(dwarf) == executableUUID else { throw DiagnosticFailure.stopped("dSYM UUID does not match the archived App") }
    let toolchainLines = try process("/usr/bin/xcodebuild", ["-version"]).split(separator: "\n").map(String.init)
    guard toolchainLines.count == 2, toolchainLines[0].hasPrefix("Xcode "), toolchainLines[1].hasPrefix("Build version ") else { throw DiagnosticFailure.stopped("unexpected Xcode version output") }
    let xcodeVersion = String(toolchainLines[0].dropFirst(6))
    let xcodeBuild = String(toolchainLines[1].dropFirst(14))
    guard matches(xcodeVersion, "^[0-9]+(\\.[0-9]+){0,2}$"), matches(xcodeBuild, "^[A-Za-z0-9]{1,32}$") else { throw DiagnosticFailure.stopped("invalid Xcode build metadata") }
    let sdk = try process("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"])
    guard matches(sdk, "^[0-9]+(\\.[0-9]+){0,2}$") else { throw DiagnosticFailure.stopped("invalid SDK version") }
    let basename = "ZashDock-\(version)-build\(build)-arm64"
    let zipName = "\(basename)-dSYMs.zip"
    let metadataName = "\(basename)-build-metadata.json"
    let checksumsName = "\(basename)-diagnostics-SHA256SUMS.txt"
    try manager.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    didCreateOutput = true
    let staging = output.appendingPathComponent(".symbols-staging", isDirectory: true)
    defer { try? manager.removeItem(at: staging) }
    let stagedBundle = staging.appendingPathComponent("ZashDock.app.dSYM", isDirectory: true)
    let stagedDWARF = stagedBundle.appendingPathComponent("Contents/Resources/DWARF/ZashDock")
    try manager.createDirectory(at: stagedDWARF.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Only two known files enter the ZIP. No archive, app, keychain, logs, or arbitrary dSYM additions.
    try manager.copyItem(at: dwarf, to: stagedDWARF)
    let safeSymbolInfo: [String: String] = [
        "CFBundleDevelopmentRegion": "English", "CFBundleIdentifier": "com.apple.xcode.dsym.app.zashdock.mac",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundlePackageType": "dSYM",
        "CFBundleShortVersionString": version, "CFBundleSignature": "????", "CFBundleVersion": build
    ]
    try PropertyListSerialization.data(fromPropertyList: safeSymbolInfo, format: .xml, options: 0)
        .write(to: stagedBundle.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    guard try uuid(stagedDWARF) == executableUUID else { throw DiagnosticFailure.stopped("copied symbol UUID mismatch") }
    let zip = output.appendingPathComponent(zipName)
    _ = try process("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", stagedBundle.path, zip.path])
    let zipDigest = try digest(zip)
    var metadata: [String: Any] = [
        "schema": 1,
        "application": ["bundle_identifier": "app.zashdock.mac", "version": version, "build_number": build,
                        "architecture": "arm64", "minimum_macos": "26.0", "executable_uuid": executableUUID],
        "source": ["repository": "https://github.com/MiracleHYH/ZashDock", "commit": commit],
        "toolchain": ["xcode_version": xcodeVersion, "xcode_build": xcodeBuild, "macos_sdk": sdk],
        "symbols": ["filename": zipName, "sha256": zipDigest, "dwarf_sha256": try digest(dwarf),
                    "scope": "ZashDock executable and statically linked ZashDockCore"],
        "archived_executable_sha256": try digest(executable)
    ]
    if let run = options["--workflow-run-id"] {
        guard matches(run, "^[1-9][0-9]{0,23}$"), let attempt = options["--workflow-run-attempt"], matches(attempt, "^[1-9][0-9]{0,8}$") else { throw DiagnosticFailure.stopped("invalid workflow provenance") }
        metadata["workflow"] = ["run_url": "https://github.com/MiracleHYH/ZashDock/actions/runs/\(run)", "attempt": attempt]
    } else if options["--workflow-run-attempt"] != nil { throw DiagnosticFailure.stopped("workflow attempt requires run ID") }
    let metadataURL = output.appendingPathComponent(metadataName)
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: metadataURL, options: .atomic)
    let checksums = "\(zipDigest)  \(zipName)\n\(try digest(metadataURL))  \(metadataName)\n"
    try Data(checksums.utf8).write(to: output.appendingPathComponent(checksumsName), options: .atomic)
    try manager.removeItem(at: staging)
    guard Set(try manager.contentsOfDirectory(atPath: output.path)) == [zipName, metadataName, checksumsName] else { throw DiagnosticFailure.stopped("unexpected diagnostic artifact") }
    completed = true
    print("Prepared matching arm64 dSYM and whitelist build metadata (UUID \(executableUUID)).")
} catch {
    // A generic diagnostic never exposes credential-containing paths or tool environment output.
    let reason: String
    if case DiagnosticFailure.stopped(let message) = error { reason = message } else { reason = "archive validation or diagnostic write failed" }
    fputs("Release diagnostics stopped: \(reason)\n", stderr)
    exit(1)
}
