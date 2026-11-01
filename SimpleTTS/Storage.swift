import Foundation

/// セーブデータの読み書きで発生するエラー
nonisolated enum StorageError: LocalizedError {
    /// `saves.json` を読み込めなかった（I/O エラーまたは解析エラー）。
    /// `backupURL` は退避先。退避にも失敗した場合は nil で、その場合はセーブの書き込みを停止している。
    case savesUnreadable(underlying: Error, backupURL: URL?)
    /// 読めなかった `saves.json` を退避できなかったため、上書きを防ぐために書き込みを停止している。
    case writeBlocked

    var errorDescription: String? {
        switch self {
        case let .savesUnreadable(underlying, _):
            return underlying.localizedDescription
        case .writeBlocked:
            return "読み込めなかったセーブデータを保護するため、セーブの書き込みを停止しています。"
        }
    }
}

/// セーブデータと本文キャッシュを Application Support（サンドボックスではアプリのコンテナ）に保存する。
///
/// 本文はセーブした位置から再開できるよう `Documents/<SHA-256>.txt` にコピーしておく。
/// これにより、元ファイルへのアクセス権（セキュリティスコープ付きブックマーク）がなくても再開できる。
final class Storage {
    private static let corruptedPrefix = "saves.corrupted-"

    private let baseURL: URL

    /// 読み込めなかった `saves.json` を退避できなかったとき true。
    /// 元のファイルを `.atomic` 書き込みで上書きしてしまわないよう、`writeSaves` を拒否する。
    private(set) var isWriteBlocked = false

    private var documentsURL: URL { baseURL.appending(path: "Documents", directoryHint: .isDirectory) }
    private var savesURL: URL { baseURL.appending(path: "saves.json", directoryHint: .notDirectory) }

    init() {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        baseURL = appSupport.appending(path: "SimpleTTS", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    }

    // MARK: - Saves

    /// セーブ一覧を読み込む。
    ///
    /// ファイルが存在しない場合だけ空配列を返す。読み込み・解析に失敗した場合は元のファイルを
    /// `saves.corrupted-*.json` に退避して `StorageError.savesUnreadable` を投げる。
    /// 退避にも失敗した場合は、以降の `writeSaves` を拒否する。
    func loadSaves() throws -> [SavePoint] {
        let data: Data
        do {
            data = try Data(contentsOf: savesURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw quarantineUnreadableSaves(underlying: error)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([SavePoint].self, from: data)
        } catch {
            throw quarantineUnreadableSaves(underlying: error)
        }
    }

    func writeSaves(_ saves: [SavePoint]) throws {
        guard !isWriteBlocked else { throw StorageError.writeBlocked }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saves)
        try data.write(to: savesURL, options: .atomic)
    }

    /// 読み込めなかった `saves.json` を退避する。退避できなければ書き込みを停止する。
    private func quarantineUnreadableSaves(underlying: Error) -> StorageError {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let backup = baseURL.appending(
            path: "\(Self.corruptedPrefix)\(stamp)-\(suffix).json",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.moveItem(at: savesURL, to: backup)
            return .savesUnreadable(underlying: underlying, backupURL: backup)
        } catch {
            isWriteBlocked = true
            return .savesUnreadable(underlying: underlying, backupURL: nil)
        }
    }

    /// 退避済みの（読み込めなかった）セーブデータが残っているか。
    /// 中身を確認できないため、残っている間はどの本文が参照されているか分からない。
    private var hasQuarantinedSaves: Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else {
            // 確認できない場合も安全側（退避ファイルがあるもの）として扱う
            return true
        }
        return files.contains {
            $0.lastPathComponent.hasPrefix(Self.corruptedPrefix) && $0.pathExtension == "json"
        }
    }

    // MARK: - Document text cache

    func storeDocumentText(_ text: String, id: String) throws {
        let url = documentURL(id: id)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func loadDocumentText(id: String) -> String? {
        guard let data = try? Data(contentsOf: documentURL(id: id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// どのセーブからも参照されていない本文キャッシュを削除する。
    ///
    /// 書き込みを停止している間や、退避したセーブデータが残っている間は何も削除しない
    /// （退避ファイルだけが参照している本文を失わないため）。
    func removeDocuments(notReferencedBy ids: Set<String>) {
        guard !isWriteBlocked, !hasQuarantinedSaves else { return }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "txt" {
            let id = file.deletingPathExtension().lastPathComponent
            if !ids.contains(id) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func documentURL(id: String) -> URL {
        documentsURL.appending(path: "\(id).txt", directoryHint: .notDirectory)
    }
}
