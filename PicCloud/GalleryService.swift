import Foundation

@MainActor
final class GalleryStore: ObservableObject {
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "PicCloud.serverURL") ?? "http://100.104.66.88:8098"
    @Published private(set) var years: [GalleryYear] = []
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let libraryVersionKey = "PicCloud.libraryVersion"
    private var hasCheckedLibraryVersion = false
    private var serverSupportsLibraryVersion = true
    private var checkedManifestURLs: Set<URL> = []

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() async {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedURL)/years.json") else {
            errorMessage = "Ungueltige Server-Adresse"
            return
        }

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
            serverURL = trimmedURL
        } catch {
            errorMessage = "Keine Verbindung zur Galerie: \(error.localizedDescription)"
        }
    }

    func loadYear(_ year: GalleryYear) async throws -> [GalleryAlbum] {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let encodedYear = year.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(trimmedURL)/year/\(encodedYear).json") else {
            throw URLError(.badURL)
        }
        try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
        let data = try await loadManifestData(from: url)
        let yearResponse = try decoder.decode(YearResponse.self, from: data)
        rememberLibraryVersionIfNeeded(yearResponse.libraryVersion)
        return yearResponse.albums
    }

    func loadAlbum(_ album: GalleryAlbum) async throws -> GalleryAlbum {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedURL)/album/\(album.id).json") else {
            throw URLError(.badURL)
        }
        try await refreshLibraryVersionIfNeeded(baseURL: trimmedURL)
        let data = try await loadManifestData(from: url)
        let albumResponse = try decoder.decode(AlbumResponse.self, from: data)
        rememberLibraryVersionIfNeeded(albumResponse.libraryVersion)
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
        guard !hasCheckedLibraryVersion else { return }
        guard let url = URL(string: "\(baseURL)/version.json") else {
            throw URLError(.badURL)
        }

        let request = PicCloudCache.serverCheckRequest(for: url, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 404 {
                serverSupportsLibraryVersion = false
                hasCheckedLibraryVersion = true
                return
            }
            throw URLError(.badServerResponse)
        }

        let versionResponse = try decoder.decode(LibraryVersionResponse.self, from: data)
        invalidateCacheIfNeeded(libraryVersion: versionResponse.libraryVersion)
        hasCheckedLibraryVersion = true
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
        years = []
        albums = []
        defaults.set(libraryVersion, forKey: libraryVersionKey)
    }
}
