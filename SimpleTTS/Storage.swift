import Foundation

/// セーブデータの読み書きで発生するエラー
nonisolated enum StorageError: LocalizedError {
    /// `saves.json` を読み込めなかった（I/O エラーまたは解析エラー）。
    /// `backupURL` は退避先。退避にも失敗した場合は nil で、その場合はセーブの書き込みを停止している。
    case savesUnreadable(underlying: Error, backupURL: URL?)
    /// 読めなかった `saves.json` を退避できなかったため、上書きを防ぐために書き込みを停止している。
    case writeBlocked
    case invalidDocumentID
    case unsafeStorageDirectory

    var errorDescription: String? {
        switch self {
        case let .savesUnreadable(underlying, _):
            return underlying.localizedDescription
        case .writeBlocked:
            return "読み込めなかったセーブデータを保護するため、セーブの書き込みを停止しています。"
        case .invalidDocumentID:
            return "文書の識別子が不正です。"
        case .unsafeStorageDirectory:
            return "保存先にリンクまたは通常のフォルダではない項目があるため、保存できません。"
        }
    }
}

/// セーブデータと本文キャッシュを Application Support（サンドボックスではアプリのコンテナ）に保存する。
///
/// 本文はセーブした位置から再開できるよう `Documents/<SHA-256>.txt` にコピーしておく。
/// これにより、元ファイルへのアクセス権（セキュリティスコープ付きブックマーク）がなくても再開できる。
final class Storage {
    private static let corruptedPrefix = "saves.corrupted-"

    private let location: Result<URL, Error>

    private var baseURL: URL { get throws { try location.get() } }

    /// 読み込めなかった `saves.json` を退避できなかったとき true。
    /// 元のファイルを `.atomic` 書き込みで上書きしてしまわないよう、`writeSaves` を拒否する。
    private(set) var isWriteBlocked = false

    private var documentsURL: URL { get throws { try baseURL.appending(path: "Documents", directoryHint: .isDirectory) } }
    private var savesURL: URL { get throws { try baseURL.appending(path: "saves.json", directoryHint: .notDirectory) } }

    /// `baseURL` はテストで隔離した保存先を指定するために使う。
    /// 作成とバックアップ除外は最初の読み書きで行い、失敗を呼び出し側へ返す。
    init(baseURL: URL? = nil) {
        location = Result {
            if let baseURL { return baseURL }
            return try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appending(path: "SimpleTTS", directoryHint: .isDirectory)
        }
    }

    private func prepareDirectories() throws {
        let fileManager = FileManager.default
        for directory in [try baseURL, try documentsURL] {
            if fileManager.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw StorageError.unsafeStorageDirectory
                }
            } else {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // 旧バージョンの保存済み本文にも、親フォルダの除外を適用する。
            try excludeFromBackup(directory)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    // MARK: - Saves

    /// セーブ一覧を読み込む。
    ///
    /// ファイルが存在しない場合だけ空配列を返す。読み込み・解析に失敗した場合は元のファイルを
    /// `saves.corrupted-*.json` に退避して `StorageError.savesUnreadable` を投げる。
    /// 退避にも失敗した場合は、以降の `writeSaves` を拒否する。
    func loadSaves() throws -> [SavePoint] {
        try prepareDirectories()
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
            let saves = try decoder.decode([SavePoint].self, from: data)
            guard saves.allSatisfy({ Self.isValidDocumentID($0.documentID) }) else {
                throw StorageError.invalidDocumentID
            }
            return saves
        } catch {
            throw quarantineUnreadableSaves(underlying: error)
        }
    }

    func writeSaves(_ saves: [SavePoint]) throws {
        guard !isWriteBlocked else { throw StorageError.writeBlocked }
        guard saves.allSatisfy({ Self.isValidDocumentID($0.documentID) }) else {
            throw StorageError.invalidDocumentID
        }
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saves)
        try data.write(to: savesURL, options: .atomic)
        try excludeFromBackup(savesURL)
    }

    /// 読み込めなかった `saves.json` を退避する。退避できなければ書き込みを停止する。
    private func quarantineUnreadableSaves(underlying: Error) -> StorageError {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        do {
            let backup = try baseURL.appending(
                path: "\(Self.corruptedPrefix)\(stamp)-\(suffix).json",
                directoryHint: .notDirectory
            )
            // 移動先の親も除外済み。失敗時は元の履歴を上書きしない。
            try prepareDirectories()
            try excludeFromBackup(savesURL)
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
        let url = try documentURL(id: id)
        try prepareDirectories()
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try excludeFromBackup(url)
            return
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        try excludeFromBackup(url)
    }

    func loadDocumentText(id: String) -> String? {
        guard (try? prepareDirectories()) != nil,
              let data = try? Data(contentsOf: documentURL(id: id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// どのセーブからも参照されていない本文キャッシュを削除する。
    ///
    /// 書き込みを停止している間や、退避したセーブデータが残っている間は何も削除しない
    /// （退避ファイルだけが参照している本文を失わないため）。
    func removeDocuments(notReferencedBy ids: Set<String>) {
        guard !isWriteBlocked, !hasQuarantinedSaves else { return }
        guard (try? prepareDirectories()) != nil else { return }
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

    /// 利用者が明示的に全削除した場合は、復旧用の退避ファイルも含めて消す。
    /// この処理を呼ぶ前に、呼び出し側で現在の文書を閉じ、自動保存を止めること。
    func removeAllData() throws {
        let url = try baseURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: url)
        }
        isWriteBlocked = false
        try prepareDirectories()
    }

    private func documentURL(id: String) throws -> URL {
        guard Self.isValidDocumentID(id) else { throw StorageError.invalidDocumentID }
        return try documentsURL.appending(path: "\(id).txt", directoryHint: .notDirectory)
    }

    private static func isValidDocumentID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
