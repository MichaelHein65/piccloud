import SwiftUI

struct GalleryView: View {
    @StateObject private var store = GalleryStore()
    @State private var selectedYear: GalleryYear?

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 14),
        GridItem(.flexible(minimum: 0), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    connectionBar

                    if store.isLoading {
                        loadingState
                    } else if store.years.isEmpty {
                        emptyState
                    } else {
                        HStack(alignment: .lastTextBaseline) {
                            Text("Jahre")
                                .font(.title2.bold())
                            Spacer()
                            Text("\(store.years.reduce(0) { $0 + $1.count }) Bilder")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.years) { year in
                                Button {
                                    selectedYear = year
                                } label: {
                                    YearTile(year: year)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [Color(.systemBackground), Color(.secondarySystemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .navigationTitle("PicCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .navigationDestination(item: $selectedYear) { year in
                YearView(year: year, store: store)
            }
            .task {
                await store.load()
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(url: store.years.first?.cover?.thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: 210)
            .clipped()

            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                Text("PicCloud")
                    .font(.largeTitle.weight(.bold))
                Text("Deine Bilder ueber Tailscale")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(.teal)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Server URL", text: $store.serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .onSubmit {
                        Task { await store.load() }
                    }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text(store.isLoading ? "Verbinde..." : "Tailscale Galerie")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await store.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Lade Albumliste...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Keine Bilder geladen",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Starte den PicCloud-Server und trage seine Adresse ein.")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private struct YearTile: View {
    let year: GalleryYear

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: year.cover?.thumbURL) { phase in
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
                    Text(year.title)
                        .font(.system(size: 32, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(year.albumCount) Alben · \(year.count) Bilder")
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
