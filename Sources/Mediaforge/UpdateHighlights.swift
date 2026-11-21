#if MEDIAFORGE_DIRECT_DISTRIBUTION
import AppKit
import Sparkle

enum UpdateHighlights {
    static func releaseNotes(
        replacing fallback: NSAttributedString,
        for item: SUAppcastItem,
        installedBuild: String
    ) -> NSAttributedString? {
        guard let history = item.propertiesDictionary["soundbrenner:releaseHighlights"] as? String,
              let highlights = bullets(in: history, after: installedBuild, through: item.versionString) else {
            return nil
        }
        let font = fallback.length > 0 ? fallback.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        paragraph.paragraphSpacing = 5
        return NSAttributedString(
            string: highlights.map { "•\t\($0)" }.joined(separator: "\n"),
            attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: paragraph]
        )
    }

    static func bullets(in history: String, after installedBuild: String, through offeredBuild: String) -> [String]? {
        guard let installed = Int(installedBuild), let offered = Int(offeredBuild),
              let releases = try? JSONDecoder().decode([String: [String]].self, from: Data(history.utf8)),
              releases[offeredBuild]?.isEmpty == false else { return nil }

        let builds = releases.keys.compactMap { key -> Int? in
            guard let build = Int(key), String(build) == key, build > installed, build <= offered else { return nil }
            return build
        }.sorted(by: >)
        var seen = Set<String>()
        let highlights = builds.flatMap { releases[String($0)] ?? [] }.filter { seen.insert($0).inserted }
        return highlights.isEmpty ? nil : Array(highlights.prefix(5))
    }
}
#endif
