import LocalAuthentication
import SwiftUI

@main
struct PicCloudApp: App {
    @StateObject private var galleryStore = GalleryStore()

    init() {
        PicCloudCache.configure()
    }

    var body: some Scene {
        WindowGroup {
            AuthenticationGate {
                GalleryView(store: galleryStore)
            }
        }
    }
}

private struct AuthenticationGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked = false
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            if isUnlocked {
                content
            } else {
                lockView
            }
        }
        .task {
            authenticate()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if !isUnlocked {
                    authenticate()
                }
            case .inactive, .background:
                isUnlocked = false
                errorMessage = nil
            @unknown default:
                break
            }
        }
    }

    private var lockView: some View {
        VStack(spacing: 18) {
            Image(systemName: "faceid")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("PicCloud ist gesperrt")
                    .font(.title2.bold())
                Text("Entsperre die App mit Face ID oder deinem Geraetecode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                authenticate()
            } label: {
                Label("Entsperren", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @MainActor
    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil

        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        context.localizedFallbackTitle = "Code verwenden"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            errorMessage = authError?.localizedDescription ?? "Auf diesem Gerät ist keine Entsperrung eingerichtet."
            isAuthenticating = false
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "PicCloud entsperren") { success, _ in
            Task { @MainActor in
                isUnlocked = success
                if !success {
                    errorMessage = "PicCloud wurde nicht entsperrt."
                }
                isAuthenticating = false
            }
        }
    }
}
