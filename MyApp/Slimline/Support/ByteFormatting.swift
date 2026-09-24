import Foundation

/// Byte-count formatting used everywhere a size is shown.
///
/// Uses the `.file` style deliberately: it matches the decimal (1 GB = 1000 MB) convention that
/// Settings › General › iPhone Storage uses, so our numbers don't visibly disagree with the
/// figure the user is trying to improve.
enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        // ByteCountFormatter spells zero as "Zero KB", which reads oddly in a total.
        guard bytes > 0 else { return "0 KB" }
        return bytes.formatted(.byteCount(style: .file))
    }

    /// A compact form for tight spots like grid badges, where the text must not wrap.
    static func compact(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return bytes.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb]))
    }
}
