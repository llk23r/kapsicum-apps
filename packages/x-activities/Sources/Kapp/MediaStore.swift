import CoreGraphics
import Foundation
import ImageIO

actor MediaStore {
    private var rootURL: URL?

    func persist(_ screenshot: StoredScreenshot) throws -> StoredMedia {
        let root = try root()
        let mediaDirectory = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let filename = safeFilename(screenshot.archiveHash) + ".heic"
        let relativePath = "Media/\(filename)"
        let destination = root.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let bytes = Data(base64Encoded: screenshot.dataBase64) else { throw MediaError.invalidData }
            try bytes.write(to: destination, options: [.atomic])
        }
        let byteCount = (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return StoredMedia(
            archiveHash: screenshot.archiveHash,
            relativePath: relativePath,
            mimeType: screenshot.mimeType,
            pixelWidth: screenshot.width,
            pixelHeight: screenshot.height,
            byteCount: byteCount)
    }

    func thumbnail(relativePath: String, maximumPixels: Int = 720) async throws -> CGImage {
        let url = try validatedURL(relativePath)
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(240, maximumPixels),
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary)
            else { throw MediaError.invalidData }
            return image
        }.value
    }

    func fullImage(relativePath: String) async throws -> CGImage {
        let url = try validatedURL(relativePath)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw MediaError.invalidData }
            try Task.checkCancellation()
            return image
        }.value
    }

    func delete(relativePaths: [String]) throws {
        for path in relativePaths.prefix(StoragePolicy.maximumRecordCount) {
            let url = try validatedURL(path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func deleteAllMedia() throws {
        let directory = try root().appendingPathComponent("Media", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func diskBytes() throws -> Int64 {
        let directory = try root().appendingPathComponent("Media", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private func root() throws -> URL {
        if let rootURL { return rootURL }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("KappData", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root
        return root
    }

    private func validatedURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { throw MediaError.invalidPath }
        let root = try root().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw MediaError.invalidPath }
        return url
    }

    private func safeFilename(_ hash: String) -> String {
        Data(hash.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }
}

enum MediaError: LocalizedError {
    case invalidData, invalidPath
    var errorDescription: String? {
        switch self {
        case .invalidData:
            L10n.string(
                "error.media.invalid_data",
                fallback: "The locally stored screenshot could not be read.")
        case .invalidPath:
            L10n.string(
                "error.media.invalid_path",
                fallback: "The local media path is invalid.")
        }
    }
}
