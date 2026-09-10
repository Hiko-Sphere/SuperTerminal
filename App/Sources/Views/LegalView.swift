import SwiftUI

/// One legal document, rendered from its bundled Markdown.
struct LegalView: View {
    let document: LegalDocument
    @State private var parsed: MarkdownDocument?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let parsed {
                MarkdownDocumentView(document: parsed)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.vertical, DesignTokens.Spacing.md)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            } else if let loadError {
                ContentUnavailableView(loadError, systemImage: "doc.questionmark")
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal-\(document.rawValue)")
        .task(id: document) {
            do {
                parsed = MarkdownDocument(try document.markdown())
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

/// Renders parsed Markdown with the app's typography. Tables become one card per row
/// on any width: four columns of prose do not fit a phone, and a card that names each
/// column is easier to read than a squeezed grid on an iPad too.
struct MarkdownDocumentView: View {
    let document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(level <= 1 ? DesignTokens.Typography.title : level == 2 ? DesignTokens.Typography.headline : DesignTokens.Typography.body.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.label)
                .padding(.top, level <= 2 ? DesignTokens.Spacing.md : DesignTokens.Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(inline(text))
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.label)
        case let .bullets(items):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        Text(verbatim: "•").foregroundStyle(DesignTokens.Color.labelSecondary)
                        Text(inline(item)).font(DesignTokens.Typography.body)
                    }
                }
            }
        case let .numbered(items):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        Text(verbatim: "\(index + 1).")
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            .monospacedDigit()
                        Text(inline(item)).font(DesignTokens.Typography.body)
                    }
                }
            }
        case let .table(header, rows):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        if let first = row.first {
                            Text(inline(first))
                                .font(DesignTokens.Typography.body.weight(.semibold))
                        }
                        ForEach(Array(zip(header.dropFirst(), row.dropFirst()).enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inline(pair.0))
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                                Text(inline(pair.1))
                                    .font(DesignTokens.Typography.callout)
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                }
            }
        case .rule:
            Divider()
        case let .illustration(name):
            // A name nothing answers to draws nothing rather than a placeholder: the legal
            // texts share this renderer and will never carry one, and a broken-image box in
            // the terms would be worse than a picture that is quietly absent. What keeps the
            // guide honest is a test over every marker in every language, not a box here.
            if let kind = TutorialPage.Illustration(rawValue: name) {
                GuideIllustration(kind: kind)
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
