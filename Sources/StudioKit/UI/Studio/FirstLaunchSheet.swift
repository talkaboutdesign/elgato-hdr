import AppKit
import SwiftUI

/// Shown once, before the administrator prompt: says why the password is needed and offers the demo source.
struct FirstLaunchSheet: View {
    let onContinue: () -> Void
    let onDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock the card's HDR signal").font(.system(size: 15, weight: .semibold))
                    Text("macOS will ask for your password next").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("macOS only lets apps see the 8-bit video modes of the capture card, so \(AppInfo.name) starts a small helper that reads the 10-bit HDR signal directly. The helper needs administrator rights, so macOS asks for your password when capture starts.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try the Demo Source", action: onDemo)
                    .help("Explore the app with a synthetic test picture; no password, no capture card")
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .help("Ask for the administrator password and start capturing")
            }
            .controlSize(.large)
            .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xl)
        .frame(width: 440)
    }
}
