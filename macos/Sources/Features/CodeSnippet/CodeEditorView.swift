import SwiftUI
import AppKit

/// 基于 NSTextView 的简单代码编辑器，支持 Shell / Python 基础语法高亮。
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeSnippetType

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.string = text

        // 让文本视图随滚动视图宽度自动换行，并支持纵向滚动。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        context.coordinator.language = language
        context.coordinator.applyHighlight(textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        guard !context.coordinator.isUpdating else { return }

        // 当用户正在编辑时，不要从 SwiftUI 回写字符串，避免光标跳动或文字被覆盖。
        if !textView.isFirstResponder, textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.applyHighlight(textView)
            context.coordinator.isUpdating = false
        }

        if context.coordinator.language != language {
            context.coordinator.language = language
            context.coordinator.applyHighlight(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CodeEditorView
        var language: CodeSnippetType = .shell
        var isUpdating = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // 仅在字符内容发生变化时更新绑定，避免属性高亮触发不必要的 SwiftUI 重绘。
            guard editedMask.contains(.editedCharacters) else { return }
            guard !isUpdating else { return }
            parent.text = textStorage.string
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applyHighlight(textView)
        }

        func applyHighlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)

            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            storage.addAttribute(.font, value: font, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

            let text = storage.string
            switch language {
            case .shell: highlightShell(text, storage)
            case .python: highlightPython(text, storage)
            }
        }

        private func highlightShell(_ text: String, _ storage: NSTextStorage) {
            let pattern = """
            (#.*)|("(?:[^"\\\\]|\\\\.)*")|('[^']*')|\\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|echo|printf|export|source|\\.|cd|pwd|mkdir|rmdir|rm|cp|mv|cat|grep|awk|sed|chmod|chown|sudo|python|python3|bash|sh|zsh)\\b|(\\b\\d+\\b)
            """
            applyRegex(pattern, to: text, storage: storage, colors: [
                1: NSColor.systemGray,
                2: NSColor.systemGreen,
                3: NSColor.systemGreen,
                4: NSColor.systemPink,
                5: NSColor.systemOrange,
            ])
        }

        private func highlightPython(_ text: String, _ storage: NSTextStorage) {
            let pattern = """
            (#.*)|(\\\"\\\"\\\"[\\s\\S]*?\\\"\\\"\\\")|('''[\\s\\S]*?''')|("(?:[^"\\\\]|\\\\.)*")|('(?:[^'\\\\]|\\\\.)*')|(@\\w+)\\b|\\b(def|class|if|else|elif|for|while|return|import|from|as|try|except|finally|with|lambda|pass|break|continue|raise|yield|True|False|None|and|or|not|in|is|global|nonlocal|assert|del)\\b|(\\b\\d+\\b)
            """
            applyRegex(pattern, to: text, storage: storage, colors: [
                1: NSColor.systemGray,
                2: NSColor.systemGreen,
                3: NSColor.systemGreen,
                4: NSColor.systemGreen,
                5: NSColor.systemGreen,
                6: NSColor.systemPurple,
                7: NSColor.systemPink,
                8: NSColor.systemOrange,
            ])
        }

        private func applyRegex(
            _ pattern: String,
            to text: String,
            storage: NSTextStorage,
            colors: [Int: NSColor]
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                for (group, color) in colors {
                    let groupRange = match.range(at: group)
                    if groupRange.location != NSNotFound && groupRange.length > 0 {
                        storage.addAttribute(.foregroundColor, value: color, range: groupRange)
                    }
                }
            }
        }
    }
}
