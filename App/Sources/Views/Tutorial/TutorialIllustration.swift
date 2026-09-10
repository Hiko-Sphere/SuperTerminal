import SwiftUI

/// The picture on each page of the tour (D-033).
///
/// Drawn rather than screenshotted. A screenshot of the app inside the app goes stale the
/// first time a colour or a corner radius changes, and at three scale factors and two
/// appearances it is six images to keep honest. These are built from the same tokens as
/// the interface they describe, so they cannot drift from it.
struct TutorialIllustration: View {
    let kind: TutorialPage.Illustration
    /// 0 before the page appears, 1 after. Every element leans on this so the whole
    /// picture assembles itself once, in order, rather than sliding in as one block.
    let phase: Double

    var body: some View {
        Group {
            switch kind {
            case .address: address
            case .fingerprint: fingerprint
            case .keyRow: keyRow
            case .palette: palette
            case .screen: screen
            case .panes: panes
            case .keychain: keychain
            case .files: files
            case .forwarding: forwarding
            }
        }
        .frame(maxWidth: 360)
        // The picture repeats what the words already say, so a screen reader that read
        // both would say everything twice.
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Color.surfaceCard, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .strokeBorder(DesignTokens.Color.separator, lineWidth: 0.5)
            )
            .stCardShadow()
    }

    /// Fades and lifts one element into place, `step` places it in the order.
    private func entrance(_ step: Int) -> some ViewModifier {
        Entrance(progress: phase, step: step)
    }

    private struct Entrance: ViewModifier {
        let progress: Double
        let step: Int
        func body(content: Content) -> some View {
            // Each element gets its own slice of the run, so they arrive one after
            // another. The offset is capped: at a flat 0.12 per step the eighth element
            // started at 0.84 of a run that ends at 1.0 and never reached full opacity —
            // the busiest picture was the one that stayed half-drawn.
            let start = min(Double(step) * 0.055, 0.40)
            let local = min(max((progress - start) / 0.60, 0), 1)
            return content
                .opacity(local)
                .offset(y: (1 - local) * 10)
        }
    }

    private func chip(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignTokens.Color.label)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private func keyCap(_ label: String, latched: Bool = false, wide: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(latched ? Color.white : DesignTokens.Color.label)
            .frame(width: wide ? 46 : 32, height: 30)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(latched ? DesignTokens.Color.accent : DesignTokens.Color.surfaceSecondary)
            )
    }

    // MARK: - Pages

    private var address: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            card {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(DesignTokens.Color.accent)
                    Text(verbatim: "deploy@build.example.com:2222")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .modifier(entrance(0))

            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .modifier(entrance(1))

            HStack(spacing: DesignTokens.Spacing.sm) {
                chip(String(localized: "USER"), "deploy", DesignTokens.Color.info)
                    .modifier(entrance(2))
                chip(String(localized: "HOST"), "build.example.com", DesignTokens.Color.success)
                    .modifier(entrance(3))
                chip(String(localized: "PORT"), "2222", DesignTokens.Color.warning)
                    .modifier(entrance(4))
            }
        }
    }

    private var fingerprint: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            card {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "touchid")
                        .font(.system(size: 40))
                        .foregroundStyle(DesignTokens.Color.success)
                        .modifier(entrance(0))
                    Text(verbatim: "SHA256:9Xk2…qF1c")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .modifier(entrance(1))
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Matches — remembered")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.success)
                    .modifier(entrance(2))
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.shield.fill")
                Text("A key that changes is refused")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DesignTokens.Color.warning)
            .modifier(entrance(3))
        }
    }

    private var keyRow: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            card {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    keyCap("ctrl", latched: true, wide: true).modifier(entrance(0))
                    keyCap("esc", wide: true).modifier(entrance(1))
                    keyCap("tab", wide: true).modifier(entrance(2))
                    keyCap("←").modifier(entrance(3))
                    keyCap("↑").modifier(entrance(4))
                    keyCap("↓").modifier(entrance(5))
                    keyCap("→").modifier(entrance(6))
                }
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("latched")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(DesignTokens.Color.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(DesignTokens.Color.accent)
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                keyCap("C")
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                Text(verbatim: "^C")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            .modifier(entrance(7))
        }
    }

    private var palette: some View {
        card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                    Text(verbatim: "dep")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(verbatim: "⌘K")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
                .modifier(entrance(0))
                Divider()
                paletteRow("server.rack", "deploy@build", String(localized: "Connection"), 1)
                paletteRow("text.badge.plus", String(localized: "Tail the deploy log"), String(localized: "Snippet"), 2)
                paletteRow("bolt", String(localized: "Disconnect All"), String(localized: "Action"), 3)
            }
        }
    }

    private func paletteRow(_ symbol: String, _ title: String, _ kind: String, _ step: Int) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(DesignTokens.Color.accent)
                .frame(width: 16)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(kind)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
        .modifier(entrance(step))
    }

    private var screen: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            card {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach([DesignTokens.Color.danger, DesignTokens.Color.warning, DesignTokens.Color.success], id: \.self) { dot in
                            Circle().fill(dot).frame(width: 6, height: 6)
                        }
                        Spacer()
                    }
                    .padding(.bottom, DesignTokens.Spacing.sm)
                    .modifier(entrance(0))

                    ZStack {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .fill(DesignTokens.Color.surfaceSecondary)
                            .frame(height: 74)
                        Circle()
                            .strokeBorder(DesignTokens.Color.accent, lineWidth: 2)
                            .frame(width: 26, height: 26)
                            .opacity(0.9)
                    }
                    .modifier(entrance(1))
                }
            }
            HStack(spacing: DesignTokens.Spacing.md) {
                gesture("hand.tap", String(localized: "Tap"), 2)
                gesture("hand.draw", String(localized: "Hold to drag"), 3)
                gesture("hand.point.up.left", String(localized: "Two fingers scroll"), 4)
            }
        }
    }

    /// Split panes: one card divided the way the app divides it, with the two keys that
    /// do it underneath. The right half is split again, because the interesting claim is
    /// that the arrangement nests rather than that it halves.
    private var panes: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            card {
                HStack(spacing: 3) {
                    paneBox(lines: 4, focused: true, step: 0)
                    VStack(spacing: 3) {
                        paneBox(lines: 2, focused: false, step: 1)
                        paneBox(lines: 2, focused: false, step: 2)
                    }
                }
                .frame(height: 92)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                keyCap("⌘D", wide: true).modifier(entrance(3))
                keyCap("⇧⌘D", wide: true).modifier(entrance(4))
            }
        }
    }

    private func paneBox(lines: Int, focused: Bool, step: Int) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .fill(DesignTokens.Color.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(
                        focused ? DesignTokens.Color.accent : DesignTokens.Color.separator,
                        lineWidth: focused ? 1.5 : 0.5
                    )
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0 ..< lines, id: \.self) { line in
                        Capsule()
                            .fill(DesignTokens.Color.labelTertiary.opacity(0.5))
                            .frame(width: line == lines - 1 ? 22 : 40, height: 3)
                    }
                }
                .padding(DesignTokens.Spacing.sm)
            }
            .modifier(entrance(step))
    }

    private func gesture(_ symbol: String, _ label: String, _ step: Int) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(DesignTokens.Color.accent)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .modifier(entrance(step))
    }

    private var keychain: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            row("key.fill", String(localized: "Private keys"), String(localized: "This device's Keychain"), DesignTokens.Color.success, 0)
            row("arrow.triangle.2.circlepath", String(localized: "iCloud sync"), String(localized: "Not available yet"), DesignTokens.Color.info, 1)
            row("faceid", String(localized: "App lock"), String(localized: "Optional"), DesignTokens.Color.accent, 2)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ tint: Color, _ step: Int) -> some View {
        card {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                Spacer()
            }
        }
        .modifier(entrance(step))
    }

    /// A folder on a server, as the browser draws it. The claim worth picturing is that
    /// these are the *server's* files with the server's own permissions and owners — not a
    /// copy of them on the phone — so the mode column is what the picture is built around.
    private var files: some View {
        card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.accent)
                    Text(verbatim: "/srv/www")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(verbatim: "SFTP")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
                .modifier(entrance(0))
                Divider()
                fileRow("folder.fill", "releases", "drwxr-xr-x", DesignTokens.Color.info, 1)
                fileRow("doc.text", "nginx.conf", "-rw-r--r--", DesignTokens.Color.labelSecondary, 2)
                fileRow("gearshape", "deploy.sh", "-rwxr-xr-x", DesignTokens.Color.success, 3)
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("Also in the Files app")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.Color.accent)
                .modifier(entrance(4))
            }
        }
    }

    private func fileRow(_ symbol: String, _ name: String, _ mode: String, _ tint: Color, _ step: Int) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(verbatim: name)
                .font(.system(size: 12))
            Spacer()
            Text(verbatim: mode)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
        .modifier(entrance(step))
    }

    /// Which way a forwarded port points, which is the whole difficulty: "local" and
    /// "remote" name the end the *listener* is on, and everyone gets it backwards once. The
    /// two rows are drawn as mirror images so the difference is the arrow, not the words.
    private var forwarding: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            card {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    forwardingRow(
                        kind: String(localized: "LOCAL"),
                        left: String(localized: "this device"),
                        leftPort: "5432",
                        right: String(localized: "the server’s network"),
                        rightPort: "db:5432",
                        tint: DesignTokens.Color.info,
                        reversed: false,
                        step: 0
                    )
                    Divider()
                    forwardingRow(
                        kind: String(localized: "REMOTE"),
                        left: String(localized: "this device"),
                        leftPort: "3000",
                        right: String(localized: "the server listens"),
                        rightPort: "8080",
                        tint: DesignTokens.Color.warning,
                        reversed: true,
                        step: 2
                    )
                }
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "lock.fill")
                Text("Inside the SSH connection — nothing new is exposed")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DesignTokens.Color.success)
            .multilineTextAlignment(.center)
            .modifier(entrance(4))
        }
    }

    private func forwardingRow(
        kind: String,
        left: String,
        leftPort: String,
        right: String,
        rightPort: String,
        tint: Color,
        reversed: Bool,
        step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(kind)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            HStack(spacing: DesignTokens.Spacing.sm) {
                endpoint(left, leftPort, tint)
                Image(systemName: reversed ? "arrow.left" : "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                endpoint(right, rightPort, DesignTokens.Color.labelSecondary)
            }
        }
        .modifier(entrance(step))
    }

    private func endpoint(_ label: String, _ port: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: port)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.Color.label)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
