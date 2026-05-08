import SwiftUI
import UIKit
import Photos

struct PhotoViewer: View {
    let album: GalleryAlbum
    let initialPhoto: GalleryPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var shareItem: ShareItem?
    @State private var isPreparingShare = false

    init(album: GalleryAlbum, initialPhoto: GalleryPhoto) {
        self.album = album
        self.initialPhoto = initialPhoto
        _selectedIndex = State(initialValue: album.photos.firstIndex(of: initialPhoto) ?? 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(album.photos.enumerated()), id: \.element.id) { index, photo in
                    ZoomableImage(photo: photo)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.photos[selectedIndex].name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(selectedIndex + 1) von \(album.photos.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button {
                    prepareShare(for: album.photos[selectedIndex])
                } label: {
                    if isPreparingShare {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                }
                .disabled(isPreparingShare)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.16), in: Circle())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.42))
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.fileURL], applicationActivities: [SaveToPhotosActivity()])
                .ignoresSafeArea()
        }
    }

    private func prepareShare(for photo: GalleryPhoto) {
        isPreparingShare = true
        Task {
            do {
                let fileURL = try await ShareFileLoader.shared.fileForSharing(photo: photo)
                await MainActor.run {
                    shareItem = ShareItem(fileURL: fileURL)
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                }
            }
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let applicationActivities: [UIActivity]?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class SaveToPhotosActivity: UIActivity {
    private var imageURL: URL?

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("de.michaelhein.piccloud.saveToPhotos")
    }

    override var activityTitle: String? {
        "In Bilder sichern"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "square.and.arrow.down")
    }

    override class var activityCategory: UIActivity.Category {
        .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { item in
            guard let url = item as? URL else { return false }
            return ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased())
        }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        imageURL = activityItems.compactMap { $0 as? URL }.first
    }

    override func perform() {
        guard let imageURL else {
            activityDidFinish(false)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.activityDidFinish(false)
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: imageURL, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self.activityDidFinish(success)
                }
            }
        }
    }
}

private final class ShareFileLoader {
    static let shared = ShareFileLoader()

    private init() {}

    func fileForSharing(photo: GalleryPhoto) async throws -> URL {
        let request = PicCloudCache.cachedRequest(for: photo.shareURL, timeout: 60)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let image = PicCloudCache.downsampledImage(from: data, maxPixelSize: 4096),
              let jpegData = image.jpegData(compressionQuality: 0.92) else {
            throw URLError(.cannotDecodeContentData)
        }

        let filename = photo.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let baseName = (filename as NSString).deletingPathExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-PicCloud")
            .appendingPathExtension("jpg")
        try jpegData.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private struct ZoomableImage: View {
    let photo: GalleryPhoto

    var body: some View {
        GeometryReader { proxy in
            let pixelSize = photo.viewerPixelSize(for: proxy.size)

            ZoomableImageView(url: photo.viewerURL(size: pixelSize), maxImagePixelSize: CGFloat(pixelSize))
                .ignoresSafeArea()
        }
    }
}

private extension GalleryPhoto {
    func viewerURL(size: Int) -> URL {
        sizedThumbnailURL(size: size) ?? url
    }

    var shareURL: URL {
        sizedThumbnailURL(size: 4096) ?? url
    }

    func viewerPixelSize(for viewport: CGSize) -> Int {
        let screenScale = UIScreen.main.scale
        let longestVisibleEdge = max(viewport.width, viewport.height)
        let requestedPixels = Int((longestVisibleEdge * screenScale).rounded(.up))
        return min(4096, max(1600, requestedPixels))
    }

    private func sizedThumbnailURL(size: Int) -> URL? {
        let marker = "/thumb/"
        guard let range = thumbURL.absoluteString.range(of: marker) else {
            return nil
        }

        let prefix = thumbURL.absoluteString[..<range.upperBound]
        let suffixStart = thumbURL.absoluteString[range.upperBound...]
        guard let slashIndex = suffixStart.firstIndex(of: "/") else {
            return nil
        }

        let path = suffixStart[slashIndex...]
        return URL(string: "\(prefix)\(size)\(path)")
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let url: URL
    let maxImagePixelSize: CGFloat

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutAwareScrollView()
        scrollView.onBoundsChanged = { [weak coordinator = context.coordinator] in
            coordinator?.configureLayout(resetZoom: true)
        }
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.addSubview(context.coordinator.imageView)

        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.resetZoom))
        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.delegate = context.coordinator
        scrollView.addGestureRecognizer(tapRecognizer)

        context.coordinator.scrollView = scrollView
        context.coordinator.load(url: url, maxPixelSize: maxImagePixelSize)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.scrollView = scrollView
        context.coordinator.load(url: url, maxPixelSize: maxImagePixelSize)
        context.coordinator.configureLayout(resetZoom: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        private var currentURL: URL?
        private var imageSize = CGSize.zero

        override init() {
            super.init()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
        }

        func load(url: URL, maxPixelSize: CGFloat) {
            guard currentURL != url else { return }
            currentURL = url
            imageView.image = nil
            imageSize = .zero
            resetScrollView()

            let request = PicCloudCache.cachedRequest(for: url, timeout: 60)
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let self, let data else { return }
                let image = PicCloudCache.downsampledImage(from: data, maxPixelSize: maxPixelSize)
                DispatchQueue.main.async {
                    guard self.currentURL == url, let image else { return }
                    self.imageView.image = image
                    self.imageSize = image.size
                    self.configureLayout()
                }
            }.resume()
        }

        func configureLayout(resetZoom: Bool = false) {
            guard let scrollView, imageSize.width > 0, imageSize.height > 0 else { return }

            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }

            let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)

            imageView.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = max(1, 1 / fitScale)

            if resetZoom {
                scrollView.zoomScale = scrollView.minimumZoomScale
                scrollView.contentOffset = .zero
            } else if scrollView.zoomScale < scrollView.minimumZoomScale || scrollView.zoomScale > scrollView.maximumZoomScale {
                scrollView.zoomScale = scrollView.minimumZoomScale
            }
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
        }

        @objc func resetZoom() {
            guard let scrollView else { return }
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                scrollView.zoomScale = scrollView.minimumZoomScale
                scrollView.contentOffset = .zero
                self.centerImage()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func centerImage() {
            guard let scrollView else { return }
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let horizontalInset = max(0, (bounds.width - content.width) / 2)
            let verticalInset = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        private func resetScrollView() {
            guard let scrollView else { return }
            scrollView.zoomScale = 1
            scrollView.contentOffset = .zero
            scrollView.contentSize = .zero
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 1
            imageView.frame = .zero
            scrollView.contentInset = .zero
        }

    }
}

private final class LayoutAwareScrollView: UIScrollView {
    var onBoundsChanged: (() -> Void)?
    private var lastBoundsSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()

        let currentSize = bounds.size
        guard currentSize != lastBoundsSize else { return }
        lastBoundsSize = currentSize
        onBoundsChanged?()
    }
}
