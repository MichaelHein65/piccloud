import Foundation

@MainActor
final class GalleryStore: ObservableObject {
    @Published var serverURL: String = GalleryStore.savedServerURL()
    @Published private(set) var years: [GalleryYear] = []
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let libraryVersionKey = "PicCloud.libraryVersion"
    private var serverSupportsLibraryVersion = true
    private var checkedManifestURLs: Set<URL> = []
    private var cachedYearAlbums: [String: [GalleryAlbum]] = [:]
    private var cachedAlbumDetails: [String: GalleryAlbum] = [:]
    private var activeBaseURL: String?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init() {
        restorePersistedState()
    }

    func syncOnLaunch() async {
        let trimmedURL = normalizedServerURL()
        guard URL(string: "\(trimmedURL)/version.json") != nil else { return }
        resetSessionCachesIfBaseURLChanged(trimmedURL)

        if years.isEmpty {
            await load()
            return
        }

        do {
            try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
            if years.isEmpty {
                await load()
            }
        } catch {
            // Keep restored state for offline/slow-start behavior.
        }
    }

    func load() async {
        let trimmedURL = normalizedServerURL()
        guard let url = URL(string: "\(trimmedURL)/years.json") else {
            errorMessage = "Ungueltige Server-Adresse"
            return
        }
        resetSessionCachesIfBaseURLChanged(trimmedURL)

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
            let data = try await loadManifestData(from: url)
            let manifest = try decoder.decode(YearManifest.self, from: data)
            rememberLibraryVersionIfNeeded(manifest.libraryVersion)
            years = manifest.years.filter { $0.albumCount > 0 }
            UserDefaults.standard.set(trimmedURL, forKey: "PicCloud.serverURL")
            UserDefaults(suiteName: "group.de.michaelhein.piccloud")?.set(trimmedURL, forKey: "PicCloud.serverURL")
            serverURL = trimmedURL
            persistStateIfPossible()
        } catch {
            errorMessage = "Keine Verbindung zur Galerie: \(error.localizedDescription)"
        }
    }

    func loadYear(_ year: GalleryYear) async throws -> [GalleryAlbum] {
        let trimmedURL = normalizedServerURL()
        resetSessionCachesIfBaseURLChanged(trimmedURL)
        if let cachedAlbums = cachedYearAlbums[year.id] {
            return cachedAlbums
        }
        guard let encodedYear = year.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(trimmedURL)/year/\(encodedYear).json") else {
            throw URLError(.badURL)
        }
        try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
        let data = try await loadManifestData(from: url)
        let yearResponse = try decoder.decode(YearResponse.self, from: data)
        rememberLibraryVersionIfNeeded(yearResponse.libraryVersion)
        cachedYearAlbums[year.id] = yearResponse.albums
        persistStateIfPossible()
        return yearResponse.albums
    }

    func loadAlbum(_ album: GalleryAlbum) async throws -> GalleryAlbum {
        let trimmedURL = normalizedServerURL()
        resetSessionCachesIfBaseURLChanged(trimmedURL)
        if let cachedAlbum = cachedAlbumDetails[album.id] {
            return cachedAlbum
        }
        guard let url = URL(string: "\(trimmedURL)/album/\(album.id).json") else {
            throw URLError(.badURL)
        }
        try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
        let data = try await loadManifestData(from: url)
        let albumResponse = try decoder.decode(AlbumResponse.self, from: data)
        rememberLibraryVersionIfNeeded(albumResponse.libraryVersion)
        cachedAlbumDetails[album.id] = albumResponse.album
        persistStateIfPossible()
        return albumResponse.album
    }

    private func loadManifestData(from url: URL) async throws -> Data {
        let shouldCheckManifest = !serverSupportsLibraryVersion && !checkedManifestURLs.contains(url)
        let request = shouldCheckManifest
            ? PicCloudCache.serverCheckRequest(for: url, timeout: 8)
            : PicCloudCache.cachedRequest(for: url, timeout: 8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        checkedManifestURLs.insert(url)
        return data
    }

    private func refreshLibraryVersionIfNeeded(baseURL: String) async throws {
        guard let url = URL(string: "\(baseURL)/version.json") else {
            throw URLError(.badURL)
        }

        let request = PicCloudCache.serverCheckRequest(for: url, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 404 {
                serverSupportsLibraryVersion = false
                return
            }
            throw URLError(.badServerResponse)
        }

        let versionResponse = try decoder.decode(LibraryVersionResponse.self, from: data)
        invalidateCacheIfNeeded(libraryVersion: versionResponse.libraryVersion)
    }

    private func rememberLibraryVersionIfNeeded(_ libraryVersion: String?) {
        guard let libraryVersion, !libraryVersion.isEmpty else { return }
        UserDefaults.standard.set(libraryVersion, forKey: libraryVersionKey)
    }

    private func invalidateCacheIfNeeded(libraryVersion: String?) {
        guard let libraryVersion, !libraryVersion.isEmpty else { return }

        let defaults = UserDefaults.standard
        let previousVersion = defaults.string(forKey: libraryVersionKey)
        guard previousVersion != nil, previousVersion != libraryVersion else {
            defaults.set(libraryVersion, forKey: libraryVersionKey)
            return
        }

        PicCloudCache.invalidateAll()
        checkedManifestURLs.removeAll()
        cachedYearAlbums.removeAll()
        cachedAlbumDetails.removeAll()
        years = []
        albums = []
        defaults.set(libraryVersion, forKey: libraryVersionKey)
        removePersistedState()
    }

    private func resetSessionCachesIfBaseURLChanged(_ baseURL: String) {
        guard activeBaseURL != baseURL else { return }
        activeBaseURL = baseURL
        checkedManifestURLs.removeAll()
        cachedYearAlbums.removeAll()
        cachedAlbumDetails.removeAll()
        years = []
        albums = []
    }

    private func normalizedServerURL() -> String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func savedServerURL() -> String {
        UserDefaults.standard.string(forKey: "PicCloud.serverURL")
            ?? UserDefaults(suiteName: "group.de.michaelhein.piccloud")?.string(forKey: "PicCloud.serverURL")
            ?? "http://100.104.66.88:8098"
    }

    private func persistStateIfPossible() {
        let defaults = UserDefaults.standard
        guard let libraryVersion = defaults.string(forKey: libraryVersionKey),
              !libraryVersion.isEmpty,
              let data = try? encoder.encode(
                PersistedGalleryState(
                    serverURL: normalizedServerURL(),
                    libraryVersion: libraryVersion,
                    years: years,
                    cachedYearAlbums: cachedYearAlbums,
                    cachedAlbumDetails: cachedAlbumDetails
                )
              ) else {
            return
        }

        try? data.write(to: persistedStateURL, options: .atomic)
    }

    private func restorePersistedState() {
        guard let data = try? Data(contentsOf: persistedStateURL),
              let state = try? decoder.decode(PersistedGalleryState.self, from: data) else {
            return
        }

        let trimmedURL = normalizedServerURL()
        guard state.serverURL == trimmedURL else { return }

        activeBaseURL = state.serverURL
        years = state.years
        cachedYearAlbums = state.cachedYearAlbums
        cachedAlbumDetails = state.cachedAlbumDetails
        UserDefaults.standard.set(state.libraryVersion, forKey: libraryVersionKey)
    }

    private func removePersistedState() {
        try? FileManager.default.removeItem(at: persistedStateURL)
    }

    private var persistedStateURL: URL {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return (cacheDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("PicCloudGalleryState.json", isDirectory: false)
    }
}

private struct PersistedGalleryState: Codable {
    let serverURL: String
    let libraryVersion: String
    let years: [GalleryYear]
    let cachedYearAlbums: [String: [GalleryAlbum]]
    let cachedAlbumDetails: [String: GalleryAlbum]
}
