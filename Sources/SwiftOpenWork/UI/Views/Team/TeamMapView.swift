import AppKit
import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// The Team map: every agent, grouped into department panels on a pannable, zoomable canvas, with a box
/// at the bottom to message an agent, a department, or everyone.
///
/// A message tagged to a department goes to that department's lead, who hands the work to the others
/// and answers once. See `TeamMapLogic.recipients`.
struct TeamMapView: View {
    @ObservedObject var appState: AppState

    @State private var view = TeamMapTransform()
    @State private var didFit = false
    @State private var panStart: TeamMapTransform?
    @State private var zoomStart: Double?
    @State private var panelDrag: (key: String, origin: CanvasPoint, offset: CGSize)?
    @State private var agentDrag: (agent: Agent, location: CGPoint)?
    @State private var pendingMove: (agent: Agent, dept: String)?
    @State private var showUsage = false
    @State private var usageDays = 7
    @State private var creating = false
    @State private var importing = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @State private var editingInstructions: Named?
    @State private var editingMemory: Named?
    @State private var editingCharge: Named?
    @State private var draft = ""
    @State private var announcement = ""
    @State private var sheetError = ""
    @State private var canvasSize = CGSize(width: 800, height: 500)

    private let space = "teamMapCanvas"

    private var p: TeamPalette { TeamPalette(appState) }
    private var sections: [TeamMapSection] { appState.teamSections }

    /// Tiles with any in-flight panel drag applied.
    private var tiles: [TeamMapTile] {
        var positions = appState.teamMap.positions
        if let d = panelDrag {
            positions[d.key] = CanvasPoint(x: d.origin.x + d.offset.width / view.scale, y: d.origin.y + d.offset.height / view.scale)
        }
        return TeamMapLogic.layout(sections, positions: positions)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(p.border).frame(height: 1)
            ZStack(alignment: .bottom) {
                canvas
                composer.padding(.bottom, 20).padding(.horizontal, 16)
            }
        }
        .background(p.bg)
        .sheet(isPresented: $creating) {
            NewDepartmentSheet(appState: appState) { creating = false }
        }
        .sheet(isPresented: $importing) {
            ImportTeamSheet(appState: appState) { importing = false }
        }
        .sheet(item: Binding(get: { renaming.map { Named(name: $0) } }, set: { renaming = $0?.name })) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename \(item.name)").font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
                TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).onSubmit { rename(item.name) }
                if !sheetError.isEmpty { Text(sheetError).font(.system(size: 12)).foregroundColor(p.muted) }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save") { rename(item.name) }.buttonStyle(.borderedProminent)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24).frame(width: 380).background(p.bg)
        }
        .sheet(item: $editingMemory) { item in
            DepartmentMemorySheet(appState: appState, department: item.name) { editingMemory = nil }
        }
        .sheet(item: $editingInstructions) { item in
            DepartmentInstructionsSheet(appState: appState, department: item.name) { editingInstructions = nil }
        }
        .sheet(item: $editingCharge) { item in
            AlsoInChargeSheet(appState: appState, leadId: item.name) { editingCharge = nil }
        }
        .confirmationDialog(pendingMove.map { "Move \($0.agent.name) to \(appState.departmentLabel($0.dept))?" } ?? "",
                            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible) {
            Button("Move") {
                if let m = pendingMove { appState.moveAgent(m.agent.id, toDepartment: m.dept); announcement = "Moved \(m.agent.name)." }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { Text("The agent keeps its settings and chats; only the department changes.") }
        .confirmationDialog(deleting.map { "Delete \($0)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete department", role: .destructive) { if let d = deleting { appState.deleteDepartment(d) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its agents are kept and move to General. Its shared instructions and notes are deleted.") }
    }

    private func rename(_ old: String) {
        if appState.renameDepartment(old, to: renameText) { renaming = nil } else { sheetError = "That name is taken or empty." }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "person.3").foregroundColor(p.muted)
                    Text("Team map").font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
                    Text(TeamMapLogic.agentCountLabel(appState.agents.count)).font(.system(size: 11)).foregroundColor(p.muted)
                }
                Text("Your agents, their departments, and how they work together. Tag a department with @ to give it a job.")
                    .font(.system(size: 12)).foregroundColor(p.muted)
            }
            Spacer()
            Button { showUsage.toggle() } label: { Image(systemName: "chart.bar").font(.system(size: 14)) }
                .buttonStyle(.hitTestable).foregroundColor(p.muted).padding(8)
                .accessibilityLabel("Usage by department")
                .popover(isPresented: $showUsage, arrowEdge: .bottom) { usageList }
            Button { importing = true } label: {
                Label("Import…", systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.hitTestable).foregroundColor(p.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).stroke(p.border))
            Button { sheetError = ""; creating = true } label: {
                Label("New department", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.hitTestable).foregroundColor(p.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).stroke(p.border))
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var usageList: some View {
        let rows = appState.departmentUsage(days: usageDays)
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage by department").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $usageDays) {
                    Text("7 days").tag(7); Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.name).foregroundColor(row.filed ? p.text : p.muted).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(row.runs) repl\(row.runs == 1 ? "y" : "ies") · \(TokenAccounting.grouped(row.tokens)) tokens")
                            .foregroundColor(p.muted).monospacedDigit().lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 12))
                    GeometryReader { g in
                        Capsule().fill(p.accent.opacity(0.7)).frame(width: max(row.tokens == 0 ? 0 : 3, g.size.width * CGFloat(row.tokens) / CGFloat(total)))
                    }.frame(height: 4)
                }
            }
            Text("Counted in the department an agent was in when it answered, so moving an agent never rewrites its past. Work an agent hands to a teammate is billed inside that teammate's own run and is not counted here.")
                .font(.system(size: 11)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 400)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dotGrid
                ZStack(alignment: .topLeading) {
                    ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                        if index < tiles.count {
                            let tile = tiles[index]
                            panel(section, tile: tile)
                            ForEach(section.allAgents) { agent in
                                if let o = TeamMapLogic.cardOrigins(section, in: tile)[agent.id] {
                                    card(agent).offset(x: o.x, y: o.y)
                                }
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No agents yet.").foregroundColor(p.muted).offset(x: 40, y: 40)
                    }
                }
                .frame(width: 1, height: 1, alignment: .topLeading)
                .scaleEffect(view.scale, anchor: .topLeading)
                .offset(x: view.x, y: view.y)

                if let d = agentDrag {
                    HStack(spacing: 8) { avatar(d.agent, size: 24); Text(d.agent.name).font(.system(size: 13)) }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.accent.opacity(0.5)))
                        .offset(x: d.location.x + 14, y: d.location.y + 14)
                        .allowsHitTesting(false)
                }
                zoomControls(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                let start = panStart ?? view
                panStart = start
                view.x = start.x + g.translation.width
                view.y = start.y + g.translation.height
            }.onEnded { _ in panStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { g in
                let base = zoomStart ?? view.scale
                zoomStart = base
                setScale(base * g.magnification, around: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
            }.onEnded { _ in zoomStart = nil })
            .background(ScrollWheelCatcher { dx, dy, zoom, point in
                if zoom { setScale(view.scale * exp(-dy * 0.006), around: point) }
                else { view.x += dx; view.y += dy }
            })
            .clipped()
            .onAppear { canvasSize = geo.size; fitIfNeeded() }
            .onChange(of: geo.size) { _, new in canvasSize = new; if !didFit { fitIfNeeded() } }
            .onChange(of: tiles.map { [$0.width, $0.height] }) { _, _ in fit() }
        }
    }

    private var dotGrid: some View {
        Canvas { ctx, size in
            let step = max(8, 24 * view.scale)
            var x = view.x.truncatingRemainder(dividingBy: step)
            while x < size.width {
                var y = view.y.truncatingRemainder(dividingBy: step)
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(p.muted.opacity(0.35)))
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }

    private func zoomControls(_ size: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { setScale(view.scale / 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
            Button { fit() } label: { Text("\(Int((view.scale * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(minWidth: 40) }
                .help("Fit everything").accessibilityLabel("Fit")
            Button { setScale(view.scale * 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.hitTestable).foregroundColor(p.muted).padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(20)
    }

    // MARK: Panels and cards

    private func panel(_ section: TeamMapSection, tile: TeamMapTile) -> some View {
        let dropping = agentDrag.map { d in
            TeamMapLogic.department(at: world(d.location), tiles: tiles) == section.key && appState.department(of: d.agent.id) != section.key
        } ?? false
        let hasBrief = appState.departmentInstructions(section.key) != nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(p.card.opacity(0.9))
            RoundedRectangle(cornerRadius: 16).stroke(dropping ? p.accent : p.border, lineWidth: dropping ? 2 : 1)
            HStack(spacing: 8) {
                Text(section.name).font(.system(size: 13, weight: .semibold)).foregroundColor(p.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: TeamMapLogic.headerHeight)
                    .contentShape(Rectangle())
                    .help("Drag to rearrange")
                    .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(space)).onChanged { g in
                        let origin = panelDrag?.origin ?? CanvasPoint(x: tile.x, y: tile.y)
                        panelDrag = (section.key, origin, g.translation)
                    }.onEnded { g in
                        if let d = panelDrag {
                            appState.setDepartmentPosition(d.key, CanvasPoint(x: d.origin.x + g.translation.width / view.scale,
                                                                              y: d.origin.y + g.translation.height / view.scale))
                        }
                        panelDrag = nil
                    })
                Text("\(section.count)").font(.system(size: 11)).monospacedDigit().foregroundColor(p.muted)
                if hasBrief {
                    Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundColor(p.muted)
                        .help("This department has shared instructions")
                }
                panelMenu(section)
            }
            .padding(.horizontal, 20)
            if section.count == 0 {
                Text("Drag an agent here")
                    .font(.system(size: 12)).foregroundColor(p.muted)
                    .frame(width: TeamMapLogic.cardWidth, height: TeamMapLogic.cardHeight)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundColor(p.border))
                    .offset(x: TeamMapLogic.padding, y: TeamMapLogic.headerHeight)
            }
        }
        .frame(width: tile.width, height: tile.height)
        .offset(x: tile.x, y: tile.y)
    }

    private func panelMenu(_ section: TeamMapSection) -> some View {
        let pending = appState.pendingFactCount(section.key)
        let others = appState.agents.filter { appState.department(of: $0.id) != section.key }
        return Menu {
            Button(appState.departmentInstructions(section.key) == nil ? "Shared instructions…" : "Shared instructions… (set)") {
                editingInstructions = Named(name: section.key)
            }
            Button(pending > 0 ? "Shared memory… (\(pending) to review)" : "Shared memory…") { editingMemory = Named(name: section.key) }
            if !section.key.isEmpty {
                Menu("Add agent") {
                    ForEach(others) { agent in
                        Button("\(agent.name) (from \(appState.departmentLabel(appState.department(of: agent.id))))") {
                            appState.moveAgent(agent.id, toDepartment: section.key)
                        }
                    }
                }.disabled(others.isEmpty)
            }
            Divider()
            Button("Rename") { renameText = section.name; sheetError = ""; renaming = section.key }.disabled(section.key.isEmpty)
            Button("Delete department", role: .destructive) { deleting = section.key }.disabled(section.key.isEmpty)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    // An agent suggested a note: the person has something to review.
                    if pending > 0 { Circle().fill(p.accent).frame(width: 7, height: 7).offset(x: -3, y: 4) }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundColor(p.muted)
        .accessibilityLabel("Manage \(section.name)")
    }

    private func avatar(_ agent: Agent, size: CGFloat) -> some View {
        Image(systemName: agent.avatar).font(.system(size: size * 0.45)).foregroundColor(.white)
            .frame(width: size, height: size).background(Color(hex: agent.color)).clipShape(Circle())
    }

    private func card(_ agent: Agent) -> some View {
        let tagged = TeamMapLogic.targets(text: draft, agents: appState.agents, state: appState.teamMap).agentIds.contains(agent.id)
        let isDragging = agentDrag?.agent.id == agent.id
        let dept = appState.department(of: agent.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                avatar(agent, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.system(size: 14, weight: .semibold)).foregroundColor(p.text).lineLimit(1)
                        if agent.isLeadAgent { Image(systemName: "crown.fill").font(.system(size: 10)).foregroundColor(p.accent).help("Lead") }
                    }
                    Text(agent.role).font(.system(size: 11)).foregroundColor(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 82)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(space)).onChanged { g in
                agentDrag = (agent, g.location)
            }.onEnded { g in finishAgentDrag(agent, at: g.location) })
            Rectangle().fill(p.border).frame(height: 1)
            HStack(spacing: 4) {
                Button { appState.createNewSession(agentId: agent.id) } label: { Image(systemName: "bubble.left").font(.system(size: 12)).frame(width: 30, height: 30) }
                    .buttonStyle(.hitTestable).foregroundColor(p.muted).help("Open a chat with \(agent.name)")
                    .accessibilityLabel("Open chat with \(agent.name)")
                Spacer(minLength: 0)
                cardMenu(agent, dept: dept)
            }
            .padding(.horizontal, 8).frame(height: 43)
        }
        .frame(width: TeamMapLogic.cardWidth, height: TeamMapLogic.cardHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tagged ? p.accent : p.border, lineWidth: tagged ? 2 : 1))
        .opacity(isDragging ? 0.35 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.name), \(agent.role)")
    }

    private func cardMenu(_ agent: Agent, dept: String) -> some View {
        Menu {
            Button(agent.isLeadAgent ? "Remove as lead" : "Make lead") { appState.setLead(agent.id, !agent.isLeadAgent) }
            if agent.isLeadAgent {
                Button("Also in charge of…") { editingCharge = Named(name: agent.id) }
            }
            Menu("Move to") {
                ForEach(appState.teamSections.filter { $0.key != dept }) { s in
                    Button(s.name) { appState.moveAgent(agent.id, toDepartment: s.key) }
                }
                if dept != "" && !appState.teamSections.contains(where: { $0.key.isEmpty }) {
                    Button("General") { appState.moveAgent(agent.id, toDepartment: "") }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "ellipsis.circle").font(.system(size: 11))
                Text(agent.isLeadAgent ? "Lead" : "Member").font(.system(size: 10))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundColor(p.muted)
        .accessibilityLabel("Options for \(agent.name)")
    }

    // MARK: Drag handling

    private func world(_ pt: CGPoint) -> CanvasPoint {
        CanvasPoint(x: (pt.x - view.x) / view.scale, y: (pt.y - view.y) / view.scale)
    }

    private func finishAgentDrag(_ agent: Agent, at location: CGPoint) {
        defer { agentDrag = nil }
        let pt = world(location)
        let current = tiles
        guard let dest = TeamMapLogic.department(at: pt, tiles: current) else { return }
        if dest == appState.department(of: agent.id) {
            guard let i = sections.firstIndex(where: { $0.key == dest }) else { return }
            let index = TeamMapLogic.insertionIndex(of: agent, in: sections[i], tile: current[i], y: pt.y)
            appState.arrangeAgent(agent.id, toIndex: index)
            announcement = "Arranged \(agent.name) in \(sections[i].name)."
        } else {
            pendingMove = (agent, dest)
        }
    }

    // MARK: View transform

    private func setScale(_ next: Double, around pt: CGPoint) {
        view = TeamMapLogic.zoom(view, to: next, around: CanvasPoint(x: pt.x, y: pt.y))
    }

    private func fit() {
        view = TeamMapLogic.fit(tiles, width: canvasSize.width, height: max(200, canvasSize.height - 96))
    }

    private func fitIfNeeded() {
        guard canvasSize.width > 100, !didFit else { return }
        didFit = true
        fit()
    }

    // MARK: Composer

    private var composer: some View {
        let targets = TeamMapLogic.targets(text: draft, agents: appState.agents, state: appState.teamMap)
        let recipients = TeamMapLogic.recipients(for: targets, agents: appState.agents, state: appState.teamMap)
        let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty && !recipients.isEmpty && !appState.isGenerating
        let mention = currentMention
        return VStack(spacing: 6) {
            if let m = mention, !mentionChoices(m).isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(mentionChoices(m), id: \.self) { name in
                        Button { insertMention(name) } label: {
                            Text("@\(name)").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                        }.buttonStyle(.hitTestable)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message your team: tag an agent with @, a department, or @everyone", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).font(.system(size: 15))
                    .foregroundColor(p.text)
                    .onSubmit { send() }
                    .accessibilityLabel("Team message")
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? p.accent : p.muted.opacity(0.4)))
                }
                .buttonStyle(.hitTestable).disabled(!canSend).accessibilityLabel("Send")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.border))
            if let hint = composerHint(targets, recipients: recipients) {
                Text(hint).font(.system(size: 11)).foregroundColor(p.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: 620)
        .opacity(appState.agents.isEmpty ? 0 : 1)
        .allowsHitTesting(!appState.agents.isEmpty)
    }

    private func composerHint(_ t: TeamMapTargets, recipients: [TeamMapRecipient]) -> String? {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty && t.isEmpty { return "Tag an agent, a department or @everyone to send." }
        if !t.isEmpty && recipients.isEmpty { return "Nobody is in that department yet." }
        let names = recipients.compactMap { r in appState.agents.first { $0.id == r.agentId }?.name }
        guard let first = recipients.first, let name = names.first else { return nil }
        switch first.reason {
        case .departmentLead(let dept): return "Goes to \(name), who leads \(dept) and hands the work to the team."
        case .everyoneLead: return "Goes to \(name), who passes it on."
        default: return names.count == 1 ? "Will send to \(name)." : "Will send to \(names.count) agents, one after another."
        }
    }

    /// The `@word` being typed at the end of the draft, if any.
    private var currentMention: String? {
        guard let at = draft.lastIndex(where: { $0 == "@" || $0 == "＠" }) else { return nil }
        if at != draft.startIndex, let before = draft[..<at].last, before.isLetter || before.isNumber { return nil }
        let tail = String(draft[draft.index(after: at)...])
        return tail.contains("\n") ? nil : tail
    }

    private func mentionChoices(_ query: String) -> [String] {
        var pool = appState.agents.map(\.name)
        pool += sections.filter { !$0.key.isEmpty }.map(\.name)
        if appState.agents.count > 1 { pool.insert("everyone", at: 0) }
        let q = query.lowercased()
        return Array(pool.filter { q.isEmpty || $0.lowercased().hasPrefix(q) }.filter { $0.lowercased() != q }.prefix(6))
    }

    private func insertMention(_ name: String) {
        if let at = draft.lastIndex(where: { $0 == "@" || $0 == "＠" }) { draft = String(draft[..<at]) + "@\(name) " }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        appState.sendFromTeamMap(text)
    }

    private struct Named: Identifiable { let name: String; var id: String { name } }
}

/// Two-finger scroll pans the canvas; pinch or ⌘-scroll zooms about the pointer.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (_ dx: Double, _ dy: Double, _ zoom: Bool, _ point: CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? CatcherView)?.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double, Double, Bool, CGPoint) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let pt = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(pt) else { return event }
                let zoom = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
                self.onScroll?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), zoom, CGPoint(x: pt.x, y: self.bounds.height - pt.y))
                return nil
            }
        }
    }
}

/// Makes a department: empty, or from a starting line-up (a lead and the specialists it delegates to).
struct NewDepartmentSheet: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void

    @State private var name = ""
    /// nil is an empty department; otherwise a template id.
    @State private var templateId: String? = DepartmentTemplateCatalog.softwareTeam.id
    @State private var error = ""

    private var p: TeamPalette { TeamPalette(appState) }
    private var template: DepartmentTemplate? { templateId.flatMap(DepartmentTemplateCatalog.template(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New department").font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
            TextField("Name, e.g. App-Coder", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
                .accessibilityLabel("Department name")
            Text("Start from").font(.system(size: 12, weight: .semibold)).foregroundColor(p.muted)
            VStack(alignment: .leading, spacing: 6) {
                choice(id: nil, title: "Empty department", summary: "Add agents yourself, from the Team map or the Agents page.", icon: "square.dashed")
                ForEach(DepartmentTemplateCatalog.all) { t in choice(id: t.id, title: t.title, summary: t.summary, icon: t.icon) }
            }
            if let template {
                Text("Creates \(template.members.count) agents: " + template.members.map { $0.isLead ? "\($0.role) (lead)" : $0.role }.joined(separator: ", ") + ". You can edit or replace them afterwards.")
                    .font(.system(size: 11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Create", action: create).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(p.bg)
    }

    private func choice(id: String?, title: String, summary: String, icon: String) -> some View {
        Button { templateId = id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: templateId == id ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(templateId == id ? p.accent : p.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(p.text)
                    Text(summary).font(.system(size: 11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(templateId == id ? p.accent.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.hitTestable)
        .accessibilityLabel(title)
    }

    private func create() {
        let ok: Bool
        if let template {
            ok = !appState.createDepartment(from: template, named: name).isEmpty
        } else {
            ok = appState.createDepartment(name)
        }
        if ok { onClose() } else { error = "That name is empty or already used by a department or an agent." }
    }
}

/// The departments a lead answers for besides its own.
struct AlsoInChargeSheet: View {
    @ObservedObject var appState: AppState
    let leadId: String
    let onClose: () -> Void

    @State private var chosen: Set<String> = []
    @State private var loaded = false

    private var p: TeamPalette { TeamPalette(appState) }
    private var lead: Agent? { appState.agents.first { $0.id == leadId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(lead?.name ?? "Lead"): also in charge of").font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
            Text("A lead always answers for its own department, and its members are its team. Tick more departments to put their members on its team too.")
                .font(.system(size: 12.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
            let own = appState.department(of: leadId)
            ForEach(appState.teamSections.filter { $0.key != own }) { s in
                Toggle(s.name, isOn: Binding(get: { chosen.contains(s.key) }, set: { on in
                    if on { chosen.insert(s.key) } else { chosen.remove(s.key) }
                }))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { appState.setManagedDepartments(leadId, Array(chosen)); onClose() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 400).background(p.bg)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chosen = Set(appState.teamMap.managed[leadId] ?? [])
        }
    }
}

/// Import a team or bot from OpenMausBot or botteams: a file link, a GitHub repository to browse, or pasted text.
/// The person sees what it adds before anything is created.
struct ImportTeamSheet: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void

    @State private var source = ""
    @State private var preview: ExternalTeam?
    @State private var library: [GitHubSource.Listing] = []
    @State private var status = ""
    @State private var working = false

    private var p: TeamPalette { TeamPalette(appState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a team").font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
            Text("Paste a link to an OpenMausBot or botteams file, a GitHub repository to browse, or the file's text. You see what it adds before anything is created.")
                .font(.system(size: 12)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $source).font(.system(size: 12, design: .monospaced)).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                .accessibilityLabel("Team link or text")
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundColor(p.muted) }
            if !library.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(library) { item in
                            HStack {
                                Text(item.name).font(.system(size: 13)).foregroundColor(p.text)
                                Spacer()
                                Button("Review…") { source = item.url.absoluteString; library = []; load() }
                            }
                        }
                    }
                }.frame(maxHeight: 200)
            }
            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.name).font(.system(size: 13, weight: .semibold)).foregroundColor(p.text)
                    if !preview.summary.isEmpty { Text(preview.summary).font(.system(size: 12)).foregroundColor(p.muted) }
                    Text(preview.members.map { $0.isLead ? "\($0.name) (lead)" : $0.name }.joined(separator: ", ")).font(.system(size: 12)).foregroundColor(p.text)
                    Text(preview.members.count > 1 ? "Creates \(preview.members.count) agents and a department called “\(preview.name)”." : "Creates 1 agent.")
                        .font(.system(size: 11.5)).foregroundColor(p.muted)
                    if !preview.connectors.isEmpty {
                        Text("Works best with: " + preview.connectors.joined(separator: ", ") + ". Nothing is connected for you.").font(.system(size: 11.5)).foregroundColor(p.muted)
                    }
                    if preview.routineCount > 0 {
                        Text("\(preview.routineCount) scheduled routine\(preview.routineCount == 1 ? "" : "s") in the file will not be imported.").font(.system(size: 11.5)).foregroundColor(p.muted)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                if let preview {
                    Button("Import") { _ = appState.importExternalTeam(preview); onClose() }.buttonStyle(.borderedProminent)
                } else {
                    Button(working ? "Working…" : "Preview", action: load).buttonStyle(.borderedProminent)
                        .disabled(working || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 520).background(p.bg)
    }

    private func load() {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = nil; library = []; status = ""
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                if text.hasPrefix("https://"), !text.contains(where: \.isWhitespace), let url = URL(string: text) {
                    if GitHubSource.isRepoLink(url) { library = try await GitHubSource.listing(for: url); return }
                    preview = ExternalTeamImport.convert(markdown: try await ExternalTeamImport.download(url))
                } else {
                    preview = ExternalTeamImport.convert(markdown: text)
                }
                if preview == nil { status = "That is not an OpenMausBot or botteams team." }
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
