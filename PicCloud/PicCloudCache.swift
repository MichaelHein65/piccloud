import SwiftUI
import ImageIO

enum PicCloudCache {
    private static let schemaVersion = 2
    private static let schemaVersionKey = "PicCloud.cacheSchemaVersion"

    static func configure() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 4 * 1024 * 1024 * 1024,
            directory: cacheDirectory
        )
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
    static func loadDownsampledImage(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
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
        return image
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
