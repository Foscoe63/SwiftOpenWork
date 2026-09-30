import SwiftUI
import SwiftOpenWorkCore

/// Browse Radiant's ready-made agent personas and pick one. The caller turns the pick into an
/// unsaved agent and opens it in the editor, so nothing is created until the user saves.
struct AgentTemplatePicker: View {
    let theme: AppTheme
    let accent: AccentColorChoice
    var onPick: (AgentTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category: String? = nil

    private var results: [AgentTemplate] {
        AgentTemplateCatalog.matching(query: query, category: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Agent from Template")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                    Text("\(AgentTemplateCatalog.templates.count) ready-made personas. Pick one, then adjust it before saving.")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            HStack(spacing: 10) {
                TextField("Search templates", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All categories").tag(String?.none)
                    ForEach(AgentTemplateCatalog.categories, id: \.self) { cat in
                        Text(cat).tag(String?.some(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if results.isEmpty {
                Text("No templates match.")
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)], spacing: 12) {
                        ForEach(results) { template in
                            card(template)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 760, height: 560)
        .background(ThemeColors.bg(for: theme))
    }

    private func card(_ t: AgentTemplate) -> some View {
        Button {
            onPick(t)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: t.avatar)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(hex: t.color))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                    Text(t.blurb)
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(t.category)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(ThemeColors.accent(for: accent))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColors.cardBg(for: theme))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ThemeColors.border(for: theme), lineWidth: 1))
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.persona)
    }
}
