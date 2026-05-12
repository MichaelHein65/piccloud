import SwiftUI

struct YearView: View {
    let year: GalleryYear
    @ObservedObject var store: GalleryStore
    @State private var albums: [GalleryAlbum] = []
    @State private var selectedAlbum: GalleryAlbum?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            Group {
                if isLandscape {
                    landscapeContent(size: proxy.size)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            albumContent
                        }
                        .padding(16)
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(year.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumView(album: album, store: store)
        }
        .task {
            await loadYear()
        }
    }

    @ViewBuilder
    private func landscapeContent(size: CGSize) -> some View {
        let availableHeight = max(220, size.height - 32)
        let headerSide = min(size.width * 0.42, availableHeight)
        let tileSide = min(170, max(126, (availableHeight - 10) / 2))
        let rows = [
            GridItem(.fixed(tileSide), spacing: 10),
            GridItem(.fixed(tileSide), spacing: 10)
        ]

        HStack(alignment: .top, spacing: 14) {
            fixedHeader(side: headerSide)

            VStack(alignment: .leading, spacing: 10) {
                if isLoading || errorMessage != nil {
                    albumContent
                        .frame(maxWidth: .infinity, minHeight: headerSide)
                } else {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: rows, spacing: 10) {
                            ForEach(albums) { album in
                                Button {
                                    selectedAlbum = album
                                } label: {
                                    AlbumTile(album: album)
                                        .frame(width: tileSide, height: tileSide)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: tileSide * 2 + 10)
                        .padding(.trailing, 16)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(16)
    }

    @ViewBuilder
    private var albumContent: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Lade Alben...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if let errorMessage {
            ContentUnavailableView(
                "Jahr konnte nicht geladen werden",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        AlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var header: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            fixedHeader(side: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func fixedHeader(side: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(url: year.cover?.thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: side, height: side)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 5) {
                Text(year.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(year.albumCount) Alben · \(year.count) Bilder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(width: side, alignment: .leading)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadYear() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            albums = try await store.loadYear(year)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AlbumTile: View {
    let album: GalleryAlbum

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: album.cover?.thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.secondarySystemGroupedBackground))
                    default:
                        Rectangle().fill(Color(.secondarySystemGroupedBackground))
                    }
                }
                .frame(width: side, height: side)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Text("\(album.count) Bilder")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .foregroundStyle(.white)
                .padding(12)
                .frame(width: side, alignment: .leading)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 6)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
