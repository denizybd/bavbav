import AppKit
import BavbavCore
import SwiftUI

struct ProjectPanelView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore

    var body: some View {
        PanelShell(
            index: "01",
            title: title,
            subtitle: subtitle,
            connection: store.connection,
            isReordering: store.leftIsReordering
        ) {
            VStack(spacing: 8) {
                if store.renameTarget?.panel == .projects { RenameSlot(store: store) }
                switch store.leftRoute {
                case .projects:
                    projectList
                case .chats:
                    chatList
                }
            }
        } footer: {
            footer
        }
    }

    private var title: String {
        switch store.leftRoute {
        case .projects: return "PROJECTS"
        case .chats: return "PROJECT / CHATS"
        }
    }

    private var subtitle: String {
        switch store.leftRoute {
        case .projects:
            return "\(store.projects.count) WORKSPACES"
        case .chats(let project):
            return project.name.uppercased()
        }
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if store.leftCreationTarget == .project {
                        LeftCreationSlot(store: store, label: "NEW PROJECT")
                    }
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(
                            number: index + 1,
                            project: project,
                            selected: store.leftInteraction.selectedID == project.id,
                            moving: store.leftIsReordering && store.leftInteraction.selectedID == project.id
                        )
                        .id(project.id)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectLeft(id: project.id) }
                    }
                }
            }
            .onChange(of: store.leftInteraction.selectedID) { id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if case .chat = store.leftCreationTarget {
                        LeftCreationSlot(store: store, label: "NEW CHAT")
                    }
                    if store.projectChats.isEmpty {
                        EmptyState(text: "No saved chats in this project")
                    }
                    ForEach(Array(store.projectChats.enumerated()), id: \.element.id) { index, chat in
                        ThreadRow(
                            number: index + 1,
                            thread: chat,
                            selected: store.leftInteraction.selectedID == chat.id,
                            moving: store.leftIsReordering && store.leftInteraction.selectedID == chat.id
                        )
                        .id(chat.id)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectLeft(id: chat.id) }
                    }
                }
            }
            .onChange(of: store.leftInteraction.selectedID) { id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if store.renameTarget?.panel == .projects {
            RenameLegend(store: store)
        } else if store.leftIsReordering {
            KeyLegend(items: shortcuts.list(store.leftRoute == .projects ? "projects.root" : "projects.chats", moving: true), accent: BavbavTheme.warning)
        } else {
            switch store.leftRoute {
            case .projects:
                KeyLegend(items: shortcuts.list("projects.root", create: true))
            case .chats:
                KeyLegend(items: shortcuts.list("projects.chats", create: true))
            }
        }
    }
}

private struct LeftCreationSlot: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore
    let label: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("+")
                    .font(BavbavTheme.mono(13, weight: .bold))
                    .foregroundStyle(BavbavTheme.warning).readableForeground()
                TextField(label, text: $store.leftCreationName)
                    .textFieldStyle(.plain)
                    .font(BavbavTheme.mono(11, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                    .focused($focused)
                    .onSubmit { store.commitLeftCreation() }
                if store.leftCreationSubmitting {
                    ProgressView().controlSize(.small).tint(BavbavTheme.warning)
                }
            }
            if let error = store.leftCreationError {
                Text(error.uppercased())
                    .font(BavbavTheme.mono(7, weight: .bold))
                    .foregroundStyle(BavbavTheme.warning).readableForeground()
                    .lineLimit(2)
            } else {
                Text("\(shortcuts.key("create.\(store.leftCreationTarget == .project ? "project" : "chat").\(store.leftCreationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "full").commitCreation.key")) \(store.leftCreationName.isEmpty ? "CANCEL" : "CREATE")")
                    .font(BavbavTheme.mono(7, weight: .bold))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(BavbavTheme.raised.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(BavbavTheme.warning.opacity(0.7), lineWidth: 1)
        }
        .onAppear { focused = true }
        .onChange(of: store.leftCreationFocusToken) { _ in focused = true }
    }
}

struct RecentsPanelView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore

    var body: some View {
        PanelShell(
            index: "02",
            title: "RECENT SIGNALS",
            subtitle: "LAST 8 CHATS",
            connection: store.connection,
            isReordering: store.recentIsReordering
        ) {
            VStack(spacing: 8) {
                if store.renameTarget?.panel == .recents { RenameSlot(store: store) }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            if store.recentChats.isEmpty {
                                EmptyState(text: "No recent conversations yet")
                            }
                            ForEach(Array(store.recentChats.enumerated()), id: \.element.id) { index, chat in
                                ThreadRow(
                                    number: index + 1,
                                    thread: chat,
                                    selected: store.recentInteraction.selectedID == chat.id,
                                    moving: store.recentIsReordering && store.recentInteraction.selectedID == chat.id
                                )
                                .id(chat.id)
                                .contentShape(Rectangle())
                                .onTapGesture { store.selectRecent(id: chat.id) }
                            }
                        }
                    }
                    .onChange(of: store.recentInteraction.selectedID) { id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        } footer: {
            if store.renameTarget?.panel == .recents {
                RenameLegend(store: store)
            } else if store.recentIsReordering {
                KeyLegend(items: shortcuts.list("recents.list", moving: true), accent: BavbavTheme.warning)
            } else {
                KeyLegend(items: shortcuts.list("recents.list"))
            }
        }
    }
}

struct ChatGPTPanelView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore
    var body: some View { microPanel }

    private var microPanel: some View {
        PanelShell(
            index: "03",
            title: "CHAT",
            subtitle: store.standaloneCreating ? "OPENING" : "STANDALONE · CODEX",
            connection: .channel("ChatGPT"),
            isReordering: store.chatGPTIsReordering
        ) {
            VStack(spacing: 8) {
                if store.renameTarget?.panel == .chatgpt { RenameSlot(store: store) }
                chatMenu
            }
        } footer: {
            if store.renameTarget?.panel == .chatgpt {
                RenameLegend(store: store)
            } else {
                KeyLegend(items: shortcuts.list(store.chatGPTInteraction.selectedID == OverlayStore.chatGPTLauncherID ? "standalone.launcher" : "standalone.list", moving: store.chatGPTIsReordering))
            }
        }
    }

    private var chatMenu: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ChatGPTLauncherRow(
                        selected: store.chatGPTInteraction.selectedID == OverlayStore.chatGPTLauncherID
                    )
                    .id(OverlayStore.chatGPTLauncherID)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectChatGPT(id: OverlayStore.chatGPTLauncherID) }
                    ForEach(store.standaloneChats) { chat in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(BavbavTheme.cyan.opacity(0.7)).frame(width: 9, height: 9)
                            Text(chat.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(BavbavTheme.mono(11))
                        .foregroundStyle(BavbavTheme.text).readableForeground()
                        .padding(.horizontal, 12).frame(height: 38)
                        .background((store.chatGPTInteraction.selectedID == chat.id ? BavbavTheme.raised : .clear).panelBackdrop())
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .id(chat.id)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectChatGPT(id: chat.id) }
                    }
                    if store.standaloneChats.isEmpty {
                        Text("Choose CHAT to start a standalone conversation.")
                            .font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted).readableForeground().padding(10)
                    }
                    if let error = store.standaloneError {
                        Text(error).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning)
                            .readableForeground().padding(10)
                    }
                }
            }
            .onChange(of: store.chatGPTInteraction.selectedID) { id in
                if let id {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

/// The native hosting view and transcript survive focus changes. Only Q-close
/// releases this presentation; inactive chats retain a lightweight snapshot.
@MainActor
final class ChatWindowPresentation: ObservableObject {
    @Published var snapshot: ChatWindowSnapshot
    @Published var isActive = false
    let scroll = ChatScrollController()

    init(snapshot: ChatWindowSnapshot) { self.snapshot = snapshot }
}

struct ChatWindowRoot: View {
    let store: OverlayStore
    @ObservedObject var presentation: ChatWindowPresentation

    var body: some View {
        ChatDetailView(store: store, host: .centered,
                       snapshot: presentation.isActive ? nil : presentation.snapshot,
                       scrollController: presentation.scroll, windowThread: presentation.snapshot.thread)
    }
}

struct ChatDetailView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @Environment(\.panelBackdropOpacity) private var backdropOpacity
    @State private var dropHover = false
    @State private var searchVisible = false
    @State private var searchQuery = ""
    @State private var searchIndex = 0
    @State private var windowNumber: Int?
    @State private var transcriptCopied = false
    @State private var searchFocusToken = 0
    private var commandScope: String {
        if !isLiveWindow { return "chat.read" }
        if store.interactionTextVisible { return "interaction.write" }
        if store.composerVisible { return composerScope }
        if store.activeInteraction != nil { return "interaction.list" }
        return store.queueModeVisible ? "queue.list" + (store.queueIsReordering ? ".moving" : "") : "chat.read"
    }
    private var composerScope: String {
        "chat.write." + (store.composerHasPayload ? "full" : "empty")
    }
    @ObservedObject var store: OverlayStore
    let host: ChatDetailHost
    var snapshot: ChatWindowSnapshot? = nil
    var scrollController: ChatScrollController? = nil
    var windowThread: CodexThread? = nil
    private var isLiveWindow: Bool {
        snapshot == nil && (windowThread == nil || windowThread?.id == store.detailThread?.id)
    }
    private var displayedSnapshot: ChatWindowSnapshot? {
        if let snapshot { return snapshot }
        guard !isLiveWindow, let windowThread else { return nil }
        return store.onDetailSnapshotRequested?(windowThread.id)
    }
    private var displayedThread: CodexThread? { displayedSnapshot?.thread ?? windowThread ?? store.detailThread }
    private var displayedItems: [CodexMessage] {
        store.offlineItems(displayedSnapshot?.items ?? (isLiveWindow ? store.visibleDetailItems : []), threadID: displayedThread?.id)
    }
    private var displayedLoading: Bool { displayedSnapshot?.loading ?? (isLiveWindow && store.visibleDetailLoading) }
    private var displayedCommands: Bool { displayedSnapshot?.showsActivity ?? (isLiveWindow && store.detailShowsActivity) }
    private var displayedError: String? { isLiveWindow ? store.composerError : displayedSnapshot?.error }
    private var displayedRunState: ChatRunDisplayState { displayedThread.map { store.runState(for: $0.id) } ?? .idle }
    private var searchMatchIDs: [String] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchVisible, !query.isEmpty else { return [] }
        return displayedItems.filter { $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
    }
    private var focusedSearchID: String? {
        let matches = searchMatchIDs
        return matches.indices.contains(searchIndex) ? matches[searchIndex] : nil
    }

    var body: some View {
        AttachmentDropRegion(isEnabled: displayedThread != nil, onHoverChanged: { dropHover = $0 }, onDrop: { board in
            guard let thread = displayedThread else { return false }
            return store.importComposerPasteboard(board, for: thread)
        }) {
            chatSurface.environment(\.panelBackdropOpacity, backdropOpacity).environment(\.shortcutLabels, shortcuts)
                .environment(\.messageDirectory, displayedThread?.cwd)
                .environment(\.messageCommandsVisible, displayedCommands)
        }
        .overlay {
            if dropHover {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(BavbavTheme.background.opacity(0.92))
                    RoundedRectangle(cornerRadius: 10).strokeBorder(BavbavTheme.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 28, weight: .light))
                        Text("Attach to this chat").font(BavbavTheme.mono(13, weight: .semibold))
                        Text("Images · documents · screenshots").font(BavbavTheme.mono(9))
                        Text("Drop to preview in your draft before sending.").font(BavbavTheme.mono(8))
                    }.foregroundStyle(BavbavTheme.accent)
                }.allowsHitTesting(false)
            }
        }
        .background(ChatWindowNumberProbe { windowNumber = $0 })
        .onReceive(NotificationCenter.default.publisher(for: .chatFindInConversation)) { notification in
            guard let target = notification.object as? NSWindow, target.windowNumber == windowNumber else { return }
            showSearch()
        }
        .onChange(of: searchQuery) { _ in searchIndex = 0 }
        .onChange(of: searchMatchIDs) { matches in
            searchIndex = min(searchIndex, max(0, matches.count - 1))
        }
        .onChange(of: displayedItems.last) { _ in transcriptCopied = false }
    }

    private var chatSurface: some View {
        GeometryReader { geometry in
        ZStack {
            BavbavTheme.background.panelBackdrop()
            VStack(spacing: 0) {
                detailHeader
                Divider().overlay(BavbavTheme.border)
                if searchVisible {
                    searchBar
                    Divider().overlay(BavbavTheme.border)
                }
                if store.renameTarget?.panel == .detail, store.renameTarget?.id == displayedThread?.id {
                    VStack(spacing: 8) {
                        RenameSlot(store: store)
                        HStack {
                            RenameLegend(store: store)
                            Spacer()
                            Button("Vazgeç") { store.cancelRename() }.disabled(store.renameSubmitting)
                            Button("Kaydet") { store.commitRename() }.disabled(store.renameSubmitting)
                        }.font(BavbavTheme.mono(9))
                    }.padding(12)
                    Divider().overlay(BavbavTheme.border)
                }
                if let id = displayedThread?.id, let error = store.sideChatError(for: id) {
                    Text(error)
                        .font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning).readableForeground()
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider().overlay(BavbavTheme.border)
                }
                messageArea
                if interactionPresented, let request = store.activeInteraction {
                    Divider().overlay(BavbavTheme.warning.opacity(0.55))
                    InteractionCard(store: store, request: request)
                }
                if let error = displayedError {
                    Divider().overlay(BavbavTheme.border)
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(BavbavTheme.warning)
                            .frame(width: 7, height: 7)
                        Text(error)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(BavbavTheme.mono(9, weight: .medium))
                    .foregroundStyle(BavbavTheme.warning).readableForeground()
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(BavbavTheme.surface.panelBackdrop())
                }
                if isLiveWindow, store.queueModeVisible, store.detailHost == host {
                    Divider().overlay(BavbavTheme.border)
                    queueManager
                } else if isLiveWindow, store.currentQueueCount > 0, store.detailHost == host {
                    Divider().overlay(BavbavTheme.border)
                    queueHint
                }
                if isLiveWindow, store.composerVisible, store.detailHost == host {
                    Divider().overlay(BavbavTheme.border)
                    ChatComposerView(store: store, menuHeight: max(96, geometry.size.height - 180))
                        .layoutPriority(1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BavbavTheme.border, lineWidth: 1)
        }
        }
    }

    private var interactionPresented: Bool {
        guard isLiveWindow else { return false }
        switch host {
        case .centered: return store.detailHost == .centered
        case .dock: return store.detailHost == .dock
        }
    }

    private var queueHint: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(BavbavTheme.cyan)
                .frame(width: 7, height: 7)
            Text("QUEUE \(store.currentQueueCount)")
                .foregroundStyle(BavbavTheme.cyan).readableForeground()
            Spacer()
            Text("\(shortcuts.key("chat.read.queueToggle.key")) MANAGE")
                .foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .font(BavbavTheme.mono(8, weight: .bold))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(BavbavTheme.surface.opacity(0.82).panelBackdrop())
    }

    private var queueManager: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("QUEUE / \(store.currentQueueCount) WAITING")
                    .font(BavbavTheme.mono(9, weight: .bold))
                    .foregroundStyle(BavbavTheme.cyan).readableForeground()
                if store.queueIsReordering {
                    Text("MOVE")
                        .font(BavbavTheme.mono(7, weight: .bold))
                        .foregroundStyle(BavbavTheme.warning).readableForeground()
                }
                Spacer()
                Text(store.queueIsReordering ? "RELEASE TO SAVE" : "\(shortcuts.key("queue.list.queueToggle.key")) CLOSE")
                    .font(BavbavTheme.mono(7, weight: .bold))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
            }

            if store.currentQueuedPrompts.isEmpty {
                Text("QUEUE EMPTY")
                    .font(BavbavTheme.mono(9, weight: .medium))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(store.currentQueuedPrompts.enumerated()), id: \.element.id) { index, prompt in
                                let selected = store.queueInteraction.selectedID == prompt.id
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(selected ? (store.queueIsReordering ? BavbavTheme.warning : BavbavTheme.cyan) : .clear)
                                        .frame(width: 3, height: 28)
                                    Text(index == 0 ? "NEXT" : "\(index + 1)")
                                        .font(BavbavTheme.mono(7, weight: .bold))
                                        .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.muted).readableForeground()
                                        .frame(width: 30, alignment: .leading)
                                    Text((prompt.text.isEmpty ? prompt.attachments.map(\.name).joined(separator: ", ") : prompt.text).replacingOccurrences(of: "\n", with: " "))
                                        .font(BavbavTheme.mono(9, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.muted).readableForeground()
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if selected {
                                        Text(prompt.requiresRetry ? "RETRY · Q" : (store.queueIsReordering ? "↕" : "STEER"))
                                            .font(BavbavTheme.mono(7, weight: .bold))
                                            .foregroundStyle(store.queueIsReordering ? BavbavTheme.warning : BavbavTheme.accent).readableForeground()
                                    }
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 32)
                                .background((selected ? BavbavTheme.raised : .clear).panelBackdrop())
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .id(prompt.id)
                            }
                        }
                    }
                    .onChange(of: store.queueInteraction.selectedID) { id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            Text("\(shortcuts.key("queue.list\(store.queueIsReordering ? ".moving" : "").up.key")) ↑ · \(shortcuts.key("queue.list\(store.queueIsReordering ? ".moving" : "").down.key")) ↓ · \(shortcuts.key("queue.list.steer.key")) STEER · \(shortcuts.key("queue.list.reorder.key")) MOVE · \(shortcuts.key("queue.list\(store.queueIsReordering ? ".moving" : "").editQueued.key")) EDIT")
                .font(BavbavTheme.mono(7, weight: .bold))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(BavbavTheme.surface.opacity(0.92).panelBackdrop())
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.channelLabel(for: displayedThread))
                    .font(BavbavTheme.mono(9, weight: .semibold))
                    .foregroundStyle(displayedCommands ? BavbavTheme.warning : BavbavTheme.accent).readableForeground()
                Text(displayedThread?.title ?? "CHAT")
                    .font(BavbavTheme.mono(15, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                    .lineLimit(1)
            }
            Spacer()
            ChatRunBadge(state: displayedRunState)
            if isLiveWindow, displayedRunState == .working, let operation = store.detailOperation {
                Text(operation)
                    .font(BavbavTheme.mono(8, weight: .light))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }
            Text("\(shortcuts.key(commandScope + ".commands.key")) · COMMANDS \(displayedCommands ? "ON" : "OFF")")
                .font(BavbavTheme.mono(8, weight: .bold))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
            if let thread = displayedThread {
                ActivitySquare(state: thread.state, hasMessages: thread.hasMessages)
                Text(store.isStandalone(thread) ? "STANDALONE" : URL(fileURLWithPath: thread.cwd).lastPathComponent.uppercased())
                    .font(BavbavTheme.mono(9, weight: .semibold))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                    .lineLimit(1)
                    .frame(maxWidth: 100, alignment: .trailing)
                chatMenu(for: thread)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }

    private func chatMenu(for thread: CodexThread) -> some View {
        // Native menus can remain open while an asynchronous fork activates a
        // different global detail. Copy exactly the window's captured history.
        let messages = displayedItems
        return Menu {
            Button {
                Task { await store.openSideChat(from: thread) }
            } label: { Label(store.sideChatCreatingIDs.contains(thread.id) ? "Yan sohbet açılıyor…" : "Yan sohbet aç", systemImage: "arrow.triangle.branch") }
            .disabled(store.sideChatCreatingIDs.contains(thread.id))
            Button { NotificationCenter.default.post(name: Notification.Name("Bavbav.OpenBrowser"), object: nil) }
                label: { Label("Web penceresi aç", systemImage: "globe") }
            Button { NotificationCenter.default.post(name: .bavbavOpenOfflineAI, object: thread) }
                label: { Label("Yerel AI · çevrimdışı görev devri", systemImage: "desktopcomputer") }
            Button { NotificationCenter.default.post(name: .bavbavSharedAccountChat, object: nil) }
                label: { Label("Konuşma kaynağı · Deniz / Emir / Yerel AI", systemImage: "person.2") }
            Divider()
            Button { showSearch() } label: { Label("Bu sohbette ara", systemImage: "magnifyingglass") }
            Button { store.beginRename(thread: thread) } label: { Label("Sohbet adını değiştir", systemImage: "pencil") }
                .disabled(store.renameSubmitting)
            Button { copyTranscript(messages) } label: { Label(transcriptCopied ? "Sohbet kopyalandı" : "Sohbeti kopyala", systemImage: "doc.on.doc") }
                .disabled(!messages.contains { $0.kind.isConversation })
            Button {
                store.focusDetailWindow(thread)
                store.toggleDetailActivity()
            } label: { Label(displayedCommands ? "Komut mesajlarını gizle" : "Komut mesajlarını göster", systemImage: "terminal") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BavbavTheme.text).readableForeground()
                .frame(width: 28, height: 28)
                .background(BavbavTheme.raised.panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Sohbet seçenekleri")
        .accessibilityLabel("Sohbet seçenekleri · \(thread.title)")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(BavbavTheme.accent).readableForeground()
            ChatSearchField(text: $searchQuery, focusToken: searchFocusToken) { moveSearch(1) }
                .frame(minWidth: 80, maxWidth: .infinity).frame(height: 24)
            Text(searchQuery.isEmpty ? "" : (searchMatchIDs.isEmpty ? "Sonuç yok" : "\(searchIndex + 1) / \(searchMatchIDs.count)"))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
                .accessibilityLabel("Arama sonucu sayısı")
            Button { moveSearch(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(searchMatchIDs.isEmpty).help("Önceki sonuç")
            Button { moveSearch(1) } label: { Image(systemName: "chevron.down") }
                .disabled(searchMatchIDs.isEmpty).help("Sonraki sonuç · Enter")
            Button { closeSearch() } label: { Image(systemName: "xmark") }.help("Aramayı kapat")
        }
        .buttonStyle(.plain)
        .font(BavbavTheme.mono(10))
        .foregroundStyle(BavbavTheme.text).readableForeground()
        .padding(.horizontal, 16).frame(height: 42)
        .background(BavbavTheme.surface.panelBackdrop())
    }

    private func showSearch() {
        searchVisible = true
        searchFocusToken &+= 1
    }

    private func closeSearch() {
        searchVisible = false
        searchQuery = ""
        searchIndex = 0
        if NSApp.keyWindow?.windowNumber == windowNumber { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func moveSearch(_ delta: Int) {
        guard !searchMatchIDs.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchMatchIDs.count) % searchMatchIDs.count
    }

    private func copyTranscript(_ messages: [CodexMessage]) {
        let text = messages.filter { $0.kind.isConversation }.map {
            "\($0.title ?? ($0.role == .user ? "YOU" : "CODEX"))\n\($0.text)"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        transcriptCopied = true
    }

    @ViewBuilder
    private var messageArea: some View {
        if displayedLoading && displayedItems.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(BavbavTheme.accent)
                Text("HISTORY STREAM OPENING")
                    .font(BavbavTheme.mono(10, weight: .medium))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedItems.isEmpty {
            EmptyState(text: displayedThread?.preview.isEmpty == false
                ? displayedThread?.preview ?? ""
                : "No messages to display in this chat")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChatTranscriptView(items: displayedItems, scroll: scrollController,
                               focusedMessageID: focusedSearchID, matchingMessageIDs: Set(searchMatchIDs))
                .id(displayedThread?.id)
        }
    }
}

/// A distinct native field makes search ownership observable to InputRouter.
/// Its Return must advance a result, never send an underlying composer draft.
@MainActor
struct ChatSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSubmit: () -> Void
    @Environment(\.panelBackdropOpacity) private var opacity
    private static let fields = NSHashTable<Field>.weakObjects()

    static func isEditing(in window: NSWindow?) -> Bool {
        guard let window, let responder = window.firstResponder else { return false }
        if responder is Field { return true }
        return fields.allObjects.contains { $0.window === window && $0.currentEditor() === responder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        Self.fields.add(field)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        field.textColor = ForegroundContrast.color(RichMessageRenderer.textColor,
                                                   strength: ForegroundContrast.strength(backgroundOpacity: opacity))
        field.requestedFocusToken = focusToken
        field.requestFocus()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        init(text: Binding<String>, onSubmit: @escaping () -> Void) { self.text = text; self.onSubmit = onSubmit }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }

    final class Field: NSTextField {
        var requestedFocusToken = 0
        private var appliedFocusToken: Int?
        private var focusScheduled = false
        init() {
            super.init(frame: .zero)
            isBordered = false
            drawsBackground = false
            focusRingType = .none
            font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            isEditable = true
            isSelectable = true
            usesSingleLineMode = true
            placeholderString = "Bu sohbette ara"
            setAccessibilityLabel("Bu sohbette ara")
            identifier = NSUserInterfaceItemIdentifier("bavbav.chat.search")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(requestFocus),
                                                       name: NSWindow.didBecomeKeyNotification, object: window)
                requestFocus()
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc func requestFocus() {
            guard appliedFocusToken != requestedFocusToken, !focusScheduled, window?.isKeyWindow == true else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard let window = self.window, window.isKeyWindow, window.isVisible,
                      window.makeFirstResponder(self) else { return }
                self.appliedFocusToken = self.requestedFocusToken
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}

/// Keep Cmd+F local to the originating native window; never retain NSWindow
/// from its own SwiftUI content or search all of the other open transcripts.
private struct ChatWindowNumberProbe: NSViewRepresentable {
    let changed: (Int?) -> Void
    func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed }
    final class Probe: NSView {
        var changed: (Int?) -> Void
        init(changed: @escaping (Int?) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let number = window?.windowNumber
            DispatchQueue.main.async { [weak self] in self?.changed(number) }
        }
    }
}

private struct ChatRunBadge: View {
    let state: ChatRunDisplayState

    private var label: String {
        switch state {
        case .idle: return "IDLE"
        case .working: return "WORKING"
        case .waiting: return "WAITING"
        }
    }

    private var color: Color {
        switch state {
        case .idle: return BavbavTheme.muted
        case .working: return BavbavTheme.accent
        case .waiting: return BavbavTheme.warning
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if state == .working {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
                    .scaleEffect(0.65)
                    .frame(width: 9, height: 9)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(BavbavTheme.mono(8, weight: .bold))
                .foregroundStyle(color).readableForeground()
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(BavbavTheme.raised.opacity(0.8).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.28), lineWidth: 1)
        }
    }
}


private struct InteractionCard: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore
    let request: CodexInteractionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BavbavTheme.warning)
                    .frame(width: 9, height: 9)
                    .shadow(color: BavbavTheme.warning.opacity(0.5), radius: 4)
                Text(request.title)
                    .font(BavbavTheme.mono(9, weight: .bold))
                    .foregroundStyle(BavbavTheme.warning).readableForeground()
                Spacer()
                if !request.questions.isEmpty {
                    Text("\(store.interactionQuestionIndex + 1)/\(request.questions.count)")
                        .font(BavbavTheme.mono(8, weight: .bold))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                }
            }

            Text(store.currentInteractionQuestion?.prompt ?? request.summary)
                .font(BavbavTheme.mono(10, weight: .semibold))
                .foregroundStyle(BavbavTheme.text).readableForeground()
                .lineLimit(3)

            if store.currentInteractionQuestion == nil, !request.detail.isEmpty {
                Text(request.detail)
                    .font(BavbavTheme.mono(8))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if store.interactionTextVisible {
                CompactInputField(
                    text: $store.interactionText,
                    focusToken: store.interactionFocusToken,
                    secure: store.interactionInputIsSecret,
                    onSubmit: { store.submitInteractionText() }
                )
                .id(store.interactionInputIsSecret)
                .frame(height: 30)
            } else if store.interactionResolving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(BavbavTheme.warning)
                    Text("SENDING DECISION")
                }
                .font(BavbavTheme.mono(8, weight: .bold))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(store.currentInteractionOptions.enumerated()), id: \.element.id) { index, option in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(store.interactionSelection == index ? BavbavTheme.warning : .clear)
                                .frame(width: 3, height: 20)
                            Text(option.label)
                                .font(BavbavTheme.mono(9, weight: .bold))
                                .foregroundStyle(store.interactionSelection == index ? BavbavTheme.text : BavbavTheme.muted).readableForeground()
                            if store.isInteractionOptionChosen(option.id) {
                                Text("■")
                                    .font(BavbavTheme.mono(7, weight: .bold))
                                    .foregroundStyle(BavbavTheme.accent).readableForeground()
                            }
                            if !option.detail.isEmpty {
                                Text(option.detail)
                                    .font(BavbavTheme.mono(8))
                                    .foregroundStyle(BavbavTheme.muted.opacity(0.8)).readableForeground()
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 25)
                        .background((store.interactionSelection == index ? BavbavTheme.raised : .clear).panelBackdrop())
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            if let error = store.interactionError {
                Text(error)
                    .font(BavbavTheme.mono(8, weight: .medium))
                    .foregroundStyle(BavbavTheme.danger).readableForeground()
                    .lineLimit(2)
            }

            Text(store.interactionTextVisible
                 ? "\(shortcuts.key("interaction.write.submitInteraction.key")) SAVE · \(shortcuts.key("interaction.write.cancelInteraction.key")) BACK"
                 : "\(shortcuts.key("interaction.list.up.key")) ↑ · \(shortcuts.key("interaction.list.down.key")) ↓ · \(shortcuts.key("interaction.list.confirmInteraction.space")) CONFIRM · \(shortcuts.key("interaction.list.close.key")) CLOSE")
                .font(BavbavTheme.mono(7, weight: .bold))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(BavbavTheme.surface.opacity(0.96).panelBackdrop())
    }
}

private struct PanelShell<Content: View, Footer: View>: View {
    let index: String
    let title: String
    let subtitle: String
    let connection: ConnectionDisplay
    let isReordering: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ZStack {
            BavbavTheme.background.opacity(0.985).panelBackdrop()
            VStack(spacing: 0) {
                header
                Divider().overlay(isReordering ? BavbavTheme.warning.opacity(0.65) : BavbavTheme.border)
                content()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                Divider().overlay(BavbavTheme.border)
                footer()
                    .padding(.horizontal, 12)
                    .frame(height: 38)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isReordering ? BavbavTheme.warning.opacity(0.8) : BavbavTheme.border, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(index)
                .font(BavbavTheme.mono(10, weight: .bold))
                .foregroundStyle(BavbavTheme.background).readableForeground()
                .frame(width: 26, height: 26)
                .background(isReordering ? BavbavTheme.warning : BavbavTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BavbavTheme.mono(12, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(BavbavTheme.mono(8, weight: .medium))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                }
            }
            Spacer()
            ConnectionPill(connection: connection)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
    }
}

private struct ProjectRow: View {
    let number: Int
    let project: CodexProject
    let selected: Bool
    let moving: Bool

    var body: some View {
        HStack(spacing: 10) {
            selectionBar
            Text(String(format: "%02d", number))
                .foregroundStyle(selected ? BavbavTheme.accent : BavbavTheme.muted.opacity(0.72)).readableForeground()
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.text.opacity(0.76)).readableForeground()
                    .lineLimit(1)
                Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(BavbavTheme.mono(8))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(project.chatCount)")
                .font(BavbavTheme.mono(9, weight: .bold))
                .foregroundStyle(project.chatCount > 0 ? BavbavTheme.cyan : BavbavTheme.muted).readableForeground()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(BavbavTheme.raised.panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .font(BavbavTheme.mono(11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background((selected ? BavbavTheme.raised : Color.clear).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var selectionBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(moving ? BavbavTheme.warning : (selected ? BavbavTheme.accent : Color.clear))
            .frame(width: 3, height: 24)
    }
}

private struct ThreadRow: View {
    let number: Int
    let thread: CodexThread
    let selected: Bool
    let moving: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(moving ? BavbavTheme.warning : (selected ? BavbavTheme.accent : Color.clear))
                .frame(width: 3, height: 26)
            Text(String(format: "%02d", number))
                .foregroundStyle(selected ? BavbavTheme.accent : BavbavTheme.muted.opacity(0.72)).readableForeground()
                .frame(width: 22, alignment: .trailing)
            ActivitySquare(state: thread.state, hasMessages: thread.hasMessages)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.text.opacity(0.76)).readableForeground()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: thread.cwd).lastPathComponent.uppercased())
                    Text("·")
                    Text(relativeTime(thread.updatedAt))
                }
                .font(BavbavTheme.mono(8, weight: .medium))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
            Spacer(minLength: 4)
        }
        .font(BavbavTheme.mono(11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background((selected ? BavbavTheme.raised : Color.clear).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "NOW" }
        if seconds < 3_600 { return "\(seconds / 60)M" }
        if seconds < 86_400 { return "\(seconds / 3_600)H" }
        return "\(seconds / 86_400)D"
    }
}

private struct ChatGPTLauncherRow: View {
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selected ? BavbavTheme.cyan : Color.clear)
                .frame(width: 3, height: 26)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(BavbavTheme.cyan.opacity(0.75))
                .frame(width: 9, height: 9)
            Text("CHAT")
                .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.text.opacity(0.76)).readableForeground()
            Spacer()
        }
        .font(BavbavTheme.mono(11, weight: .semibold))
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background((selected ? BavbavTheme.raised : Color.clear).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct CodexDockThreadRow: View {
    let number: Int
    let thread: CodexThread
    let selected: Bool
    let moving: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(moving ? BavbavTheme.warning : (selected ? BavbavTheme.cyan : Color.clear))
                .frame(width: 3, height: 26)
            Text(String(format: "%02d", number))
                .foregroundStyle(selected ? BavbavTheme.cyan : BavbavTheme.muted.opacity(0.72)).readableForeground()
                .frame(width: 22, alignment: .trailing)
            ActivitySquare(state: thread.state, hasMessages: thread.hasMessages)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .foregroundStyle(selected ? BavbavTheme.text : BavbavTheme.text.opacity(0.76)).readableForeground()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: thread.cwd).lastPathComponent.uppercased())
                    Text("·")
                    Text(relativeTime(thread.updatedAt))
                }
                .font(BavbavTheme.mono(8, weight: .medium))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
            Spacer(minLength: 4)
        }
        .font(BavbavTheme.mono(11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background((selected ? BavbavTheme.raised : Color.clear).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.title), Codex chat")
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "NOW" }
        if seconds < 3_600 { return "\(seconds / 60)M" }
        if seconds < 86_400 { return "\(seconds / 3_600)H" }
        return "\(seconds / 86_400)D"
    }
}

private struct ActivitySquare: View {
    let state: ThreadRunState
    let hasMessages: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(strokeColor, lineWidth: 1)
            }
            .frame(width: 9, height: 9)
            .shadow(color: state == .active ? BavbavTheme.accent.opacity(0.6) : .clear, radius: 4)
            .accessibilityLabel(accessibilityText)
    }

    private var fillColor: Color {
        switch state {
        case .active: return BavbavTheme.accent
        case .systemError: return BavbavTheme.danger
        default: return hasMessages ? BavbavTheme.cyan.opacity(0.62) : .clear
        }
    }

    private var strokeColor: Color {
        hasMessages || state == .active || state == .systemError ? .clear : BavbavTheme.muted
    }

    private var accessibilityText: String {
        switch state {
        case .active: return "Codex is working"
        case .systemError: return "Chat error"
        default: return hasMessages ? "Contains messages" : "Empty chat"
        }
    }
}

private struct ConnectionPill: View {
    let connection: ConnectionDisplay

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.55), radius: 3)
            Text(connection.shortLabel)
                .font(BavbavTheme.mono(8, weight: .bold))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(BavbavTheme.surface.panelBackdrop())
        .clipShape(Capsule())
        .help(helpText)
    }

    private var color: Color {
        switch connection {
        case .connecting: return BavbavTheme.warning
        case .connected, .channel: return BavbavTheme.accent
        case .failed: return BavbavTheme.danger
        }
    }

    private var helpText: String {
        switch connection {
        case .connecting: return "Connecting to Codex"
        case .connected(let account): return "Connected to Codex: \(account)"
        case .channel(let label): return "Local channel: \(label)"
        case .failed(let error): return error
        }
    }
}

struct KeyLegend: View {
    let items: [(String, String)]
    var accent: Color = BavbavTheme.accent

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.0).foregroundStyle(accent).readableForeground()
                    Text(item.1).foregroundStyle(BavbavTheme.muted).readableForeground()
                }
            }
            Spacer(minLength: 0)
        }
        .font(BavbavTheme.mono(8, weight: .semibold))
    }
}

private struct EmptyState: View {
    let text: String

    var body: some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(BavbavTheme.muted.opacity(0.55), lineWidth: 1)
                .frame(width: 14, height: 14)
            Text(text)
                .font(BavbavTheme.mono(10))
                .foregroundStyle(BavbavTheme.muted).readableForeground()
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

struct MessageBlock: View {
    let message: CodexMessage
    @Environment(\.messageCommandsVisible) private var commandsVisible

    var body: some View {
        let content = message.role == .user
            ? SentMessageAttachments.parse(text: message.text)
            : SentMessageAttachments(text: message.text, attachments: [])
        let images = MessageImageReferences.images(for: message)
            .filter { image in !content.attachments.contains { $0.path == image.source } }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(BavbavTheme.mono(9, weight: .bold))
                    .foregroundStyle(accent).readableForeground()
                if message.kind.isConversation {
                    if let timestamp = message.timestamp {
                        Text(timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(BavbavTheme.mono(8, weight: .light))
                            .foregroundStyle(BavbavTheme.muted).readableForeground()
                            .help(timestamp.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second().locale(Locale(identifier: "en_US"))))
                    } else {
                        Text("—")
                            .font(BavbavTheme.mono(8, weight: .light))
                            .foregroundStyle(BavbavTheme.muted).readableForeground()
                            .help("No timestamp is available for this message")
                    }
                }
                Spacer(minLength: 0)
                if let status = message.status, !status.isEmpty {
                    Text(status.uppercased())
                        .font(BavbavTheme.mono(7, weight: .bold))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                }
            }
            if !content.text.isEmpty && (images.isEmpty || message.kind.isConversation || commandsVisible) {
                MessageTextView(text: content.text, fontSize: message.kind.isConversation ? 12 : 9,
                                markdown: message.kind.isConversation)
            }
            if !content.attachments.isEmpty {
                AttachmentStrip(attachments: content.attachments)
            }
            if !images.isEmpty {
                LazyVStack(spacing: 10) {
                    ForEach(images, id: \.source) {
                        // Completion may create/replace a file whose path was
                        // already announced while the tool was still running.
                        MessageImageCard(reference: $0).id(message.status ?? "")
                    }
                }
            } else if message.kind == .image && content.text.isEmpty {
                Text(message.status == "inProgress" ? "Preparing image…" : "No image output was found in this record.")
                    .font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted).readableForeground()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(BavbavTheme.border.opacity(0.7), lineWidth: 1)
        }
    }

    private var label: String {
        message.title ?? (message.role == .user ? "YOU" : "CODEX")
    }

    private var accent: Color {
        switch message.kind {
        case .user: return BavbavTheme.cyan
        case .agent: return BavbavTheme.accent
        case .command, .fileChange, .diff: return BavbavTheme.warning
        case .system: return BavbavTheme.danger
        default: return BavbavTheme.muted
        }
    }

    private var background: Color {
        if message.kind == .user { return BavbavTheme.surface }
        if message.kind.isConversation { return BavbavTheme.raised.opacity(0.72) }
        return BavbavTheme.surface.opacity(0.72)
    }
}
