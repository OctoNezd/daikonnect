import SwiftUI
import AppKit

/// Version, the project's home on GitHub, and Sparkle's "Check for Updates…".
struct AboutView: View {
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
                Text("Version \(AppMeta.version) (build \(AppMeta.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            Link("github.com/octonezd/daikonnect", destination: AppMeta.repositoryURL)
                .font(.callout)

            Divider()

            CheckForUpdatesView()
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 340)
    }
}

#Preview {
    AboutView()
}
