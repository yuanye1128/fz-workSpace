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
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(
                DevFlowTheme.surface(colorScheme),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hoverFillOpacity))
                    .allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(DevFlowTheme.border(colorScheme))
            )
            .overlay {
                NativeHoverReader(isHovered: $isHovered)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var hoverFillOpacity: Double {
        if configuration.isPressed { return 0.14 }
        if isHovered { return 0.08 }
        return 0
    }
}

struct CardActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardActionButtonBody(configuration: configuration)
    }
}

private struct CardActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DevFlowTheme.accent)
            .padding(.horizontal, 13)
            .frame(height: 33)
            .background(
                DevFlowTheme.accent.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.10 : 0.05)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DevFlowTheme.accent.opacity(isHovered || configuration.isPressed ? 0.4 : 0.25)))
            .overlay {
                NativeHoverReader(isHovered: $isHovered)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// AppKit 级悬停探测，避免 SwiftUI Button/Menu 吞掉 onHover。
struct NativeHoverReader: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> NativeHoverView {
        let view = NativeHoverView()
        view.onHoverChange = { hovering in
            DispatchQueue.main.async {
                if isHovered != hovering {
                    isHovered = hovering
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NativeHoverView, context: Context) {
        nsView.onHoverChange = { hovering in
            DispatchQueue.main.async {
                if isHovered != hovering {
                    isHovered = hovering
                }
            }
        }
    }
}

final class NativeHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard bounds.width > 0, bounds.height > 0 else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

/// 系统风格悬停浅底，用于侧栏项、工单号等 plain 按钮。
struct HoverHighlightModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var isActive: Bool = false
    var activeFill: Color = .clear
    var hoverOpacity: Double = 0.08

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                NativeHoverReader(isHovered: $isHovered)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fillColor: Color {
        if isActive { return activeFill }
        if isHovered { return Color.primary.opacity(hoverOpacity) }
        return .clear
    }
}

extension View {
    func hoverHighlight(
        isActive: Bool = false,
        activeFill: Color = .clear,
        cornerRadius: CGFloat = 8,
        hoverOpacity: Double = 0.08
    ) -> some View {
        modifier(
            HoverHighlightModifier(
                cornerRadius: cornerRadius,
                isActive: isActive,
                activeFill: activeFill,
                hoverOpacity: hoverOpacity
            )
        )
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
