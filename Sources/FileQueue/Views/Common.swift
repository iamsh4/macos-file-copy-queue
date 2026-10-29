import SwiftUI
import UniformTypeIdentifiers

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func rate(_ bps: Double) -> String { bytes(Int64(bps)) + "/s" }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()

    static func duration(_ t: TimeInterval) -> String {
        durationFormatter.string(from: max(1, t.rounded())) ?? ""
    }

    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

extension TransferOperation {
    var tint: Color { self == .copy ? .blue : .orange }
}

/// Shows a type-based icon instantly, then the real Finder icon loaded off the main thread
/// (asking for icons on a sleeping NAS can otherwise stall the UI).
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 32

    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? placeholder)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .task(id: url) {
                let path = url.path
                let icon = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    return NSWorkspace.shared.icon(forFile: path)
                }.value
                if let icon { image = icon }
            }
    }

    private var placeholder: NSImage {
        let ext = url.pathExtension
        if ext.isEmpty || url.hasDirectoryPath {
            return NSWorkspace.shared.icon(for: ext.isEmpty ? .folder : (UTType(filenameExtension: ext) ?? .folder))
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

struct OperationBadge: View {
    let operation: TransferOperation

    var body: some View {
        Text(operation.title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(operation.tint)
            .background(operation.tint.opacity(0.14), in: Capsule())
    }
}

func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
    await withTaskGroup(of: (Int, URL?).self) { group in
        for (i, provider) in providers.enumerated() {
            group.addTask {
                await withCheckedContinuation { cont in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: (i, url)) }
                }
            }
        }
        var result = [URL?](repeating: nil, count: providers.count)
        for await (i, url) in group { result[i] = url }
        return result.compactMap { $0 }
    }
}
