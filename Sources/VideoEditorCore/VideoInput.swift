import Foundation
import UniformTypeIdentifiers

public enum VideoInput {
    public static func paths(from text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
                path.removeFirst()
                path.removeLast()
            }
            if let url = URL(string: path), url.isFileURL { return url }
            path = (path as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    public static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true else { return false }
        return values.contentType?.conforms(to: .movie) == true
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
}
