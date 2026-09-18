import SwiftUI
import AppKit

/// Version, the project's home on GitHub, and a button that asks whether
/// there is a newer build.
struct AboutView: View {
    @ObservedObject var checker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text(AppMeta.AppName)
                    .font(.title2.weight(.semibold))
                Text("A KDE Connect client for the Mac.")
                    .foregroundStyle(.secondary)
                Text("Version \(checker.version) (build \(checker.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            Link("github.com/octonezd/daikonnect", destination: UpdateChecker.repositoryURL)
                .font(.callout)

            Divider()

            updateRow
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 340)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch checker.state {
        case .idle:
            Button("Check for Updates") { checker.check() }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            VStack(spacing: 8) {
                Label("This is the latest build.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Button("Check Again") { checker.check() }
            }
        case let .updateAvailable(version, build, page, download):
            VStack(spacing: 8) {
                Label("Build \(build) is available.", systemImage: "arrow.down.circle")
                Text("This build is \(checker.build). The release is \(version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Release Notes", destination: page)
                    if let download {
                        Link("Download", destination: download)
                    }
                }
            }
        case let .failed(reason):
            VStack(spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { checker.check() }
            }
        }
    }
}

#Preview("Up to date") {
    let checker = UpdateChecker.shared
    checker.setStateForPreview(.upToDate)
    return AboutView()
}

#Preview("Update available") {
    let checker = UpdateChecker.shared
    checker.setStateForPreview(.updateAvailable(version: "v1.0.99", build: 99,
                                           page: URL(string: "https://github.com/octonezd/daikonnect/releases/tag/v1.0.99")!,
                                           download: URL(string: "https://example.com/daiKonnect.dmg")))
    return AboutView()
}
