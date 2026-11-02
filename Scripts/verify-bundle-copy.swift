#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

// Compare generated bundle copies without descending through framework symlinks.
// This tool reads both trees; it never changes either copy.
enum VerificationError: Error, CustomStringConvertible {
    case failure(String)
    var description: String {
        switch self { case .failure(let message): return message }
    }
}

struct Entry: Equatable {
    let type: mode_t
    let permissions: mode_t
    let size: off_t?
    let digest: String?
    let linkTarget: String?
}

func status(_ path: String) throws -> stat {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        throw VerificationError.failure("Cannot inspect \(path): \(String(cString: strerror(errno)))")
    }
    return value
}

func hashFile(_ path: String, expected: stat) throws -> String {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw VerificationError.failure("Cannot read regular file: \(path)")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
          opened.st_mode & S_IFMT == S_IFREG,
          opened.st_dev == expected.st_dev,
          opened.st_ino == expected.st_ino else {
        throw VerificationError.failure("File changed while opening: \(path)")
    }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hash.update(data: chunk)
    }
    var finished = stat()
    guard fstat(descriptor, &finished) == 0,
          finished.st_size == opened.st_size,
          finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
          finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
          finished.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
          finished.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else {
        throw VerificationError.failure("File changed while reading: \(path)")
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func inventory(_ root: String) throws -> [String: Entry] {
    guard try status(root).st_mode & S_IFMT == S_IFDIR else {
        throw VerificationError.failure("Root must be a real directory, not a symbolic link: \(root)")
    }
    var entries: [String: Entry] = [:]
    func visit(_ path: String, relative: String) throws {
        let info = try status(path)
        let kind = info.st_mode & S_IFMT
        let permissions = info.st_mode & 0o7777
        switch kind {
        case S_IFDIR:
            entries[relative] = Entry(type: kind, permissions: permissions,
                                      size: nil, digest: nil, linkTarget: nil)
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                try visit(path + "/" + name, relative: relative == "." ? name : relative + "/" + name)
            }
        case S_IFREG:
            entries[relative] = Entry(type: kind, permissions: permissions,
                                      size: info.st_size, digest: try hashFile(path, expected: info), linkTarget: nil)
        case S_IFLNK:
            entries[relative] = Entry(type: kind, permissions: permissions, size: nil, digest: nil,
                                      linkTarget: try FileManager.default.destinationOfSymbolicLink(atPath: path))
        default:
            throw VerificationError.failure("Unsupported file type at \(relative)")
        }
    }
    try visit(root, relative: ".")
    return entries
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw VerificationError.failure("Usage: verify-bundle-copy.swift <original-directory> <restored-directory>")
    }
    let original = try inventory(CommandLine.arguments[1])
    let restored = try inventory(CommandLine.arguments[2])
    let paths = Set(original.keys).union(restored.keys).sorted()
    let differences = paths.filter { original[$0] != restored[$0] }
    guard differences.isEmpty else {
        for path in differences.prefix(20) {
            let reason = original[path] == nil ? "unexpected entry" : restored[path] == nil ? "missing entry" : "content, type, permissions, or link target differs"
            FileHandle.standardError.write(Data("\(path): \(reason)\n".utf8))
        }
        throw VerificationError.failure("Bundle trees differ at \(differences.count) path(s).")
    }
    print("Verified identical trees (\(paths.count) entries; SHA-256, types, permissions, and symlink targets).")
} catch {
    FileHandle.standardError.write(Data("Verification failed: \(error)\n".utf8))
    exit(1)
}
