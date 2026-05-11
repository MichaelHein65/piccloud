import SwiftUI

struct AlbumView: View {
    let album: GalleryAlbum
    @ObservedObject var store: GalleryStore
    @State private var loadedAlbum: GalleryAlbum?
    @State private var selectedPhoto: GalleryPhoto?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 155), spacing: 3)
    ]

    private var displayAlbum: GalleryAlbum {
        loadedAlbum ?? album
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                albumHeader

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Lade Bilder...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Album konnte nicht geladen werden",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(displayAlbum.photos) { photo in
                            Button {
                                selectedPhoto = photo
                            } label: {
                                PhotoTile(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAlbum()
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewer(album: displayAlbum, initialPhoto: photo)
        }
    }

    private func loadAlbum() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            loadedAlbum = try await store.loadAlbum(album)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var albumHeader: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: displayAlbum.cover?.thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color(.secondarySystemGroupedBackground))
                    }
                }
                .frame(width: side, height: side)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 5) {
                    Text(album.title)
                        .font(.title.weight(.bold))
                        .lineLimit(2)
                    Text("\(displayAlbum.count) Bilder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.84))
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(width: side, alignment: .leading)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.top, 10)
    }
}

private struct PhotoTile: View {
    let photo: GalleryPhoto

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            CachedRemoteImage(url: photo.thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Rectangle().fill(Color(.secondarySystemGroupedBackground))
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
