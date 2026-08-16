import AppKit
import SwiftUI

struct RecapChatComposer: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = RecapChatTextView()
        editor.delegate = context.coordinator
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 9, height: 7)
        editor.setAccessibilityLabel(L10n.string(
            "accessibility.ask_local_period",
            fallback: "Ask about this local period"))
        if let container = editor.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude)
        }
        editor.string = text
        editor.onSubmit = onSubmit
        editor.canSubmit = isEnabled
        editor.isEditable = isEnabled

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = editor
        context.coordinator.editor = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = context.coordinator.editor else { return }
        editor.onSubmit = onSubmit
        editor.canSubmit = isEnabled
        editor.isEditable = isEnabled
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(
                location: (text as NSString).length,
                length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RecapChatComposer
        weak var editor: RecapChatTextView?

        init(parent: RecapChatComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
        }
    }
}

@MainActor
final class RecapChatTextView: NSTextView {
    enum ReturnKeyAction: Equatable {
        case submit
        case insertNewline
        case passThrough
    }

    var onSubmit: ((String) -> Void)?
    var canSubmit = true

    override func keyDown(with event: NSEvent) {
        switch Self.returnKeyAction(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            hasMarkedText: hasMarkedText()) {
        case .submit:
            guard canSubmit else { return }
            onSubmit?(string)
        case .insertNewline:
            insertNewline(nil)
        case .passThrough:
            super.keyDown(with: event)
        }
    }

    static func returnKeyAction(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> ReturnKeyAction {
        guard keyCode == 36 || keyCode == 76, !hasMarkedText else {
            return .passThrough
        }

        var modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .numericPad, .function])
        if modifiers.contains(.control) || modifiers.contains(.command) {
            return .passThrough
        }
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            return .insertNewline
        }
        return modifiers.isEmpty ? .submit : .passThrough
    }
}
