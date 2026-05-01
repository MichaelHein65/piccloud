import Foundation

@MainActor
final class GalleryStore: ObservableObject {
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "PicCloud.serverURL") ?? "http://100.104.66.88:8098"
    @Published private(set) var years: [GalleryYear] = []
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

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
            let request = PicCloudCache.cachedRequest(for: url, timeout: 8)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            let manifest = try decoder.decode(YearManifest.self, from: data)
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
        let request = PicCloudCache.cachedRequest(for: url, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(YearResponse.self, from: data).albums
    }

    func loadAlbum(_ album: GalleryAlbum) async throws -> GalleryAlbum {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedURL)/album/\(album.id).json") else {
            throw URLError(.badURL)
        }
        let request = PicCloudCache.cachedRequest(for: url, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(AlbumResponse.self, from: data).album
    }
}
