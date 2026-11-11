import SwiftUI

/// 検索欄に入力した語を含む文の一覧。サイドバーにセーブ一覧の代わりに表示する。
/// 行を選ぶと、その文へ移動する（読み上げ中ならその文から読み直す）。
struct SearchResultsList: View {
    let model: ReaderModel
    /// 検索結果の文へ移動したあとに呼ばれる（iPhone で読み上げ画面に戻るため）
    var onSelect: () -> Void = {}

    var body: some View {
        if model.document == nil {
            ContentUnavailableView {
                Label("No Document Open", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Open a text file to search its sentences.")
            }
        } else if model.isSearchPending {
            ProgressView()
                .accessibilityLabel(Text("Search Sentences"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: SentenceSearch.normalizedQuery(model.searchQuery) ?? "")
        } else {
            List(selection: selection) {
                Section {
                    ForEach(model.searchResults) { result in
                        SearchResultRow(result: result, query: model.searchQuery)
                            .tag(result.sentenceIndex)
                            .contextMenu {
                                Button("Go to Sentence") { select(result) }
                            }
                    }
                } header: {
                    summary
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// 一致した文の数。上限を超えたときは、表示している件数も示す。
    @ViewBuilder
    private var summary: some View {
        if model.searchMatchCount > model.searchResults.count {
            Text("Showing first \(model.searchResults.count) of \(model.searchMatchCount) matches")
        } else {
            Text("\(model.searchMatchCount) matching sentences")
        }
    }

    /// 現在の文が検索結果にあれば、その行を選択中として表示する。
    /// 行を選ぶと（クリック・タップ・↑／↓）、その文へ移動する。
    private var selection: Binding<Int?> {
        Binding(
            get: {
                let current = model.currentIndex
                return model.searchResults.contains { $0.sentenceIndex == current } ? current : nil
            },
            set: { index in
                guard let index, let result = model.searchResults.first(where: { $0.sentenceIndex == index }) else { return }
                select(result)
            }
        )
    }

    private func select(_ result: SentenceSearchResult) {
        if result.sentenceIndex != model.currentIndex {
            model.goToSearchResult(result)
        }
        // 検索欄に入力中のまま行をクリックしても、続けて Space・←／→ で読み上げを操作できるよう検索欄から抜ける
        model.isSearchFieldFocused = false
        onSelect()
    }
}

/// 検索結果の 1 行。文番号と、検索語を強調した文を表示する。
private struct SearchResultRow: View {
    let result: SentenceSearchResult
    let query: String

    /// 一致した箇所が文の後ろのほうにあるとき、その前をこの文字数だけ残して省略する
    private static let leadingContext = 20
    /// 一致した箇所がこの文字数より後ろにあるときだけ、文の先頭を省略する
    private static let maxLeadingCharacters = 40
    /// 一致した箇所の背景色
    private static let matchHighlight = Color.yellow.opacity(0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sentence \(result.sentenceIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(highlightedExcerpt)
                .font(.callout)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .help(result.sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sentence \(result.sentenceIndex + 1)")
        .accessibilityValue(result.sentence)
    }

    /// 一致した箇所が見えるよう、必要なら文の先頭を「…」で省略し、一致した箇所を強調する。
    private var highlightedExcerpt: AttributedString {
        var excerpt = result.sentence
        var isTruncated = false
        if let first = SentenceSearch.matchRanges(of: query, in: excerpt).first,
           excerpt.distance(from: excerpt.startIndex, to: first.lowerBound) > Self.maxLeadingCharacters {
            let start = excerpt.index(first.lowerBound, offsetBy: -Self.leadingContext)
            excerpt = String(excerpt[start...])
            isTruncated = true
        }

        var attributed = AttributedString(excerpt)
        for range in SentenceSearch.matchRanges(of: query, in: excerpt) {
            if let attributedRange = Range(range, in: attributed) {
                // 和文は太字だけでは目立たないため、検索の強調表示と同じく黄色の背景も付ける
                attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                attributed[attributedRange].backgroundColor = Self.matchHighlight
            }
        }
        return isTruncated ? AttributedString("…") + attributed : attributed
    }
}
