import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

/// Colours for the editor, derived from the app theme.
struct EditorPalette {
    var isDark: Bool
    var background: NSColor
    var text: NSColor
    var gutterText: NSColor
    var gutterCurrentText: NSColor
    var gutterBackground: NSColor
    var currentLine: NSColor
    var tokens: [SyntaxTokenKind: NSColor]

    @MainActor
    static func make(theme: AppTheme) -> EditorPalette {
        let dark: Bool = {
            switch theme {
            case .light: return false
            case .dark, .midnight, .cyberpunk, .monokai: return true
            case .system:
                return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }()
        let background: NSColor = {
            switch theme {
            case .light: return NSColor(hex: "#FFFFFF")
            case .dark: return NSColor(hex: "#12141C")
            case .midnight: return NSColor(hex: "#0B1020")
            case .cyberpunk: return NSColor(hex: "#07070E")
            case .monokai: return NSColor(hex: "#272822")
            case .system: return dark ? NSColor(hex: "#1E1E22") : NSColor(hex: "#FFFFFF")
            }
        }()
        if theme == .monokai {
            return EditorPalette(
                isDark: true, background: background, text: NSColor(hex: "#F8F8F2"),
                gutterText: NSColor(hex: "#75715E"), gutterCurrentText: NSColor(hex: "#F8F8F2"),
                gutterBackground: NSColor(hex: "#23241F"), currentLine: NSColor(hex: "#3E3D32").withAlphaComponent(0.6),
                tokens: [
                    .keyword: NSColor(hex: "#F92672"), .type: NSColor(hex: "#66D9EF"),
                    .string: NSColor(hex: "#E6DB74"), .number: NSColor(hex: "#AE81FF"),
                    .comment: NSColor(hex: "#75715E"), .attribute: NSColor(hex: "#A6E22E"),
                    .function: NSColor(hex: "#A6E22E"), .property: NSColor(hex: "#FD971F"),
                    .tag: NSColor(hex: "#F92672"), .attributeName: NSColor(hex: "#A6E22E"),
                    .heading: NSColor(hex: "#66D9EF"), .link: NSColor(hex: "#AE81FF"),
                    .emphasis: NSColor(hex: "#FD971F"),
                ]
            )
        }
        if dark {
            return EditorPalette(
                isDark: true, background: background, text: NSColor(hex: "#E3E6EE"),
                gutterText: NSColor(hex: "#5B6072"), gutterCurrentText: NSColor(hex: "#C9CEDB"),
                gutterBackground: background.blended(withFraction: 0.04, of: .white) ?? background,
                currentLine: NSColor.white.withAlphaComponent(0.045),
                tokens: [
                    .keyword: NSColor(hex: "#FF7AB2"), .type: NSColor(hex: "#6BDFFF"),
                    .string: NSColor(hex: "#FF8170"), .number: NSColor(hex: "#D9C97C"),
                    .comment: NSColor(hex: "#7F8C98"), .attribute: NSColor(hex: "#FD8F3F"),
                    .function: NSColor(hex: "#67B7A4"), .property: NSColor(hex: "#A167E6"),
                    .tag: NSColor(hex: "#FF7AB2"), .attributeName: NSColor(hex: "#D9C97C"),
                    .heading: NSColor(hex: "#6BDFFF"), .link: NSColor(hex: "#5DD8FF"),
                    .emphasis: NSColor(hex: "#FD8F3F"),
                ]
            )
        }
        return EditorPalette(
            isDark: false, background: background, text: NSColor(hex: "#1F2328"),
            gutterText: NSColor(hex: "#A0A7B4"), gutterCurrentText: NSColor(hex: "#1F2328"),
            gutterBackground: NSColor(hex: "#F6F7F9"), currentLine: NSColor(hex: "#ECF5FF"),
            tokens: [
                .keyword: NSColor(hex: "#9B2393"), .type: NSColor(hex: "#0B4F79"),
                .string: NSColor(hex: "#C41A16"), .number: NSColor(hex: "#1C00CF"),
                .comment: NSColor(hex: "#5D6C79"), .attribute: NSColor(hex: "#815F03"),
                .function: NSColor(hex: "#326D74"), .property: NSColor(hex: "#6C36A9"),
                .tag: NSColor(hex: "#9B2393"), .attributeName: NSColor(hex: "#815F03"),
                .heading: NSColor(hex: "#0B4F79"), .link: NSColor(hex: "#0F68A0"),
                .emphasis: NSColor(hex: "#815F03"),
            ]
        )
    }
}

extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Text view

/// `NSTextView` with the editing behaviour code needs.
final class CodeTextView: NSTextView {

    weak var document: EditorDocument?
    var palette: EditorPalette?
    var onSave: (() -> Void)?
    var onGoToLine: (() -> Void)?
    var onCommandClick: ((String) -> Void)?
    var completionSource: ((String) -> [String])?

    /// An AI suggestion drawn as ghost text at `location`. Never part of the document until Tab
    /// accepts it, so it cannot be saved, undone or diffed by accident.
    struct Ghost: Equatable {
        var location: Int
        var text: String
    }

    var ghost: Ghost? {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }
    /// Set when the last edit typed through the ghost, so the coordinator does not ask again.
    private(set) var lastEditConsumedGhost = false

    private var indentation: EditorText.Indentation { document?.indentation ?? .spaces(4) }
    private var language: SyntaxLanguage { document?.language ?? .plain }
    private var nsText: NSString { string as NSString }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let palette, let layoutManager, let textContainer, selectedRange().length == 0 else { return }
        let location = selectedRange().location
        var lineRect: NSRect
        if location >= nsText.length, layoutManager.extraLineFragmentTextContainer != nil {
            lineRect = layoutManager.extraLineFragmentRect
        } else if nsText.length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, nsText.length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            lineRect = NSRect(x: 0, y: 0, width: textContainer.size.width, height: font?.boundingRectForFont.height ?? 16)
        }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        guard lineRect.intersects(rect) else { return }
        palette.currentLine.setFill()
        lineRect.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhost()
    }

    private func drawGhost() {
        guard let ghost, let palette, let font, selectedRange().length == 0,
              selectedRange().location == ghost.location, ghost.location <= nsText.length else { return }
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: NSRange(location: ghost.location, length: 0), actualRange: &actual)
        guard let window, screenRect != .zero else { return }
        let caret = convert(window.convertFromScreen(screenRect), from: nil)
        let lineHeight = layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height
        let ghostColor = palette.text.withAlphaComponent(palette.isDark ? 0.38 : 0.42)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ghostColor]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 3)),
            .foregroundColor: palette.gutterText,
        ]

        let lines = ghost.text.components(separatedBy: "\n")
        let first = lines[0] as NSString
        first.draw(at: NSPoint(x: caret.minX, y: caret.minY), withAttributes: attributes)
        let hint = "  ⇥ accept · esc" as NSString

        guard lines.count > 1 else {
            let firstWidth = first.size(withAttributes: attributes).width
            hint.draw(at: NSPoint(x: caret.minX + firstWidth, y: caret.minY + 2), withAttributes: hintAttributes)
            return
        }
        // Further lines float over the text below on a panel of their own, so ghost text never
        // interleaves with real code and cannot be mistaken for it.
        let rest = Array(lines.dropFirst())
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        let width = rest.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let panel = NSRect(
            x: left - 4,
            y: caret.minY + lineHeight,
            width: max(width, 120) + 16,
            height: CGFloat(rest.count) * lineHeight + lineHeight * 0.9
        )
        palette.background.setFill()
        let shape = NSBezierPath(roundedRect: panel, xRadius: 4, yRadius: 4)
        shape.fill()
        palette.gutterText.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        for (index, line) in rest.enumerated() {
            (line as NSString).draw(at: NSPoint(x: left, y: panel.minY + CGFloat(index) * lineHeight), withAttributes: attributes)
        }
        hint.draw(at: NSPoint(x: left, y: panel.maxY - lineHeight * 0.95), withAttributes: hintAttributes)
    }

    /// Insert the whole suggestion, as one undoable edit.
    @discardableResult
    func acceptGhost() -> Bool {
        guard let ghost, selectedRange().length == 0, selectedRange().location == ghost.location else { return false }
        self.ghost = nil
        let range = NSRange(location: ghost.location, length: 0)
        guard shouldChangeText(in: range, replacementString: ghost.text) else { return false }
        textStorage?.replaceCharacters(in: range, with: ghost.text)
        lastEditConsumedGhost = true
        didChangeText()
        lastEditConsumedGhost = false
        setSelectedRange(NSRange(location: ghost.location + (ghost.text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if ghost != nil {
            ghost = nil
            return
        }
        super.cancelOperation(sender)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Moving the cursor away from a suggestion withdraws it.
        if let ghost, selectedRange() != NSRange(location: ghost.location, length: 0) {
            self.ghost = nil
        }
        // The current-line band moves with the cursor.
        needsDisplay = true
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "/": toggleComment(); return true
        case "s": onSave?(); return true
        case "l": onGoToLine?(); return true
        case "]": shiftSelectedLines(outdent: false); return true
        case "[": shiftSelectedLines(outdent: true); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let insertion = EditorText.newlineInsertion(
            at: selection.location, in: nsText, indentation: indentation, language: language
        )
        replace(selection, with: insertion.text, cursorAt: selection.location + insertion.cursorOffset)
    }

    override func insertTab(_ sender: Any?) {
        if acceptGhost() { return }
        let selection = selectedRange()
        if selection.length > 0, nsText.substring(with: selection).contains("\n") {
            shiftSelectedLines(outdent: false)
            return
        }
        // Tab completes a word in progress, and indents everywhere else.
        if selection.length == 0 {
            let prefix = identifierPrefixRange(endingAt: selection.location)
            if prefix.length > 0,
               let source = completionSource,
               !source(nsText.substring(with: prefix)).isEmpty {
                complete(sender)
                return
            }
        }
        replace(selection, with: indentation.unit, cursorAt: selection.location + (indentation.unit as NSString).length)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftSelectedLines(outdent: true)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typing what the suggestion says keeps the rest of it; typing anything else withdraws it.
        if let ghost, let typed = string as? String, replacementRange.location == NSNotFound,
           selectedRange() == NSRange(location: ghost.location, length: 0) {
            if !typed.isEmpty, ghost.text.hasPrefix(typed), ghost.text.count > typed.count {
                self.ghost = Ghost(
                    location: ghost.location + (typed as NSString).length,
                    text: String(ghost.text.dropFirst(typed.count))
                )
                lastEditConsumedGhost = true
                super.insertText(string, replacementRange: replacementRange)
                lastEditConsumedGhost = false
                return
            }
            self.ghost = nil
        }
        // A closing brace typed on a blank line steps back one level.
        if let typed = string as? String, typed == "}" || typed == "]" || typed == ")",
           replacementRange.location == NSNotFound {
            let selection = selectedRange()
            let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
            let beforeCursor = nsText.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
            let unitLength = (indentation.unit as NSString).length
            if selection.length == 0, !beforeCursor.isEmpty,
               beforeCursor.allSatisfy({ $0 == " " || $0 == "\t" }),
               (beforeCursor as NSString).length >= unitLength {
                let removal = NSRange(location: selection.location - unitLength, length: unitLength)
                super.insertText(typed, replacementRange: removal)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Completion

    override var rangeForUserCompletion: NSRange {
        identifierPrefixRange(endingAt: selectedRange().location)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        index.pointee = 0
        guard charRange.length > 0, let source = completionSource else { return nil }
        let candidates = source(nsText.substring(with: charRange))
        return candidates.isEmpty ? nil : candidates
    }

    private func identifierPrefixRange(endingAt location: Int) -> NSRange {
        var start = location
        while start > 0 {
            let c = nsText.character(at: start - 1)
            let isIdentifier = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
            guard isIdentifier else { break }
            start -= 1
        }
        return NSRange(location: start, length: location - start)
    }

    // MARK: Go to definition

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let onCommandClick {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index < nsText.length {
                var end = index
                while end < nsText.length {
                    let c = nsText.character(at: end)
                    let isIdentifier = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
                    guard isIdentifier else { break }
                    end += 1
                }
                let word = identifierPrefixRange(endingAt: end)
                if word.length > 0 {
                    onCommandClick(nsText.substring(with: word))
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Line operations

    func toggleComment() {
        guard let prefix = language.lineCommentPrefix else {
            NSSound.beep()
            return
        }
        let lines = EditorText.wholeLines(for: selectedRange(), in: nsText)
        let block = nsText.substring(with: lines)
        let replaced = EditorText.toggleLineComments(block, prefix: prefix)
        replace(lines, with: replaced, select: NSRange(location: lines.location, length: (replaced as NSString).length))
    }

    func shiftSelectedLines(outdent: Bool) {
        let lines = EditorText.wholeLines(for: selectedRange(), in: nsText)
        let block = nsText.substring(with: lines)
        let replaced = EditorText.shiftLines(block, by: indentation, outdent: outdent)
        guard replaced != block else { return }
        replace(lines, with: replaced, select: NSRange(location: lines.location, length: (replaced as NSString).length))
    }

    /// Replace through the text system, so the edit is one undo step and delegates hear about it.
    private func replace(_ range: NSRange, with text: String, cursorAt cursor: Int? = nil, select selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let selection {
            setSelectedRange(selection)
        } else if let cursor {
            setSelectedRange(NSRange(location: cursor, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }
}

// MARK: - Line numbers

final class LineNumberRulerView: NSRulerView {

    weak var codeTextView: CodeTextView?
    var palette: EditorPalette?
    private var lineStarts: [Int] = [0]
    private var lineStartsRevision = -1
    private weak var lineStartsDocument: EditorDocument?

    init(textView: CodeTextView, scrollView: NSScrollView) {
        self.codeTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    private func refreshLineStarts() {
        guard let textView = codeTextView, let document = textView.document else { return }
        guard document !== lineStartsDocument || document.textRevision != lineStartsRevision else { return }
        let text = textView.string as NSString
        var starts = [0]
        starts.reserveCapacity(text.length / 30)
        let length = text.length
        var i = 0
        while i < length {
            if text.character(at: i) == 10 { starts.append(i + 1) }
            i += 1
        }
        lineStarts = starts
        lineStartsRevision = document.textRevision
        lineStartsDocument = document
        let digits = max(3, String(starts.count).count)
        let width = CGFloat(digits) * 7.8 + 18
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
            // The scroll view only lays the ruler and the text out side by side when it tiles.
            // Without this the clip view kept its old frame and the gutter was drawn over the
            // first characters of every line.
            scrollView?.tile()
        }
    }

    /// 0-based index of the line containing `location`.
    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let palette else { return }
        refreshLineStarts()

        palette.gutterBackground.setFill()
        bounds.fill()

        let fontSize = max(9, (textView.font?.pointSize ?? 13) - 1)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let cursorLine = lineIndex(containing: textView.selectedRange().location)

        func draw(_ number: Int, atLineFragment fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let isCurrent = number - 1 == cursorLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCurrent ? palette.gutterCurrentText : palette.gutterText,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let baselineOffset = (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + baselineOffset), withAttributes: attributes)
        }

        var line = lineIndex(containing: charRange.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(charRange) { break }
            if start >= text.length {
                // The empty last line after a trailing newline.
                if layoutManager.extraLineFragmentTextContainer != nil {
                    draw(line + 1, atLineFragment: layoutManager.extraLineFragmentRect)
                }
                break
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line + 1, atLineFragment: fragment)
            line += 1
        }
        if text.length == 0 {
            draw(1, atLineFragment: NSRect(x: 0, y: 0, width: 0, height: textView.font?.boundingRectForFont.height ?? 16))
        }
    }
}

// MARK: - SwiftUI bridge

struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    var theme: AppTheme
    var fontSize: CGFloat
    var wrapLines: Bool
    var workspaceSymbols: [String]
    var onSave: () -> Void
    var onGoToLine: () -> Void
    var onCommandClick: (String) -> Void
    var onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.scrollView = scrollView
        context.coordinator.layoutManager = layoutManager
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        coordinator.parent = self

        textView.onSave = onSave
        textView.onGoToLine = onGoToLine
        textView.onCommandClick = onCommandClick
        let symbols = workspaceSymbols
        textView.completionSource = { [weak textView] prefix in
            guard let document = textView?.document else { return [] }
            return EditorText.completions(
                prefix: prefix,
                documentWords: coordinator.words(for: document),
                workspaceSymbols: symbols,
                keywords: EditorText.keywords(for: document.language)
            )
        }

        let palette = EditorPalette.make(theme: theme)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let styleChanged = coordinator.appliedFontSize != fontSize || coordinator.appliedDark != palette.isDark
            || coordinator.appliedTheme != theme
        textView.palette = palette
        coordinator.ruler?.palette = palette

        if coordinator.document !== document {
            coordinator.attach(document, font: font, palette: palette)
        } else if styleChanged {
            coordinator.applyBaseAttributes(font: font, palette: palette)
            coordinator.applyTokens(force: true)
        }
        coordinator.appliedFontSize = fontSize
        coordinator.appliedDark = palette.isDark
        coordinator.appliedTheme = theme

        if coordinator.seenExternalRevision != document.externalRevision {
            coordinator.seenExternalRevision = document.externalRevision
            coordinator.applyBaseAttributes(font: font, palette: palette)
            textView.setSelectedRange(document.selectedRange)
            coordinator.scheduleHighlight(immediate: true)
            coordinator.ruler?.needsDisplay = true
        }

        if coordinator.appliedWrap != wrapLines {
            coordinator.appliedWrap = wrapLines
            coordinator.setWrap(wrapLines)
        }

        if let line = document.pendingReveal {
            DispatchQueue.main.async {
                guard document.pendingReveal == line else { return }
                let selection = document.pendingRevealSelection
                document.pendingReveal = nil
                document.pendingRevealSelection = nil
                coordinator.reveal(line: line, selecting: selection)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView?
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRulerView?
        weak var scrollView: NSScrollView?
        var layoutManager: NSLayoutManager?
        private(set) weak var document: EditorDocument?
        var appliedFontSize: CGFloat = 0
        var appliedDark: Bool?
        var appliedTheme: AppTheme?
        var appliedWrap: Bool?
        var seenExternalRevision = -1
        private var highlightTask: Task<Void, Never>?
        private var suggestionWork: DispatchWorkItem?
        private var suggestionTask: Task<Void, Never>?
        private var cachedWords: (revision: Int, documentId: UUID, words: [String])?

        func attach(_ newDocument: EditorDocument, font: NSFont, palette: EditorPalette) {
            guard let textView, let layoutManager else { return }
            if let old = document {
                old.selectedRange = textView.selectedRange()
                old.scrollOrigin = scrollView?.contentView.bounds.origin ?? .zero
                old.storage.removeLayoutManager(layoutManager)
            }
            cancelSuggestions()
            document = newDocument
            textView.document = newDocument
            newDocument.storage.addLayoutManager(layoutManager)
            seenExternalRevision = newDocument.externalRevision
            applyBaseAttributes(font: font, palette: palette)
            let length = newDocument.storage.length
            let selection = newDocument.selectedRange
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
            if let clip = scrollView?.contentView {
                clip.scroll(to: newDocument.scrollOrigin)
                scrollView?.reflectScrolledClipView(clip)
            }
            applyTokens(force: true)
            scrollView?.tile()
            if newDocument.tokensRevision != newDocument.textRevision {
                scheduleHighlight(immediate: true)
            }
            ruler?.needsDisplay = true
            textView.needsDisplay = true
        }

        func detach() {
            cancelSuggestions()
            guard let layoutManager, let document else { return }
            if let textView {
                document.selectedRange = textView.selectedRange()
            }
            document.scrollOrigin = scrollView?.contentView.bounds.origin ?? .zero
            document.storage.removeLayoutManager(layoutManager)
            self.document = nil
        }

        func applyBaseAttributes(font: NSFont, palette: EditorPalette) {
            guard let textView, let document else { return }
            let full = NSRange(location: 0, length: document.storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.defaultTabInterval = font.advancement(forGlyph: font.glyph(withName: "space")).width * 4
            paragraph.tabStops = []
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: palette.text,
                .paragraphStyle: paragraph,
            ]
            document.storage.beginEditing()
            document.storage.setAttributes(attributes, range: full)
            document.storage.endEditing()
            textView.font = font
            textView.typingAttributes = attributes
            textView.backgroundColor = palette.background
            textView.insertionPointColor = palette.isDark ? .white : .black
            textView.selectedTextAttributes = [
                .backgroundColor: palette.isDark
                    ? NSColor(hex: "#3A4A6B")
                    : NSColor(hex: "#B4D7FF"),
            ]
            scrollView?.backgroundColor = palette.background
            ruler?.needsDisplay = true
        }

        func setWrap(_ wrap: Bool) {
            guard let textView, let container = textView.textContainer, let scrollView else { return }
            if wrap {
                scrollView.hasHorizontalScroller = false
                textView.isHorizontallyResizable = false
                container.widthTracksTextView = true
                container.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                textView.frame.size.width = scrollView.contentSize.width
            } else {
                scrollView.hasHorizontalScroller = true
                textView.isHorizontallyResizable = true
                container.widthTracksTextView = false
                container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            ruler?.needsDisplay = true
        }

        func reveal(line: Int, selecting selection: (column: Int, length: Int)? = nil) {
            guard let textView else { return }
            let text = textView.string as NSString
            let start = EditorText.location(ofLine: line, in: text)
            var lineRange = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
            if lineRange.length > 0, NSMaxRange(lineRange) <= text.length,
               text.character(at: NSMaxRange(lineRange) - 1) == 10 {
                lineRange.length -= 1
            }
            textView.window?.makeFirstResponder(textView)
            // A search result selects its match; a plain jump puts the cursor at the line start.
            var match: NSRange?
            if let selection, selection.column >= 0, selection.length > 0 {
                let location = min(lineRange.location + selection.column, text.length)
                match = NSRange(location: location, length: min(selection.length, text.length - location))
            }
            textView.setSelectedRange(match ?? NSRange(location: lineRange.location, length: 0))
            if let indicator = match ?? (lineRange.length > 0 ? lineRange : nil) {
                // Before the scroll below: the indicator scrolls its whole range into view, which on
                // a long line pulled the view sideways and hid the start of every line.
                textView.showFindIndicator(for: indicator)
            }
            // Centre it vertically, at the left edge, rather than leaving it pinned to a corner.
            if let layoutManager = textView.layoutManager, let container = textView.textContainer, let scrollView {
                let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                let clip = scrollView.contentView
                let visibleHeight = clip.bounds.height
                var wanted = clip.bounds
                wanted.origin = NSPoint(x: Self.leftmostOriginX(of: scrollView), y: rect.midY - visibleHeight / 2)
                clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                // A match far along a long line still has to be visible.
                if let match {
                    let matchGlyphs = layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
                    var matchRect = layoutManager.boundingRect(forGlyphRange: matchGlyphs, in: container)
                    matchRect.origin.x += textView.textContainerOrigin.x
                    if !textView.visibleRect.contains(matchRect) {
                        textView.scrollRangeToVisible(match)
                    }
                }
            }
            ruler?.needsDisplay = true
        }

        /// The clip view's x origin when scrolled fully left.
        ///
        /// Not always 0. Current AppKit lays a vertical ruler *over* a full-width clip view and
        /// insets the text with a negative bounds origin (x = -ruleThickness). Scrolling to x = 0
        /// there slid the first characters of every line under the line numbers.
        static func leftmostOriginX(of scrollView: NSScrollView) -> CGFloat {
            guard scrollView.rulersVisible, let ruler = scrollView.verticalRulerView else { return 0 }
            let rulerOverlapsClip = scrollView.contentView.frame.minX < ruler.frame.maxX - 0.5
            return rulerOverlapsClip ? -ruler.ruleThickness : 0
        }

        func words(for document: EditorDocument) -> [String] {
            if let cached = cachedWords, cached.documentId == document.id, cached.revision == document.textRevision {
                return cached.words
            }
            let words = EditorText.words(in: document.text)
            cachedWords = (document.textRevision, document.id, words)
            return words
        }

        // MARK: Highlighting

        func scheduleHighlight(immediate: Bool = false) {
            guard let document else { return }
            highlightTask?.cancel()
            let text = document.text
            let revision = document.textRevision
            let language = document.language
            let length = (text as NSString).length
            // Short files recolour almost as you type; long ones wait for a pause.
            let delay: TimeInterval = immediate ? 0 : (length < 150_000 ? 0.05 : 0.3)
            highlightTask = Task { [weak self, weak document] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                // `SyntaxHighlighter.tokens` is nonisolated, pure computation — hop off the main
                // actor for it explicitly. A plain `DispatchWorkItem` run on `DispatchQueue.global`
                // used to be handed this work instead, but a closure written inside a `@MainActor`
                // method is itself inferred `@MainActor`; running it on a background queue tripped
                // Swift's runtime isolation check and crashed the app on every highlight pass.
                let tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.tokens(in: text, language: language)
                }.value
                guard !Task.isCancelled, let self, let document, self.document === document,
                      document.textRevision == revision else { return }
                document.tokens = tokens
                document.tokensRevision = revision
                self.applyTokens(force: true)
            }
        }

        func applyTokens(force: Bool) {
            guard let layoutManager, let document, let palette = textView?.palette else { return }
            let full = NSRange(location: 0, length: document.storage.length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            for token in document.tokens where NSMaxRange(token.range) <= full.length {
                if let color = palette.tokens[token.kind] {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let document else { return }
            document.textDidChange()
            scheduleHighlight()
            ruler?.needsDisplay = true
            if textView?.lastEditConsumedGhost == true { return }
            textView?.ghost = nil
            scheduleSuggestion()
        }

        // MARK: Suggestions

        /// Ask for a suggestion once typing pauses. Only edits schedule one — moving the cursor
        /// around to read code never does — and any newer edit cancels the pending request.
        func scheduleSuggestion() {
            suggestionWork?.cancel()
            suggestionTask?.cancel()
            InlineSuggestionEngine.shared.cancel()
            guard AppState.shared.settings.inlineSuggestionsEnabled, let document, let textView else { return }
            let revision = document.textRevision
            let work = DispatchWorkItem { [weak self, weak document, weak textView] in
                guard let self, let document, let textView,
                      self.document === document, document.textRevision == revision else { return }
                let selection = textView.selectedRange()
                let text = textView.string as NSString
                guard InlineSuggestionPolicy.shouldRequest(
                    text: text, caret: selection.location, selectionLength: selection.length, language: document.language
                ) else { return }
                let request = InlineSuggestionRequest(path: document.path, language: document.language, text: text, caret: selection.location)
                let caret = selection.location
                self.suggestionTask = Task { @MainActor [weak self, weak document, weak textView] in
                    let suggestion = await InlineSuggestionEngine.shared.suggest(request)
                    guard let self, let document, let textView, !Task.isCancelled,
                          self.document === document, document.textRevision == revision,
                          textView.selectedRange() == NSRange(location: caret, length: 0),
                          let suggestion else { return }
                    textView.ghost = CodeTextView.Ghost(location: caret, text: suggestion)
                }
            }
            suggestionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + InlineSuggestionPolicy.pauseBeforeRequest, execute: work)
        }

        func cancelSuggestions() {
            suggestionWork?.cancel()
            suggestionTask?.cancel()
            textView?.ghost = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let document else { return }
            let selection = textView.selectedRange()
            document.selectedRange = selection
            let position = EditorText.lineAndColumn(of: selection.location, in: textView.string as NSString)
            parent?.onCursorChange(position.line, position.column)
            ruler?.needsDisplay = true
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            document?.undoManager
        }

        @objc func boundsDidChange(_ notification: Notification) {
            ruler?.needsDisplay = true
        }
    }
}
