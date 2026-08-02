import AVFoundation
import CoreLocation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareUploadModel(extensionContext: extensionContext)
        let host = UIHostingController(rootView: ShareUploadView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        Task { await model.prepare() }
    }
}

private struct SharedFile {
    let url: URL
    let originalName: String
    let kind: String
    let capturedAt: Date
    let coordinate: CLLocationCoordinate2D?
    var place = "Unbekannter Ort"
}

@MainActor
private final class ShareUploadModel: ObservableObject {
    enum State { case loading, ready, uploading, finished, failed }
    @Published var state: State = .loading
    @Published var folderName = ""
    @Published var status = "Bilder und Metadaten werden gelesen …"
    @Published var progress = 0.0

    private weak var extensionContext: NSExtensionContext?
    private var files: [SharedFile] = []
    private let geocoder = CLGeocoder()
    private var placeCache: [String: String] = UserDefaults(suiteName: "group.de.michaelhein.piccloud")?
        .dictionary(forKey: "PicCloud.placeCache") as? [String: String] ?? [:]
    private let displayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    init(extensionContext: NSExtensionContext?) { self.extensionContext = extensionContext }

    func prepare() async {
        do {
            files = try await loadSharedFiles()
            guard !files.isEmpty else { throw UploadError.message("Keine unterstützten Bilder oder Filme ausgewählt.") }
            files.sort { $0.capturedAt < $1.capturedAt }
            status = "Orte werden bestimmt …"
            var places: [String] = []
            for index in files.indices {
                let place = await placeName(for: files[index].coordinate)
                files[index].place = place
                if index < 5 && place != "Unbekannter Ort" && !places.contains(place) { places.append(place) }
            }
            let title = places.prefix(3).joined(separator: "-")
            folderName = "\(displayDate.string(from: files[0].capturedAt)) \(title.isEmpty ? "Unbekannter Ort" : title)"
            status = "\(files.count) Datei\(files.count == 1 ? "" : "en") ausgewählt"
            state = .ready
        } catch {
            fail(error)
        }
    }

    func upload() async {
        let cleaned = folderName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.range(of: #"^(19|20)\d{6} .+"#, options: .regularExpression) != nil else {
            status = "Der Name muss mit einem Datum im Format yyyyMMdd beginnen."
            return
        }
        state = .uploading
        do {
            let baseURL = sharedServerURL()
            let session = try await createSession(baseURL: baseURL, folderName: cleaned)
            status = "Upload wird im Hintergrund eingeplant …"
            let taskIDs = files.enumerated().map { offset, file in
                BackgroundUploader.shared.schedule(file: file.url, index: offset, sessionID: session, baseURL: baseURL)
            }
            for (offset, taskID) in taskIDs.enumerated() {
                try await BackgroundUploader.shared.wait(for: taskID)
                progress = Double(offset + 1) / Double(files.count)
                status = "\(offset + 1) von \(files.count) Dateien übertragen"
            }
            state = .finished
            status = BackgroundUploader.shared.wasHandedOff
                ? "Upload läuft im Hintergrund weiter: \(cleaned)"
                : "Gespeichert in \(cleaned)"
        } catch {
            fail(error)
        }
    }

    func close(completed: Bool) {
        if completed { extensionContext?.completeRequest(returningItems: nil) }
        else { extensionContext?.cancelRequest(withError: UploadError.message("Vom Benutzer abgebrochen")) }
    }

    private func loadSharedFiles() async throws -> [SharedFile] {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        return try await withThrowingTaskGroup(of: SharedFile?.self) { group in
            for provider in providers {
                group.addTask { try await Self.load(provider: provider) }
            }
            var result: [SharedFile] = []
            for try await file in group { if let file { result.append(file) } }
            return result
        }
    }

    nonisolated private static func load(provider: NSItemProvider) async throws -> SharedFile? {
        let kind: String
        let type: UTType
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { kind = "movie"; type = .movie }
        else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            kind = "image"
            // Asking Photos for the generic public.image representation may silently
            // transcode HEIC to JPEG. Prefer the concrete registered original type.
            let registeredTypes = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            type = registeredTypes.first(where: { $0 == .heic })
                ?? registeredTypes.first(where: { $0.identifier == "public.heif" })
                ?? registeredTypes.first(where: { $0.conforms(to: .image) })
                ?? .image
        }
        else { return nil }
        let destination = try await provider.copyFileRepresentation(for: type)
        var original = provider.suggestedName ?? destination.lastPathComponent
        if URL(fileURLWithPath: original).pathExtension.isEmpty {
            original += ".\(destination.pathExtension)"
        }
        let metadata = kind == "movie" ? await movieMetadata(destination) : imageMetadata(destination)
        return SharedFile(url: destination, originalName: original, kind: kind, capturedAt: metadata.0, coordinate: metadata.1)
    }

    nonisolated private static func imageMetadata(_ url: URL) -> (Date, CLLocationCoordinate2D?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (fileDate(url), nil)
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dateText = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let date = parseEXIFDate(dateText) ?? fileDate(url)
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        guard var latitude = gps?[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps?[kCGImagePropertyGPSLongitude] as? Double else { return (date, nil) }
        if (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
        if (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
        return (date, CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    nonisolated private static func movieMetadata(_ url: URL) async -> (Date, CLLocationCoordinate2D?) {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let dateItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate).first
        let dateText = try? await dateItem?.load(.stringValue)
        let date = dateText.flatMap { ISO8601DateFormatter().date(from: $0) } ?? fileDate(url)
        let locationItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation).first
        let locationText = try? await locationItem?.load(.stringValue)
        return (date, locationText.flatMap(parseISO6709))
    }

    nonisolated private static func parseEXIFDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    nonisolated private static func parseISO6709(_ value: String) -> CLLocationCoordinate2D? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latRange = Range(match.range(at: 1), in: value), let lonRange = Range(match.range(at: 2), in: value),
              let lat = Double(value[latRange]), let lon = Double(value[lonRange]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    nonisolated private static func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]).creationDate) ?? Date()
    }

    private func placeName(for coordinate: CLLocationCoordinate2D?) async -> String {
        guard let coordinate else { return "Unbekannter Ort" }
        let key = placeCacheKey(coordinate)
        if let cached = placeCache[key] { return cached }
        if let nearby = nearbyCachedPlace(to: coordinate, maximumKilometers: 3) { return nearby }

        for attempt in 0..<2 {
            do {
                let marks = try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    preferredLocale: Locale(identifier: "de_DE")
                )
                let mark = marks.first
                let place = sanitizePlace(mark?.locality ?? mark?.subLocality ?? mark?.administrativeArea ?? mark?.name)
                if place != "Unbekannter Ort" {
                    placeCache[key] = place
                    UserDefaults(suiteName: "group.de.michaelhein.piccloud")?.set(placeCache, forKey: "PicCloud.placeCache")
                    try? await Task.sleep(for: .milliseconds(250))
                    return place
                }
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return nearbyCachedPlace(to: coordinate, maximumKilometers: 10) ?? "Unbekannter Ort"
    }

    private func placeCacheKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private func nearbyCachedPlace(to coordinate: CLLocationCoordinate2D, maximumKilometers: Double) -> String? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var closest: (place: String, distance: CLLocationDistance)?
        for (key, place) in placeCache {
            let parts = key.split(separator: ",")
            guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { continue }
            let distance = target.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            if distance <= maximumKilometers * 1_000 && (closest == nil || distance < closest!.distance) {
                closest = (place, distance)
            }
        }
        return closest?.place
    }

    private func sanitizePlace(_ value: String?) -> String {
        let cleaned = (value ?? "").replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unbekannter Ort" : cleaned
    }

    private func sharedServerURL() -> URL {
        let defaults = UserDefaults(suiteName: "group.de.michaelhein.piccloud")
        let text = defaults?.string(forKey: "PicCloud.serverURL") ?? "http://100.104.66.88:8098"
        return URL(string: text.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
    }

    private func createSession(baseURL: URL, folderName: String) async throws -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd HH-mm"
        let descriptions: [[String: Any]] = files.map {
            ["originalName": $0.originalName, "mediaKind": $0.kind, "timestamp": formatter.string(from: $0.capturedAt), "place": $0.place]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("upload/session"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["folderName": folderName, "files": descriptions])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let session = json["sessionId"] as? String else { throw UploadError.message("Ungültige Serverantwort") }
        return session
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UploadError.message(detail?.isEmpty == false ? detail! : "Der PiCloud-Server hat den Upload abgelehnt.")
        }
    }

    private func fail(_ error: Error) { state = .failed; status = error.localizedDescription }
}

private enum UploadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private struct ShareUploadView: View {
    @ObservedObject var model: ShareUploadModel
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if model.state == .loading { ProgressView().frame(maxWidth: .infinity) }
                if model.state == .ready {
                    Text("Ordnername").font(.headline)
                    TextField("yyyyMMdd Titel", text: $model.folderName).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    Text("Du kannst den vorgeschlagenen Namen vor dem Upload ändern.").font(.footnote).foregroundStyle(.secondary)
                }
                if model.state == .uploading { ProgressView(value: model.progress) }
                if model.state == .finished { Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green).frame(maxWidth: .infinity) }
                if model.state == .failed { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange).frame(maxWidth: .infinity) }
                Text(model.status).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                if model.state == .ready { Button("Weiter") { Task { await model.upload() } }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity) }
                if model.state == .finished || model.state == .failed { Button(model.state == .finished ? "Fertig" : "Schließen") { model.close(completed: model.state == .finished) }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity) }
            }
            .padding().navigationTitle("In PicCloud sichern")
            .toolbar { if model.state != .uploading && model.state != .finished { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { model.close(completed: false) } } } }
        }
    }
}

private extension NSItemProvider {
    func copyFileRepresentation(for type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? UploadError.message("Datei konnte nicht gelesen werden"))
                    return
                }
                let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "dat" : url.pathExtension
                guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.michaelhein.piccloud") else {
                    continuation.resume(throwing: UploadError.message("Der gemeinsame Upload-Speicher ist nicht verfügbar"))
                    return
                }
                let uploadDirectory = container.appendingPathComponent("PendingUploads", isDirectory: true)
                do { try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true) }
                catch { continuation.resume(throwing: error); return }
                let destination = uploadDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class BackgroundUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let identifier = "de.michaelhein.piccloud.share.upload"

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var completed: [Int: Result<Void, Error>] = [:]
    private var fileURLs: [Int: URL] = [:]
    private var handedOff = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sharedContainerIdentifier = "group.de.michaelhein.piccloud"
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func schedule(file: URL, index: Int, sessionID: String, baseURL: URL) -> Int {
        if index == 0 { lock.lock(); handedOff = false; lock.unlock() }
        var request = URLRequest(url: baseURL.appendingPathComponent("upload/\(sessionID)/\(index)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = file.path
        lock.lock(); fileURLs[task.taskIdentifier] = file; lock.unlock()
        task.resume()
        return task.taskIdentifier
    }

    var wasHandedOff: Bool {
        lock.lock(); defer { lock.unlock() }
        return handedOff
    }

    func wait(for taskID: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = completed.removeValue(forKey: taskID) {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                continuations[taskID] = continuation
                lock.unlock()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Void, Error>
        if let urlError = error as? URLError,
           urlError.code == .backgroundSessionWasDisconnected || urlError.code == .backgroundSessionInUseByAnotherProcess {
            // iOS has detached this extension process from the background service.
            // All upload tasks were already scheduled and continue under system control.
            lock.lock(); handedOff = true; lock.unlock()
            result = .success(())
        } else if let error {
            result = .failure(error)
        } else if let response = task.response as? HTTPURLResponse, (200...299).contains(response.statusCode) {
            result = .success(())
        } else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(UploadError.message("Der PiCloud-Server meldet HTTP \(code)."))
        }
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        if continuation == nil { completed[task.taskIdentifier] = result }
        let fileURL = fileURLs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if case .success = result, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        continuation?.resume(with: result)
    }
}
