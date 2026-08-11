import AppKit
import SwiftUI

struct TagPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(color.opacity(0.11), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(DevFlowTheme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(DevFlowTheme.surface(colorScheme).opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DevFlowTheme.border(colorScheme)))
    }
}

struct CardActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DevFlowTheme.accent)
            .padding(.horizontal, 13)
            .frame(height: 33)
            .background(DevFlowTheme.accent.opacity(configuration.isPressed ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DevFlowTheme.accent.opacity(0.25)))
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.45)
    }
}

struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

struct PathDropTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isDropTargeted: Bool

    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FilePathDropContainerView {
        let containerView = FilePathDropContainerView()
        containerView.registerForDraggedTypes(FilePathDropContainerView.supportedDragTypes)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = FilePathTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 13)
        textView.textContainer?.widthTracksTextView = true

        let receivePaths: ([String]) -> Void = { paths in
            context.coordinator.append(paths: paths)
        }
        let updateDropTarget: (Bool) -> Void = { isTargeted in
            context.coordinator.parent.isDropTargeted = isTargeted
        }
        containerView.onDropPaths = receivePaths
        containerView.onDropTargetChange = updateDropTarget
        textView.setAccessibilityLabel("辅助 AI 定位")

        scrollView.documentView = textView
        containerView.install(scrollView: scrollView)
        context.coordinator.textView = textView
        return containerView
    }

    func updateNSView(_ containerView: FilePathDropContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PathDropTextEditor
        fileprivate weak var textView: FilePathTextView?

        init(parent: PathDropTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func append(paths: [String]) {
            let validPaths = paths.filter { !$0.isEmpty }
            guard !validPaths.isEmpty else { return }
            let appended = validPaths.joined(separator: "\n")
            let updatedText = parent.text.isEmpty ? appended : "\(parent.text)\n\(appended)"
            textView?.string = updatedText
            textView?.needsDisplay = true
            parent.text = updatedText
        }
    }
}

fileprivate final class FilePathTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let textContainer else { return }
        let origin = NSPoint(
            x: textContainerOrigin.x + textContainer.lineFragmentPadding,
            y: textContainerOrigin.y
        )
        let availableWidth = textContainer.size.width - textContainer.lineFragmentPadding * 2
        let rect = NSRect(
            origin: origin,
            size: NSSize(width: availableWidth, height: bounds.height - origin.y)
        )
        placeholder.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font ?? .systemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72)
            ]
        )
    }

}

final class FilePathDropContainerView: NSView {
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let supportedDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, legacyFilenamesType]

    var onDropPaths: (([String]) -> Void)?
    var onDropTargetChange: ((Bool) -> Void)?

    func install(scrollView: NSScrollView) {
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let isTargeted = Self.supportsPaths(in: sender.draggingPasteboard)
        onDropTargetChange?(isTargeted)
        return isTargeted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let isTargeted = Self.supportsPaths(in: sender.draggingPasteboard)
        onDropTargetChange?(isTargeted)
        return isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.supportsPaths(in: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.paths(from: sender.draggingPasteboard)
        onDropTargetChange?(false)
        guard !paths.isEmpty else { return false }
        onDropPaths?(paths)
        return true
    }

    static func supportsPaths(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: supportedDragTypes) != nil
    }

    static func paths(from pasteboard: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        if !fileURLs.isEmpty {
            return fileURLs.compactMap { url in
                guard let path = url.path, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
        }

        let legacyPaths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] ?? []
        return legacyPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}
