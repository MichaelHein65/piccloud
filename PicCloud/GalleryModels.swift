import Foundation

struct GalleryManifest: Decodable {
    let generatedAt: Date
    let rootName: String
    let albums: [GalleryAlbum]
}

struct YearManifest: Decodable {
    let generatedAt: Date
    let rootName: String
    let years: [GalleryYear]
}

struct YearResponse: Decodable {
    let generatedAt: Date
    let rootName: String
    let year: GalleryYear
    let albums: [GalleryAlbum]
}

struct AlbumResponse: Decodable {
    let generatedAt: Date
    let rootName: String
    let album: GalleryAlbum
}

struct GalleryYear: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let albumCount: Int
    let cover: GalleryPhoto?
}

struct GalleryAlbum: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
    let count: Int
    let cover: GalleryPhoto?
    let photos: [GalleryPhoto]

    init(id: String, title: String, path: String, count: Int, cover: GalleryPhoto?, photos: [GalleryPhoto]) {
        self.id = id
        self.title = title
        self.path = path
        self.count = count
        self.cover = cover
        self.photos = photos
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case path
        case count
        case cover
        case photos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        count = try container.decode(Int.self, forKey: .count)
        cover = try container.decodeIfPresent(GalleryPhoto.self, forKey: .cover)
        photos = try container.decodeIfPresent([GalleryPhoto].self, forKey: .photos) ?? []
    }
}

struct GalleryPhoto: Decodable, Identifiable, Hashable {
    let id: String
    let albumId: String
    let name: String
    let relativePath: String
    let url: URL
    let thumbURL: URL
    let modifiedAt: Date?
}
