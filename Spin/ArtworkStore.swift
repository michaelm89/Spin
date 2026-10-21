import CryptoKit
import Foundation
import ImageIO

/// Downloads album covers once and keeps them on disk in ~/Library/Caches/Spin.
final class ArtworkStore {
    static let shared = ArtworkStore()

    private let directory: URL
    private let memory = NSCache<NSString, CGImage>()

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spin/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 120
    }

    func image(for urlString: String, maxPixels: Int = 640) async -> CGImage? {
        let key = "\(urlString)#\(maxPixels)" as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let file = directory.appendingPathComponent(Self.fileName(for: urlString))
        var data = try? Data(contentsOf: file)
        if data == nil, let url = URL(string: urlString) {
            data = try? await URLSession.shared.data(from: url).0
            if let data { try? data.write(to: file, options: .atomic) }
        }
        guard let data, let image = Self.decode(data, maxPixels: maxPixels) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    func images(for urls: [String], maxPixels: Int = 640) async -> [String: CGImage] {
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for url in Set(urls) {
                group.addTask { (url, await self.image(for: url, maxPixels: maxPixels)) }
            }
            var result: [String: CGImage] = [:]
            for await (url, image) in group { result[url] = image }
            return result
        }
    }

    private static func fileName(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
