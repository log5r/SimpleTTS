import Darwin
import Foundation
import UniformTypeIdentifiers

nonisolated enum TextFileError: LocalizedError, Equatable {
    case localFileRequired
    case regularFileRequired
    case fileTooLarge
    case unsupportedFileType
    case invalidText

    var errorDescription: String? {
        switch self {
        case .localFileRequired:
            return String(localized: "Choose a text file on your device. Web URLs cannot be opened.")
        case .regularFileRequired:
            return String(localized: "Choose a regular text file. Folders and links cannot be opened.")
        case .fileTooLarge:
            return String(localized: "Choose a text file no larger than 10 MiB.")
        case .unsupportedFileType:
            return String(localized: "Choose a plain text file.")
        case .invalidText:
            return String(localized: "This file could not be read as text.")
        }
    }
}

/// ファイル選択とドロップの両方で使う。同期 I/O のため、呼び出し側でメインスレッドから離して実行する。
nonisolated enum TextFileLoader {
    static let maximumByteCount = 10 * 1_024 * 1_024

    static func read(from url: URL) throws -> String {
        // セキュリティスコープやファイル API に渡す前に、ネットワーク URL を拒否する。
        guard url.isFileURL else { throw TextFileError.localFileRequired }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        if !url.pathExtension.isEmpty {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .plainText) else {
                throw TextFileError.unsupportedFileType
            }
        }

        // パスの事前検査だけでは、検査後に FIFO などへ置き換えられる可能性がある。
        // 非ブロッキングで開き、実際に開いたファイルの種類を検査する。シンボリックリンクも追わない。
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw TextFileError.regularFileRequired }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw TextFileError.regularFileRequired }
        guard metadata.st_size <= maximumByteCount else { throw TextFileError.fileTooLarge }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            // 読み込み中にファイルが大きくなっても、上限を超える 1 byte で検出して打ち切る。
            let count = min(buffer.count, maximumByteCount - data.count + 1)
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!, count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count + bytesRead <= maximumByteCount else { throw TextFileError.fileTooLarge }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }

        guard let decoded = TextDecoding.decode(data) else { throw TextFileError.invalidText }
        // 他のツールが出力したテキストには、プレースホルダーの区切りなどとして NUL が紛れ込むことがある。
        // NUL は表示も読み上げもしないので取り除く。バイナリファイルは NUL 以外の制御文字も含むため、下の検査で拒否される。
        let text = removingNUL(from: decoded)
        guard !text.unicodeScalars.contains(where: isBinaryControl) else {
            throw TextFileError.invalidText
        }
        return text
    }

    private static func removingNUL(from text: String) -> String {
        guard text.unicodeScalars.contains("\0") else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { $0 != "\0" })
        return String(scalars)
    }

    private static func isBinaryControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...8, 11, 14...31, 127...159: true
        default: false
        }
    }
}
