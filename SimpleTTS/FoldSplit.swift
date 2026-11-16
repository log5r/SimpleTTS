import CoreGraphics

/// 折りたためる iPhone（iPhone Duo）の内側の画面で、折り目を避けて読み上げ画面を 2 つに分けるための寸法。
///
/// 折り目の位置は、システムが「内容を 2 つに分けるべき領域」（`ReservedRegion.Kind.division`）として知らせる。
/// その領域が読み上げ画面を横切り、両側に十分な広さが残るときだけ分割する。
/// 折り目がない画面（外側の画面、ほかの iPhone、iPad、macOS）では作られず、従来のレイアウトのままになる。
nonisolated struct FoldSplit: Equatable {
    /// 2 つの区画の並べ方
    enum Axis: Equatable {
        /// 折り目が縦に走り、区画を左右に並べる
        case horizontal
        /// 折り目が横に走り、区画を上下に並べる
        case vertical
    }

    /// 分割するときに、それぞれの区画に必要な最小の長さ（並べる方向の長さ）。
    /// 読み上げ画面のいちばん狭いレイアウト（`ReaderWidthClass.minimal`）の操作列がおよそ 320pt なので、それより少し広くする。
    static let minimumPaneLength: CGFloat = 340

    let axis: Axis
    /// 先頭側（左右なら leading、上下なら上）の区画
    let first: CGRect
    /// 折り目そのものの区画（何も置かない）
    let gap: CGRect
    /// 末尾側（左右なら trailing、上下なら下）の区画
    let second: CGRect

    /// - Parameters:
    ///   - size: 読み上げ画面の大きさ
    ///   - divisions: 分割すべき領域（読み上げ画面の座標）。読み上げ画面を横切らない領域は無視する。
    ///   - minimumPaneLength: 区画に必要な最小の長さ。どちらかがこれより短くなるなら分割しない。
    init?(size: CGSize, divisions: [CGRect], minimumPaneLength: CGFloat = Self.minimumPaneLength) {
        let bounds = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0 else { return nil }

        for division in divisions {
            // 折り目は幅 0 の線として届くこともあるので、空の矩形も捨てない
            let region = division.standardized.intersection(bounds)
            guard !region.isNull else { continue }

            // 細長い向きで折り目の向きを決める（縦に長ければ縦の折り目）
            let isVerticalFold = region.height / size.height >= region.width / size.width
            if isVerticalFold {
                // 上端から下端まで横切っていなければ、区画を分けても折り目をまたぐ内容が残る
                guard region.minY <= bounds.minY, region.maxY >= bounds.maxY else { continue }
                let first = CGRect(x: 0, y: 0, width: region.minX, height: size.height)
                let second = CGRect(x: region.maxX, y: 0, width: size.width - region.maxX, height: size.height)
                guard first.width >= minimumPaneLength, second.width >= minimumPaneLength else { continue }
                self.axis = .horizontal
                self.first = first
                self.gap = CGRect(x: region.minX, y: 0, width: region.width, height: size.height)
                self.second = second
            } else {
                guard region.minX <= bounds.minX, region.maxX >= bounds.maxX else { continue }
                // 上下分割でも操作列の幅が必要。高さだけでは、狭い詳細カラムも分割してしまう。
                guard size.width >= minimumPaneLength else { continue }
                let first = CGRect(x: 0, y: 0, width: size.width, height: region.minY)
                let second = CGRect(x: 0, y: region.maxY, width: size.width, height: size.height - region.maxY)
                guard first.height >= minimumPaneLength, second.height >= minimumPaneLength else { continue }
                self.axis = .vertical
                self.first = first
                self.gap = CGRect(x: 0, y: region.minY, width: size.width, height: region.height)
                self.second = second
            }
            return
        }
        return nil
    }
}

/// ヒンジが「動いた」とみなすかどうかの判定（iPhone Duo）。
///
/// 開閉の途中では、ヒンジの開き具合の段階（`DeviceHinge.Status`）が変わる前から折り目の位置が少しずつ動く。
/// 読み上げ画面は、動いている間は位置スライダーへの入力を受け付けない（`ReaderView` を参照）。
/// 開き具合の段階が変わったとき、または前回動いたとみなしたときから角度が `angleThreshold` 以上変わったときに
/// 動いたとみなし、手に持ったときの角度のわずかな揺れでは動いたとみなさない。
nonisolated enum HingeMotion {
    /// これ未満の角度の変化は、手に持ったときの揺れとして無視する（度）。
    /// iPhone Duo シミュレータで開閉したときは、1 回の通知でおよそ 7 度ずつ変わった。
    static let angleThreshold: Double = 1

    /// ある時点のヒンジ。ヒンジがない（または情報がない）ときは、どちらも nil。
    struct Snapshot: Equatable {
        /// 開き具合の段階（`DeviceHinge.Status`。iOS 27.1 より前の SDK でも扱えるよう型を消している）
        var status: AnyHashable?
        /// 開き具合の角度（度）
        var degrees: Double?
    }

    /// - Parameters:
    ///   - reference: 前回動いたとみなしたときのヒンジ。まだなければ nil（最初の通知は動いたとみなす）。
    ///   - current: 今のヒンジ
    static func hasMoved(from reference: Snapshot?, to current: Snapshot) -> Bool {
        guard let reference else { return true }
        if reference.status != current.status { return true }
        switch (reference.degrees, current.degrees) {
        case let (old?, new?):
            return abs(new - old) >= angleThreshold
        case (nil, nil):
            return false
        default:
            // 角度の情報の有無が変わった
            return true
        }
    }
}
