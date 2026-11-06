import LicenseManagerKit
import SwiftUI

// Replace with your product's id and public key (dashboard > Products > SDK).
// These belong to a test product: any key you create for it in the dashboard works.
let productID = "x7Kp2QaZ"
let publicKey = """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEA4/XqAdkS+6UaZFdyAVwZ2oaFhKmvwjT44tVq940jjUE=
    -----END PUBLIC KEY-----
    """

/// One instance for the whole app.
let licenseManager: LicenseManager = {
    do {
        return try LicenseManager(
            productID: productID,
            publicKey: publicKey,
            // `swift run` builds have no Info.plist: pass the version explicitly.
            options: .init(version: "1.0.0", minOfflineDuration: 14 * 24 * 60 * 60)
        )
    } catch {
        fatalError("LicenseManager configuration: \(error.localizedDescription)")
    }
}()

@main
struct ExampleApp: App {
    @StateObject private var license = LicenseObserver(manager: licenseManager)

    var body: some Scene {
        WindowGroup("LicenseManager Example") {
            Group {
                switch license.state {
                case .loading:
                    ProgressView("Checking your license…")
                case .active:
                    AppView()
                case .missingKey:
                    ActivationView()
                default:
                    LockedView()
                }
            }
            .frame(minWidth: 460, minHeight: 320)
            .environmentObject(license)
        }
    }
}

struct ActivationView: View {
    @EnvironmentObject private var license: LicenseObserver
    @State private var key = ""
    @State private var error: String?
    @State private var activating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your license key").font(.title2.bold())
            Text("You received it by email after your purchase.").foregroundStyle(.secondary)
            TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(activate)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Activate", action: activate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || activating)
                if activating { ProgressView().controlSize(.small) }
            }
        }
        .padding(32)
    }

    func activate() {
        activating = true
        error = nil
        Task {
            defer { activating = false }
            do throws(LicenseError) {
                try await license.activate(key: key)
            } catch {
                self.error = message(for: error)
            }
        }
    }

    func message(for error: LicenseError) -> String {
        switch error.code {
        case .notFound: "This license key doesn't exist. Check for typos."
        case .licenseExpired: "This license has expired."
        case .machineLimitReached: "This license is already used on its maximum number of Macs."
        case .versionNotAllowed: "This license doesn't include this version of the app."
        case .networkError: "Couldn't reach the license server. Check your connection and try again."
        default: "Activation failed (\(error.code.rawValue))."
        }
    }
}

struct LockedView: View {
    @EnvironmentObject private var license: LicenseObserver

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Try again") { Task { await license.refresh() } }
                Button("Manage license") { license.openPortal() }
            }
        }
        .padding(32)
    }

    var title: String {
        switch license.state {
        case .expired: "Your license has expired"
        case .invalidKey: "Your license key is no longer valid"
        case .machineLimitReached: "Too many Macs"
        case .versionNotAllowed: "This version isn't included in your license"
        case .clockTampered: "Your clock looks wrong"
        default: "Can't verify your license"
        }
    }

    var detail: String {
        switch license.state {
        case .versionNotAllowed:
            if case .version(let version) = license.latestAllowedVersion {
                "Your license covers up to version \(version)."
            } else {
                "Renew your license to get updates."
            }
        case .machineLimitReached: "Deactivate another Mac in the customer portal."
        case .clockTampered: "Set your Mac's date and time automatically, then try again."
        case .offlineExpired: "Connect to the internet so the app can check your license."
        default: "Renew or manage your license in the customer portal."
        }
    }
}

struct AppView: View {
    @EnvironmentObject private var license: LicenseObserver
    @State private var exported = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Licensed").font(.title2.bold())
            if let hint = license.licenseKeyHint {
                Text("Key ending in \(hint)").foregroundStyle(.secondary)
            }
            if case .offline(let validUntil?, _) = license.offlineState {
                Text("Offline, works until \(validUntil.formatted(date: .abbreviated, time: .omitted))")
                    .foregroundStyle(.secondary)
            }
            Button("Export (paid feature)") { exported = export() }
            if exported { Text("Exported.") }
            Button("Manage license") { license.openPortal() }
        }
        .padding(32)
    }
}

/// A paid feature checks the license where it runs, not only in the UI.
func export() -> Bool {
    guard licenseManager.state == .active else { return false }
    // ... do the export
    return true
}
