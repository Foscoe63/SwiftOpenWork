import SwiftUI
import SwiftOpenWorkEngine

/// A message as the mods want it drawn. With no mod listening it is `content(text)` and nothing
/// more. A mod can rewrite the text (hide a name while sharing a screen), or draw the message itself.
struct ModMaskedMessage<Content: View>: View {
    let component: String
    let text: String
    let isStreaming: Bool
    @ViewBuilder let content: (String) -> Content
    @ObservedObject private var host = ModHost.shared
    @State private var result: ModRenderResult = .none

    var body: some View {
        Group {
            switch result {
            case .tree(let node) where host.hasMessageHooks:
                ModElementView(node: node, component: component, requestId: "msg", theme: "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .engine(let props) where host.hasMessageHooks:
                content(props["text"]?.string ?? text)
            default:
                content(text)
            }
        }
        .task(id: "\(text.count)-\(text.hashValue)-\(host.revision)-\(host.hasMessageHooks)") {
            guard host.hasMessageHooks else { result = .none; return }
            // A message that is still streaming changes every few milliseconds; wait for a pause.
            try? await Task.sleep(nanoseconds: isStreaming ? 250_000_000 : 40_000_000)
            guard !Task.isCancelled else { return }
            result = await host.render(component: component, requestId: "msg", props: ["text": .string(text)])
        }
    }
}
