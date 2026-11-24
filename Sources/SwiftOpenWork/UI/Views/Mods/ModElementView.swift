import SwiftUI
import AppKit
import SwiftOpenWorkEngine

/// Draws what a mod's `ui.render` hook returned: Box, Text, Button, Input, Select, Svg, Link,
/// Code and Markdown. The sizes mods give are in terminal cells (they were written for a
/// terminal too), so a cell is about 8pt across and 12pt down here.
struct ModElementView: View {
    let node: ModNode
    let component: String
    let requestId: String
    let theme: String

    var body: some View {
        ModNodeView(node: node, ctx: ModDrawContext(component: component, requestId: requestId, theme: theme))
    }
}

struct ModDrawContext {
    var component: String
    var requestId: String
    var theme: String
}

private enum ModMetrics {
    static func across(_ value: ModJSON?) -> CGFloat? { value?.number.map { CGFloat($0) * 8 } }
    static func down(_ value: ModJSON?) -> CGFloat? { value?.number.map { CGFloat($0) * 12 } }
}

private enum ModColor {
    static func color(_ name: String?) -> Color? {
        guard let name, !name.isEmpty else { return nil }
        switch name {
        case "black": return Color(hex: 0x1b1b1b)
        case "red", "error": return Color(hex: 0xd14343)
        case "green", "success": return Color(hex: 0x16a34a)
        case "yellow", "warning": return Color(hex: 0xc58b00)
        case "blue": return Color(hex: 0x3b82f6)
        case "magenta": return Color(hex: 0xb455c4)
        case "cyan": return Color(hex: 0x0e9db5)
        case "white": return Color(hex: 0xf0efec)
        case "gray", "grey": return Color(hex: 0x8a8985)
        case "blackBright": return Color(hex: 0x6b6a65)
        case "redBright": return Color(hex: 0xef6a6a)
        case "greenBright": return Color(hex: 0x3fd17e)
        case "yellowBright": return Color(hex: 0xe2b73a)
        case "blueBright": return Color(hex: 0x6ea0f7)
        case "magentaBright": return Color(hex: 0xd27ae0)
        case "cyanBright": return Color(hex: 0x4ec6da)
        case "whiteBright": return .white
        case "accent": return .accentColor
        default:
            let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
            if hex.count == 6, let value = UInt32(hex, radix: 16) { return Color(hex: value) }
            if hex.count == 3, let value = UInt32(hex.map { "\($0)\($0)" }.joined(), radix: 16) { return Color(hex: value) }
            return nil
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ModNodeView: View {
    let node: ModNode
    let ctx: ModDrawContext

    var body: some View {
        switch node {
        case .text(let text): Text(text).font(.system(size: 12))
        case .fragment(let items):
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in ModNodeView(node: item, ctx: ctx) }
        case .element(let element):
            ModElementNode(element: element, ctx: ctx)
        }
    }
}

private struct ModElementNode: View {
    let element: ModElement
    let ctx: ModDrawContext

    var body: some View {
        switch element.type {
        case "Box": ModBox(element: element, ctx: ctx)
        case "Text": ModTextNode.text(element, ctx: ctx)
        case "Button": ModButtonNode(element: element, ctx: ctx)
        case "Input": ModInputNode(element: element, ctx: ctx)
        case "Select": ModSelectNode(element: element, ctx: ctx)
        case "Link": ModLinkNode(element: element)
        case "Code":
            Text(element.prop("code")?.string ?? element.prop("text")?.string ?? ModTextNode.plain(element.children))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        case "Markdown":
            let source = element.prop("text")?.string ?? element.prop("markdown")?.string ?? ModTextNode.plain(element.children)
            Text((try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "Svg", "Image":
            ModSvgNode(element: element)
        default:
            ForEach(Array(element.children.enumerated()), id: \.offset) { _, child in ModNodeView(node: child, ctx: ctx) }
        }
    }
}

private struct ModBox: View {
    let element: ModElement
    let ctx: ModDrawContext

    private var hasBorder: Bool { !(element.prop("borderStyle")?.string ?? "").isEmpty }
    private var isColumn: Bool { (element.prop("flexDirection")?.string ?? "row").hasPrefix("column") }
    private var gap: CGFloat { ModMetrics.across(element.prop("gap")) ?? ModMetrics.across(element.prop("columnGap")) ?? 0 }

    var body: some View {
        if element.prop("display")?.string == "none" { EmptyView() }
        else {
            let content = Group {
                if isColumn {
                    VStack(alignment: horizontalAlignment, spacing: ModMetrics.down(element.prop("gap")) ?? ModMetrics.down(element.prop("rowGap")) ?? 0) { kids }
                } else {
                    HStack(alignment: verticalAlignment, spacing: gap) { rowKids }
                }
            }
            content
                // A terminal border takes a cell on every side; ours is drawn over the box, so leave room for it.
                .padding(.horizontal, hasBorder ? 6 : 0)
                .padding(.vertical, hasBorder ? 5 : 0)
                .padding(.leading, edge("paddingLeft", "paddingX", "padding", horizontal: true))
                .padding(.trailing, edge("paddingRight", "paddingX", "padding", horizontal: true))
                .padding(.top, edge("paddingTop", "paddingY", "padding", horizontal: false))
                .padding(.bottom, edge("paddingBottom", "paddingY", "padding", horizontal: false))
                .frame(minWidth: ModMetrics.across(element.prop("minWidth")), minHeight: ModMetrics.down(element.prop("minHeight")))
                .frame(width: ModMetrics.across(element.prop("width")), height: ModMetrics.down(element.prop("height")))
                .frame(maxWidth: (element.prop("flexGrow")?.number ?? 0) > 0 && !isColumn ? .infinity : nil, alignment: .leading)
                .background(ModColor.color(element.prop("backgroundColor")?.string))
                .overlay(border)
                .padding(.leading, edge("marginLeft", "marginX", "margin", horizontal: true))
                .padding(.trailing, edge("marginRight", "marginX", "margin", horizontal: true))
                .padding(.top, edge("marginTop", "marginY", "margin", horizontal: false))
                .padding(.bottom, edge("marginBottom", "marginY", "margin", horizontal: false))
        }
    }

    /// A row's children, spread the way `justifyContent` asks (the default packs them at the start).
    @ViewBuilder private var rowKids: some View {
        let mode = element.prop("justifyContent")?.string ?? ""
        let items = Array(element.children.enumerated())
        if mode == "space-between", items.count > 1 {
            ForEach(items, id: \.offset) { index, child in
                if index > 0 { Spacer(minLength: 0) }
                ModNodeView(node: child, ctx: ctx)
            }
        } else if mode == "flex-end" || mode == "center" {
            Spacer(minLength: 0)
            kids
            if mode == "center" { Spacer(minLength: 0) }
        } else {
            kids
            if !mode.isEmpty { Spacer(minLength: 0) }   // a lone child still sits at the start
        }
    }

    @ViewBuilder private var kids: some View {
        ForEach(Array(element.children.enumerated()), id: \.offset) { _, child in ModNodeView(node: child, ctx: ctx) }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch element.prop("alignItems")?.string { case "center": return .center; case "flex-end": return .trailing; default: return .leading }
    }
    private var verticalAlignment: VerticalAlignment {
        switch element.prop("alignItems")?.string { case "center": return .center; case "flex-end": return .bottom; default: return .top }
    }

    private func edge(_ side: String, _ axis: String, _ all: String, horizontal: Bool) -> CGFloat {
        for key in [side, axis, all] {
            if let value = element.prop(key) {
                if let measured = horizontal ? ModMetrics.across(value) : ModMetrics.down(value) { return measured }
            }
        }
        return 0
    }

    @ViewBuilder private var border: some View {
        if let style = element.prop("borderStyle")?.string, !style.isEmpty {
            let base = ModColor.color(element.prop("borderColor")?.string) ?? Color.secondary.opacity(0.5)
            RoundedRectangle(cornerRadius: style == "round" ? 8 : 3)
                .stroke(element.prop("borderDimColor")?.bool == true ? base.opacity(0.45) : base, lineWidth: 1)
        }
    }
}

enum ModTextNode {
    /// The text of an element's children, without styling.
    static func plain(_ children: [ModNode]) -> String {
        children.map { node -> String in
            switch node {
            case .text(let s): return s
            case .fragment(let items): return plain(items)
            case .element(let e): return plain(e.children)
            }
        }.joined()
    }

    /// A Text element: its own style over its children, whose nested Text elements keep theirs.
    static func text(_ element: ModElement, ctx: ModDrawContext) -> some View {
        styled(element)
            .textSelection(.enabled)
            .lineLimit(truncates(element) ? 1 : nil)
            .truncationMode(element.prop("wrap")?.string == "truncate-start" ? .head : element.prop("wrap")?.string == "middle" ? .middle : .tail)
    }

    private static func truncates(_ e: ModElement) -> Bool {
        guard let wrap = e.prop("wrap")?.string else { return false }
        return wrap.hasPrefix("truncate") || wrap == "end" || wrap == "middle"
    }

    static func styled(_ element: ModElement) -> Text {
        var run = Text("")
        for child in element.children {
            switch child {
            case .text(let s): run = run + Text(s)
            case .fragment(let items): run = run + Text(plain(items))
            case .element(let e): run = run + (e.type == "Text" ? styled(e) : Text(plain(e.children)))
            }
        }
        var out = run
        let size: CGFloat
        switch element.prop("size")?.string { case "caption", "footnote": size = 11.5; case "heading": size = 16; case "title": size = 20; default: size = 12 }
        let weight: Font.Weight = (element.prop("bold")?.bool == true || element.prop("weight")?.string == "bold") ? .bold
            : element.prop("weight")?.string == "semibold" ? .semibold : element.prop("weight")?.string == "medium" ? .medium : .regular
        out = out.font(element.prop("mono")?.bool == true ? .system(size: size, weight: weight, design: .monospaced) : .system(size: size, weight: weight))
        if element.prop("italic")?.bool == true { out = out.italic() }
        if element.prop("underline")?.bool == true { out = out.underline() }
        if element.prop("strikethrough")?.bool == true { out = out.strikethrough() }
        if element.prop("tabular")?.bool == true { out = out.monospacedDigit() }
        if let color = ModColor.color(element.prop("color")?.string) { out = out.foregroundColor(color) }
        if element.prop("dimColor")?.bool == true { out = out.foregroundColor(.secondary) }
        return out
    }
}

private struct ModButtonNode: View {
    let element: ModElement
    let ctx: ModDrawContext
    @State private var busy = false

    var body: some View {
        let label = element.prop("label")?.string ?? ModTextNode.plain(element.children)
        Button {
            guard let plugin = element.pressPlugin, let handle = element.pressHandle else { return }
            busy = true
            Task {
                await ModHost.shared.press(plugin: plugin, handle: handle, element: element.prop("key")?.text, component: ctx.component, requestId: ctx.requestId)
                busy = false
            }
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: element.prop("variant")?.string == "primary" ? .semibold : .regular))
                .padding(.horizontal, element.prop("plain")?.bool == true ? 2 : 10)
                .padding(.vertical, element.prop("plain")?.bool == true ? 0 : 4)
                .foregroundColor(element.prop("variant")?.string == "primary" ? .white : .primary)
                .background(element.prop("plain")?.bool == true ? Color.clear : (element.prop("variant")?.string == "primary" ? Color.accentColor : Color.secondary.opacity(0.15)))
                .cornerRadius(6)
                .opacity(element.prop("dimColor")?.bool == true ? 0.62 : 1)
        }
        .buttonStyle(.hitTestable)
        .disabled(busy || element.pressHandle == nil)
        .help(element.prop("hotkey")?.string.map { "Shortcut: \($0)" } ?? "")
    }
}

private struct ModInputNode: View {
    let element: ModElement
    let ctx: ModDrawContext
    @State private var text: String = ""
    @State private var seeded = false

    var body: some View {
        TextField(element.prop("placeholder")?.string ?? element.prop("label")?.string ?? "", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onAppear { if !seeded { text = element.prop("value")?.string ?? ""; seeded = true } }
            .onSubmit { fire(element.onSubmit) }
            .onChange(of: text) { _, _ in fire(element.onInput, quiet: true) }
    }

    private func fire(_ handle: Int?, quiet: Bool = false) {
        guard let plugin = element.pressPlugin, let handle else { return }
        let value = text
        Task { await ModHost.shared.press(plugin: plugin, handle: handle, element: element.prop("key")?.text, component: ctx.component, requestId: ctx.requestId, text: value) }
    }
}

private struct ModSelectNode: View {
    let element: ModElement
    let ctx: ModDrawContext
    @State private var selection: String = ""
    @State private var seeded = false

    private var options: [(value: String, label: String)] {
        (element.prop("options")?.array ?? []).compactMap { option in
            if let s = option.string { return (s, s) }
            guard let o = option.object, let value = o["value"]?.text ?? o["label"]?.text else { return nil }
            return (value, o["label"]?.text ?? value)
        }
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .onAppear { if !seeded { selection = element.prop("value")?.text ?? options.first?.value ?? ""; seeded = true } }
        .onChange(of: selection) { _, value in
            guard let plugin = element.pressPlugin, let handle = element.onSelect else { return }
            Task { await ModHost.shared.press(plugin: plugin, handle: handle, element: element.prop("key")?.text, component: ctx.component, requestId: ctx.requestId, text: value, value: value) }
        }
    }
}

private struct ModLinkNode: View {
    let element: ModElement

    var body: some View {
        let label = element.prop("label")?.string ?? ModTextNode.plain(element.children)
        let target = element.prop("url")?.string ?? element.prop("href")?.string ?? ""
        Button(label) {
            // Only web links open: a mod cannot launch an app or a file through a link.
            if let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}

private struct ModSvgNode: View {
    let element: ModElement

    var body: some View {
        if let source = element.prop("source")?.string, let image = NSImage(data: Data(source.utf8)) {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .frame(width: element.prop("width")?.number.map { CGFloat($0) }, height: element.prop("height")?.number.map { CGFloat($0) })
                .accessibilityLabel(element.prop("alt")?.string ?? "")
        } else if let alt = element.prop("alt")?.string {
            Text(alt).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
