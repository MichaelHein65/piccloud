import SwiftUI
import ImageIO
import CryptoKit

enum PicCloudCache {
    private static let schemaVersion = 2
    private static let schemaVersionKey = "PicCloud.cacheSchemaVersion"
    private static let decodedImageCache = NSCache<NSString, UIImage>()

    static func configure() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 4 * 1024 * 1024 * 1024,
            directory: cacheDirectory
        )
        ensureThumbnailCacheDirectory()
        invalidateIfSchemaChanged()
    }

    static func cachedRequest(for url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        return request
    }

    static func serverCheckRequest(for url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        return request
    }

    static func invalidateAll() {
        URLCache.shared.removeAllCachedResponses()
        decodedImageCache.removeAllObjects()
        clearThumbnailCache()
    }

    static func prefetch(_ url: URL, timeout: TimeInterval = 60) async {
        let request = cachedRequest(for: url, timeout: timeout)
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func invalidateIfSchemaChanged() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: schemaVersionKey) != schemaVersion else { return }
        invalidateAll()
        defaults.set(schemaVersion, forKey: schemaVersionKey)
    }

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "PicCloudURLCache",
            isDirectory: true
        )
    }

    private static var thumbnailCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "PicCloudThumbnailCache",
            isDirectory: true
        )
    }

    private static func ensureThumbnailCacheDirectory() {
        guard let thumbnailCacheDirectory else { return }
        try? FileManager.default.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
    }

    private static func clearThumbnailCache() {
        guard let thumbnailCacheDirectory else { return }
        try? FileManager.default.removeItem(at: thumbnailCacheDirectory)
        ensureThumbnailCacheDirectory()
    }
}

struct CachedRemoteImage<Content: View>: View {
    let url: URL?
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty
    @State private var currentTask: Task<Void, Never>?

    var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
            .onDisappear {
                currentTask?.cancel()
                currentTask = nil
            }
    }

    @MainActor
    private func load() async {
        currentTask?.cancel()

        guard let url else {
            phase = .empty
            return
        }

        if let cachedImage = PicCloudCache.cachedImage(for: url, maxPixelSize: 1024) {
            phase = .success(Image(uiImage: cachedImage))
            return
        }

        phase = .empty
        let task = Task {
            do {
                let uiImage = try await PicCloudCache.loadDownsampledImage(from: url, maxPixelSize: 1024)
                let image = Image(uiImage: uiImage)
                await MainActor.run {
                    phase = .success(image)
                }
            } catch {
                await MainActor.run {
                    phase = .failure(error)
                }
            }
        }
        currentTask = task
        await task.value
    }
}

extension PicCloudCache {
    static func cachedImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let image = decodedImageCache.object(forKey: key) {
            return image
        }

        guard let diskURL = cachedImageURL(for: url, maxPixelSize: maxPixelSize),
              let data = try? Data(contentsOf: diskURL),
              let image = UIImage(data: data) else {
            return nil
        }

        decodedImageCache.setObject(image, forKey: key)
        return image
    }

    static func loadDownsampledImage(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        if let cachedImage = cachedImage(for: url, maxPixelSize: maxPixelSize) {
            return cachedImage
        }

        do {
            return try await loadDownsampledImage(from: url, maxPixelSize: maxPixelSize, cachePolicy: .returnCacheDataElseLoad)
        } catch {
            return try await loadDownsampledImage(from: url, maxPixelSize: maxPixelSize, cachePolicy: .reloadIgnoringLocalCacheData)
        }
    }

    private static func loadDownsampledImage(
        from url: URL,
        maxPixelSize: CGFloat,
        cachePolicy: URLRequest.CachePolicy
    ) async throws -> UIImage {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 20)
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let image = downsampledImage(from: data, maxPixelSize: maxPixelSize) else {
            throw URLError(.cannotDecodeContentData)
        }
        cacheImage(image, for: url, maxPixelSize: maxPixelSize)
        return image
    }

    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(maxPixelSize.rounded()))" as NSString
    }

    private static func cachedImageURL(for url: URL, maxPixelSize: CGFloat) -> URL? {
        guard let thumbnailCacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data("\(url.absoluteString)|\(Int(maxPixelSize.rounded()))".utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
        return thumbnailCacheDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func cacheImage(_ image: UIImage, for url: URL, maxPixelSize: CGFloat) {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        decodedImageCache.setObject(image, forKey: key)

        guard let diskURL = cachedImageURL(for: url, maxPixelSize: maxPixelSize),
              let data = image.jpegData(compressionQuality: 0.82) ?? image.pngData() else {
            return
        }

        try? data.write(to: diskURL, options: .atomic)
    }

    static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
