import AppKit
import BavbavCore
import Combine
import Foundation

enum OverlayKind: Equatable {
    case projects
    case recents
    case chatgpt
    case settings
    case detail
}

enum LeftRoute: Equatable {
    case projects
    case chats(CodexProject)
}

enum LeftCreationTarget: Equatable {
    case project
    case chat(CodexProject)
}

struct RenameTarget: Equatable {
    enum Item: Equatable {
        case project(CodexProject)
        case chat(CodexThread)
    }
    let panel: OverlayKind
    let scope: String
    let item: Item
    var id: String {
        switch item { case .project(let value): return value.id; case .chat(let value): return value.id }
    }
    var name: String {
        switch item { case .project(let value): return value.name; case .chat(let value): return value.title }
    }
}

enum ChatDetailHost: Equatable {
    case centered
    case dock
}

enum ChatRunDisplayState: Equatable {
    case idle
    case working
    case waiting
}

enum ConnectionDisplay: Equatable {
    case connecting
    case connected(String)
    case channel(String)
    case failed(String)

    var shortLabel: String {
        switch self {
        case .connecting: return "LINKING"
        case .connected: return "CODEX"
        case .channel(let label): return label.uppercased()
        case .failed: return "OFFLINE"
        }
    }
}

enum SettingsRow: Int, CaseIterable {
    case model
    case effort

    var label: String {
        switch self {
        case .model: return "MODEL"
        case .effort: return "EFFORT"
        }
    }
}

struct ThreadRuntimeOverrides: Codable, Equatable {
    var model: String?
    var effort: String?

    static let inherited = ThreadRuntimeOverrides(model: nil, effort: nil)
}

struct SettingsChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let value: String?
}

struct QueuedPrompt: Identifiable, Equatable {
    let id: String
    var threadID: String
    let text: String
    let model: String?
    let effort: String?
    var attachments: [ComposerAttachment] = []
    var collaborationMode: CodexCollaborationMode = .default
    var requiresRetry = false
    var displayText: String { ComposerInput.displayText(text: text, attachments: attachments) }
}

private struct ComposerDraftExtras: Codable, Equatable {
    var attachments: [ComposerAttachment] = []
    var mode: CodexCollaborationMode = .default
}

struct ChatWindowSnapshot {
    let thread: CodexThread
    let items: [CodexMessage]
    let conversation: [CodexMessage]
    let activity: [CodexMessage]
    let showsActivity: Bool
    let loading: Bool
    let error: String?

    func replacingThread(_ thread: CodexThread) -> ChatWindowSnapshot {
        ChatWindowSnapshot(thread: thread, items: items, conversation: conversation, activity: activity,
                           showsActivity: showsActivity, loading: loading, error: error)
    }
}

@MainActor
final class OverlayStore: ObservableObject {
    let journal: JournalService
    @Published private(set) var connection: ConnectionDisplay = .connecting
    @Published private(set) var projects: [CodexProject] = []
    @Published private(set) var projectChats: [CodexThread] = []
    @Published private(set) var recentChats: [CodexThread] = []
    @Published private(set) var chatGPTExpanded = false
    let chatGPTSession = ChatGPTWebSession()
    @Published private(set) var chatGPTRecents: [ChatGPTConversationLink] = []
    @Published private(set) var standaloneChats: [CodexThread] = []
    @Published private(set) var standaloneCreating = false
    @Published private(set) var standaloneError: String?
    private let standaloneDirectory: URL
    private var standaloneIDs: Set<String>
    @Published private(set) var leftRoute: LeftRoute = .projects
    @Published private(set) var leftCreationTarget: LeftCreationTarget?
    @Published var leftCreationName = ""
    @Published private(set) var leftCreationFocusToken = 0
    @Published private(set) var leftCreationSubmitting = false
    @Published private(set) var leftCreationError: String?
    @Published private(set) var renameTarget: RenameTarget?
    @Published var renameName = ""
    @Published private(set) var renameSubmitting = false
    @Published private(set) var renameError: String?
    @Published var leftInteraction = ListInteractionState()
    @Published var recentInteraction = ListInteractionState()
    @Published var chatGPTInteraction = ListInteractionState()
    @Published private(set) var detailThread: CodexThread?
    @Published private(set) var detailHost: ChatDetailHost = .centered
    @Published private(set) var detailMessages: [CodexMessage] = [] {
        didSet { cachedDetailItems = nil }
    }
    @Published private(set) var detailLoading = false
    @Published private(set) var detailActivityItems: [CodexMessage] = [] {
        didSet { cachedDetailItems = nil }
    }
    @Published private(set) var detailShowsActivity = false {
        didSet { cachedDetailItems = nil }
    }
    @Published private(set) var detailOperation: String?
    @Published private(set) var detailActivityLoading = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var codexModels: [CodexModelDescriptor] = []
    @Published private(set) var rateLimits: CodexRateLimits?
    @Published private(set) var accountUsage: CodexAccountUsage?
    @Published private(set) var settingsLoading = false
    @Published private(set) var settingsError: String?
    @Published private(set) var settingsRow: SettingsRow = .model
    @Published private(set) var settingsIsChoosing = false
    @Published private(set) var settingsChoiceIndex = 0
    @Published private(set) var activeOverrides = ThreadRuntimeOverrides.inherited
    @Published private(set) var inheritedRuntime = ThreadRuntimeOverrides.inherited
    @Published var composerText = "" {
        didSet {
            guard oldValue != composerText, let threadID = detailThread?.id else { return }
            persistDraft(composerText, for: threadID)
        }
    }
    @Published private(set) var composerVisible = false
    @Published private(set) var composerFocusToken = 0
    @Published private(set) var messageSending = false
    @Published private(set) var steerSending = false
    @Published private(set) var composerError: String?
    @Published private var composerExtras: [String: ComposerDraftExtras] = [:]
    @Published private var attachmentImports: [String: Int] = [:]
    @Published private var attachmentErrors: [String: String] = [:]
    @Published private(set) var composerToolsVisible = false
    @Published private(set) var composerToolIndex = 0
    @Published private(set) var composerGoalEditing = false
    @Published var goalObjective = ""
    @Published private var goalsByThreadID: [String: CodexThreadGoal] = [:]
    @Published private var goalBusyThreadIDs: Set<String> = []
    @Published private var goalErrorsByThreadID: [String: String] = [:]
    private var goalReadGeneration: [String: Int] = [:]
    private var turnModesByThreadID: [String: CodexCollaborationMode] = [:]
    @Published private(set) var queuedPromptsByThreadID: [String: [QueuedPrompt]] = [:]
    @Published private(set) var queueModeVisible = false
    @Published var queueInteraction = ListInteractionState()
    @Published private(set) var pendingInteractions: [CodexInteractionRequest] = [] {
        didSet { updateRunningChatCount() }
    }
    @Published private(set) var runningChatCount = 0
    @Published private(set) var interactionSelection = 0
    @Published private(set) var interactionQuestionIndex = 0
    @Published private(set) var interactionResolving = false
    @Published private(set) var interactionError: String?
    @Published var interactionText = ""
    @Published private(set) var interactionTextVisible = false
    @Published private(set) var interactionFocusToken = 0

    var onWillOpenDetail: ((CodexThread, ChatDetailHost) -> Void)?
    var onOpenDetail: (() -> Void)?
    var onDetailSnapshotRequested: ((String) -> ChatWindowSnapshot?)?
    var onDetailThreadIdentityChanged: ((CodexThread, CodexThread) -> Void)?
    var onThreadRenamed: ((CodexThread) -> Void)?
    var onChatGPTLayoutChanged: ((Bool) -> Void)?

    private let client = CodexAppServer()
    private let attachmentIntake: AttachmentIntake
    private var cachedDetailItems: [CodexMessage]?
    private(set) var timelineBuildCount = 0
    private let defaults: UserDefaults
    private var codexHome: String?
    private var allThreads: [CodexThread] = []
    private var threadNameRevision = 0
    private var threadNameChanges: [String: (revision: Int, name: String)] = [:]
    private var connecting = false
    private var refreshing = false
    private var consecutiveRefreshFailures = 0
    private var eventHandlerInstalled = false
    private var activeTurnIDsByThreadID: [String: String] = [:]
    private var settingsRefreshing = false
    private var lastFreshModelCatalogAt: Date?
    private var sendingThreadIDs: Set<String> = []
    private var optimisticUserMessages: [OptimisticUserMessage] = []
    private var queuedThreadOrder: [String] = []
    private var draftsByThreadID: [String: String] = [:]
    private var creatingWritableThread = false
    private var detailLoadGeneration = 0
    private var detailFocusGeneration = 0
    private var conversationRevision = 0
    private var activityRevision = 0
    private var detailReadInFlight = false
    private var activityReadInFlight = false
    private var detailLoadTask: Task<Void, Never>?
    private var activityLoadGeneration = 0
    private var activityLoadTask: Task<Void, Never>?
    private var runtimeLoadGeneration = 0
    private var runtimeLoadTask: Task<Void, Never>?
    private var projectChatsLoadGeneration = 0
    private var interactionAnswers: [String: [String]] = [:]

    static let chatGPTLauncherID = "chatgpt.launcher"

    init(defaults: UserDefaults = .standard, standaloneDirectory: URL? = nil, journal: JournalService? = nil,
         attachmentIntake: AttachmentIntake? = nil) {
        self.defaults = defaults
        self.attachmentIntake = attachmentIntake ?? .shared
        self.journal = journal ?? JournalService()
        self.standaloneDirectory = standaloneDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bavbav/StandaloneChats", isDirectory: true)
        self.standaloneIDs = Set(defaults.stringArray(forKey: "chat.standalone-ids") ?? [])
        self.journal.onOpenSource = { [weak self] thread in
            guard let self else { return }
            self.focusDetailWindow(self.allThreads.first { $0.id == thread.id } ?? thread)
        }
        self.journal.recoverTurn = { [client] threadID, turnID in
            try await client.readJournalTurn(threadID: threadID, turnID: turnID)
        }
        // CHAT must remain usable even if the independent Codex connection fails.
        chatGPTInteraction.selectedID = Self.chatGPTLauncherID
        chatGPTSession.onRecentsChanged = { [weak self] links in
            guard let self else { return }
            chatGPTRecents = links
            if !chatGPTMenuIDs.contains(chatGPTInteraction.selectedID ?? "") {
                chatGPTInteraction.selectedID = Self.chatGPTLauncherID
            }
        }
    }

    func connectAndLoad() async {
        guard !connecting else { return }
        connecting = true
        connection = .connecting
        journal.sourceConnected = false
        defer { connecting = false }
        await journal.start()

        do {
            let health = try await client.connect()
            codexHome = health.codexHome.isEmpty ? nil : health.codexHome
            guard health.authenticated, health.historyAvailable, health.modelAvailable else {
                connection = .failed("Codex hesabı veya model erişimi hazır değil")
                return
            }
            await installEventHandlerIfNeeded()
            connection = .connected(health.accountType ?? "local")
            journal.sourceConnected = true
            await refresh()
            await refreshSettingsData()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func installEventHandlerIfNeeded() async {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        await client.setEventHandler { [weak self] event in
            // CodexAppServer invokes this closure in wire order. The main queue
            // keeps streaming deltas in that same order for the observable UI.
            DispatchQueue.main.async { [weak self] in
                self?.handleServerEvent(event)
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let nameRevision = threadNameRevision

        do {
            // Fetch every practical local record rather than silently cutting
            // the project catalog at the newest 80 conversations.
            let fetched = reconcileFetchedNames(visibleThreads(try await client.listThreads(limit: 2_000)), since: nameRevision)
            allThreads = fetched

            let saved = ProjectCatalog.loadSavedProjects(codexHome: codexHome)
                .filter { ProjectCatalog.canonicalPath($0.path) != standaloneDirectory.standardizedFileURL.path }
            let merged = ProjectCatalog.mergeProjects(saved: saved, threads: fetched.filter { !self.isStandalone($0) })
            projects = applySavedOrder(merged.map(applyProjectName), key: "order.projects")

            updateChatCatalogs()
            ensureSelections()
            journal.pulse()

            if case .chats(let project) = leftRoute {
                await loadChats(for: project, preserveSelection: true)
            }
            syncVisibleConversation()
            lastSync = Date()
            consecutiveRefreshFailures = 0
            journal.sourceConnected = true
            if case .failed = connection {
                connection = .connected("local")
            }
        } catch {
            consecutiveRefreshFailures += 1
            NSLog("[Bavbav] Codex refresh failed: %@", error.localizedDescription)
            // Eski ve kullanılabilir veriyi tek geçici gecikmede OFFLINE diye
            // damgalama. Arka arkaya sorun varsa kullanıcıya netçe göster.
            if allThreads.isEmpty || consecutiveRefreshFailures >= 3 {
                connection = .failed(error.localizedDescription)
                journal.sourceConnected = false
            }
        }
    }

    /// Re-reads the visible conversation so replies completed while Bavbav was
    /// closed, inactive, or reconnecting are not dependent on missed live events.
    func syncVisibleConversation() {
        guard let threadID = detailThread?.id,
              !sendingThreadIDs.contains(threadID),
              !detailReadInFlight,
              !activityReadInFlight,
              !optimisticUserMessages.contains(where: { $0.threadID == threadID })
        else { return }
        startDetailLoad(threadID: threadID)
        startActivityLoad(threadID: threadID)
    }

    func navigate(_ panel: OverlayKind, delta: Int) {
        switch panel {
        case .projects:
            let ids = leftVisibleIDs
            guard !ids.isEmpty else { return }
            if leftInteraction.isReordering {
                reorderLeft(delta: delta)
            } else {
                leftInteraction.selectedID = adjacentID(
                    current: leftInteraction.selectedID,
                    ids: ids,
                    delta: delta
                )
            }
        case .recents:
            let ids = recentChats.map(\.id)
            guard !ids.isEmpty else { return }
            if recentInteraction.isReordering {
                let current = index(of: recentInteraction.selectedID, in: ids)
                let moved = StableOrdering.moved(recentChats, from: current, delta: delta)
                recentChats = moved.items
                recentInteraction.selectedID = recentChats[moved.index].id
            } else {
                recentInteraction.selectedID = adjacentID(
                    current: recentInteraction.selectedID,
                    ids: ids,
                    delta: delta
                )
            }
        case .chatgpt:
            guard !chatGPTExpanded else { return }
            let ids = chatGPTMenuIDs
            guard !ids.isEmpty else { return }
            if chatGPTInteraction.isReordering,
               let index = standaloneChats.firstIndex(where: { $0.id == chatGPTInteraction.selectedID }) {
                standaloneChats = StableOrdering.moved(standaloneChats, from: index, delta: delta).items
                return
            }
            chatGPTInteraction.selectedID = adjacentID(
                current: chatGPTInteraction.selectedID,
                ids: ids,
                delta: delta
            )
        case .settings:
            settingsNavigate(delta: delta)
        case .detail:
            break
        }
    }

    /// Returns true when the caller should start the long-press timer.
    func beginSpace(_ panel: OverlayKind) -> Bool {
        switch panel {
        case .projects:
            let output = leftInteraction.beginSpace(visibleIDs: leftVisibleIDs)
            if output == .committed {
                saveLeftOrder()
                return false
            }
            return true
        case .recents:
            let output = recentInteraction.beginSpace(visibleIDs: recentChats.map(\.id))
            if output == .committed {
                saveOrder(recentChats.map(\.id), key: "order.recents")
                return false
            }
            return true
        case .chatgpt:
            guard !chatGPTExpanded else { return false }
            guard let selected = chatGPTInteraction.selectedID else { return false }
            if selected == Self.chatGPTLauncherID {
                activate(id: selected, in: .chatgpt)
                return false
            }
            let output = chatGPTInteraction.beginSpace(visibleIDs: chatGPTMenuIDs)
            if output == .committed { saveOrder(standaloneChats.map(\.id), key: "order.standalone") }
            return output != .committed
        case .settings:
            settingsSpace()
            return false
        case .detail:
            return false
        }
    }

    func crossLongPressThreshold(_ panel: OverlayKind) {
        switch panel {
        case .projects:
            _ = leftInteraction.crossLongPressThreshold(visibleIDs: leftVisibleIDs)
        case .recents:
            _ = recentInteraction.crossLongPressThreshold(visibleIDs: recentChats.map(\.id))
        case .chatgpt:
            _ = chatGPTInteraction.crossLongPressThreshold(visibleIDs: chatGPTMenuIDs)
        case .settings:
            break
        case .detail:
            break
        }
    }

    /// Cancel a pending tap without opening it; completed reorder mode is kept.
    func cancelListPress(_ panel: OverlayKind) {
        switch panel {
        case .projects: if case .pressing = leftInteraction.mode { leftInteraction.mode = .browsing }
        case .recents: if case .pressing = recentInteraction.mode { recentInteraction.mode = .browsing }
        case .chatgpt: if case .pressing = chatGPTInteraction.mode { chatGPTInteraction.mode = .browsing }
        default: break
        }
    }

    func releaseSpace(_ panel: OverlayKind) {
        let output: ListInteractionOutput
        switch panel {
        case .projects:
            output = leftInteraction.releaseSpace()
        case .recents:
            output = recentInteraction.releaseSpace()
        case .chatgpt:
            output = chatGPTInteraction.releaseSpace()
        case .settings:
            return
        case .detail:
            return
        }

        if case .activate(let id) = output {
            activate(id: id, in: panel)
        }
    }

    func activateSelection(_ panel: OverlayKind) {
        switch panel {
        case .projects:
            guard let id = leftInteraction.selectedID else { return }
            activate(id: id, in: panel)
        case .recents:
            guard let id = recentInteraction.selectedID else { return }
            activate(id: id, in: panel)
        case .chatgpt:
            guard let id = chatGPTInteraction.selectedID else { return }
            activate(id: id, in: panel)
        case .settings:
            settingsSpace()
        case .detail:
            break
        }
    }

    /// Resets transient keyboard modes on Q. In a project's chat list the
    /// coordinator keeps the window open and this restores the parent project.
    func prepareToClose(_ panel: OverlayKind) {
        if renameTarget?.panel == panel { cancelRename() }
        switch panel {
        case .projects:
            let projectSelection: String? = {
                if case .chats(let project) = leftRoute { return project.id }
                return leftInteraction.selectedID
            }()
            if leftInteraction.isReordering {
                restoreLeftOrder()
            }
            leftRoute = .projects
            projectChats = []
            leftInteraction = ListInteractionState(
                selectedID: projects.contains(where: { $0.id == projectSelection })
                    ? projectSelection
                    : projects.first?.id
            )
        case .recents:
            if recentInteraction.isReordering {
                if let original = recentInteraction.originalIDs {
                    recentChats = StableOrdering.reconcile(recentChats, preferredIDs: original)
                }
            }
            let selection = recentInteraction.selectedID
            recentInteraction = ListInteractionState(
                selectedID: recentChats.contains(where: { $0.id == selection })
                    ? selection
                    : recentChats.first?.id
            )
        case .chatgpt:
            if chatGPTInteraction.isReordering, let ids = chatGPTInteraction.originalIDs {
                standaloneChats = StableOrdering.reconcile(standaloneChats, preferredIDs: ids)
            }
            if chatGPTExpanded {
                chatGPTExpanded = false
                onChatGPTLayoutChanged?(false)
            }
            chatGPTInteraction = ListInteractionState(selectedID: Self.chatGPTLauncherID)
        case .settings:
            settingsIsChoosing = false
            settingsChoiceIndex = 0
        case .detail:
            if queueInteraction.isReordering {
                cancelQueueSpacePress(revert: true)
            }
            queueModeVisible = false
            queueInteraction = ListInteractionState()
            if composerVisible {
                cancelWriting()
            }
        }
    }

    func selectLeft(id: String) {
        leftInteraction.selectedID = id
    }

    func selectRecent(id: String) {
        recentInteraction.selectedID = id
    }

    func selectChatGPT(id: String) {
        chatGPTInteraction.selectedID = id
    }

    func collapseChatGPT() {
        chatGPTExpanded = false
        onChatGPTLayoutChanged?(false)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func shutdown() async {
        await journal.stop()
        await client.setEventHandler(nil)
        await client.shutdown()
    }

    var leftVisibleIDs: [String] {
        switch leftRoute {
        case .projects: return projects.map(\.id)
        case .chats: return projectChats.map(\.id)
        }
    }

    var leftIsReordering: Bool { leftInteraction.isReordering }
    var leftCreationActive: Bool { leftCreationTarget != nil }
    var recentIsReordering: Bool { recentInteraction.isReordering }
    var chatGPTIsReordering: Bool { chatGPTInteraction.isReordering }

    func isComposerPresented(in panel: OverlayKind) -> Bool {
        guard composerVisible else { return false }
        switch panel {
        case .detail:
            return detailHost == .centered
        case .chatgpt:
            return false
        case .projects, .recents, .settings:
            return false
        }
    }

    func beginLeftCreation() {
        guard renameTarget?.panel != .projects, !leftInteraction.isReordering, !leftCreationSubmitting else { return }
        switch leftRoute {
        case .projects:
            leftCreationTarget = .project
        case .chats(let project):
            leftCreationTarget = .chat(project)
        }
        NSLog("[Bavbav] New %@ name slot opened", leftRoute == .projects ? "project" : "chat")
        leftCreationName = ""
        leftCreationError = nil
        DispatchQueue.main.async { [weak self] in self?.leftCreationFocusToken &+= 1 }
    }

    func cancelLeftCreation() {
        guard !leftCreationSubmitting else { return }
        if leftCreationTarget != nil { NSLog("[Bavbav] Empty name cancelled creation") }
        leftCreationTarget = nil
        leftCreationName = ""
        leftCreationError = nil
    }

    func commitLeftCreation() {
        guard let target = leftCreationTarget, !leftCreationSubmitting else { return }
        let name = leftCreationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelLeftCreation()
            return
        }
        leftCreationSubmitting = true
        leftCreationError = nil

        Task {
            defer { leftCreationSubmitting = false }
            do {
                switch target {
                case .project:
                    try await createNamedProject(name)
                case .chat(let project):
                    try await createNamedChat(name, in: project)
                }
                leftCreationTarget = nil
                leftCreationName = ""
            } catch {
                leftCreationError = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.leftCreationFocusToken &+= 1 }
            }
        }
    }

    var renameScope: String {
        "rename.\(renameTarget?.scope ?? "projects.root")." + (renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "full")
    }

    func isRenaming(_ panel: OverlayKind, id: String) -> Bool {
        renameTarget?.panel == panel && renameTarget?.id == id
    }

    func beginRename(in panel: OverlayKind) {
        guard !renameSubmitting, panel != .projects || !leftCreationActive else { return }
        let target: RenameTarget
        switch panel {
        case .projects:
            guard !leftIsReordering else { return }
            switch leftRoute {
            case .projects:
                guard let item = projects.first(where: { $0.id == leftInteraction.selectedID }) else { return }
                target = RenameTarget(panel: panel, scope: "projects.root", item: .project(item))
            case .chats:
                guard let item = projectChats.first(where: { $0.id == leftInteraction.selectedID }) else { return }
                target = RenameTarget(panel: panel, scope: "projects.chats", item: .chat(item))
            }
        case .recents:
            guard !recentIsReordering, let item = recentChats.first(where: { $0.id == recentInteraction.selectedID }) else { return }
            target = RenameTarget(panel: panel, scope: "recents.list", item: .chat(item))
        case .chatgpt:
            // CHAT is an action, not a saved conversation name.
            guard !chatGPTIsReordering, let item = standaloneChats.first(where: { $0.id == chatGPTInteraction.selectedID }) else { return }
            target = RenameTarget(panel: panel, scope: "standalone.list", item: .chat(item))
        case .settings, .detail: return
        }
        renameName = target.name
        renameError = nil
        renameTarget = target
    }

    func cancelRename() {
        guard !renameSubmitting else { return }
        renameTarget = nil
        renameName = ""
        renameError = nil
    }

    func commitRename() {
        guard let target = renameTarget, !renameSubmitting else { return }
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { cancelRename(); return }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
            renameError = "Ad tek satır olmalı; kontrol karakteri içeremez."
            return
        }
        switch target.item {
        case .project(let project):
            var names = defaults.dictionary(forKey: "project.display-names.v1") as? [String: String] ?? [:]
            names[ProjectCatalog.canonicalPath(project.path)] = name
            defaults.set(names, forKey: "project.display-names.v1")
            projects = projects.map(applyProjectName)
            if case .chats(let current) = leftRoute { leftRoute = .chats(applyProjectName(current)) }
            cancelRename()
        case .chat(let thread):
            renameSubmitting = true
            renameError = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await client.setThreadName(id: thread.id, name: name)
                    threadNameRevision &+= 1
                    threadNameChanges[thread.id] = (threadNameRevision, name)
                    let latest = allThreads.first { $0.id == thread.id } ?? thread
                    let renamed = renamedThread(latest, name: name, updatedAt: latest.updatedAt)
                    allThreads = allThreads.map { $0.id == thread.id ? self.renamedThread($0, name: name, updatedAt: $0.updatedAt) : $0 }
                    projectChats = projectChats.map { $0.id == thread.id ? self.renamedThread($0, name: name, updatedAt: $0.updatedAt) : $0 }
                    updateChatCatalogs()
                    if let current = detailThread, current.id == thread.id {
                        detailThread = renamedThread(current, name: name, updatedAt: current.updatedAt)
                    }
                    onThreadRenamed?(renamed)
                    renameSubmitting = false
                    cancelRename()
                } catch {
                    renameSubmitting = false
                    renameError = "Ad değiştirilemedi: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyProjectName(_ project: CodexProject) -> CodexProject {
        var project = project
        if let name = (defaults.dictionary(forKey: "project.display-names.v1") as? [String: String])?[ProjectCatalog.canonicalPath(project.path)] {
            project.name = name
        }
        return project
    }

    private func reconcileFetchedNames(_ threads: [CodexThread], since revision: Int) -> [CodexThread] {
        threads.map { thread in
            guard let change = threadNameChanges[thread.id], change.revision > revision else { return thread }
            return renamedThread(thread, name: change.name, updatedAt: thread.updatedAt)
        }
    }

    func isInteractionInputPresented(in panel: OverlayKind) -> Bool {
        guard interactionTextVisible, activeInteraction != nil else { return false }
        switch panel {
        case .detail:
            return detailHost == .centered
        case .chatgpt:
            return false
        case .projects, .recents, .settings:
            return false
        }
    }

    func hasInteractionPresented(in panel: OverlayKind) -> Bool {
        guard activeInteraction != nil else { return false }
        switch panel {
        case .detail: return detailHost == .centered
        case .chatgpt: return false
        case .projects, .recents, .settings: return false
        }
    }

    var chatGPTMenuIDs: [String] {
        [Self.chatGPTLauncherID] + standaloneChats.map(\.id)
    }

    func isStandalone(_ thread: CodexThread) -> Bool {
        standaloneIDs.contains(thread.id) || ProjectCatalog.canonicalPath(thread.cwd) == standaloneDirectory.standardizedFileURL.path
    }

    func channelLabel(for thread: CodexThread?) -> String {
        thread.map { isStandalone($0) ? "CHANNEL / ChatGPT" : "CHANNEL / CODEX" } ?? "CHANNEL / CODEX"
    }

    private func updateChatCatalogs() {
        let sorted = allThreads.sorted { $0.updatedAt > $1.updatedAt }
        recentChats = applySavedOrder(Array(sorted.filter { !self.isStandalone($0) }.prefix(8)), key: "order.recents")
        standaloneChats = applySavedOrder(Array(sorted.filter { self.isStandalone($0) }.prefix(3)), key: "order.standalone")
    }

    private func createStandaloneChat() {
        guard !standaloneCreating else { return }
        standaloneCreating = true
        standaloneError = nil
        Task {
            defer { standaloneCreating = false }
            do {
                try FileManager.default.createDirectory(at: standaloneDirectory, withIntermediateDirectories: true)
                let thread = try await client.startThread(cwd: standaloneDirectory.path,
                    sandbox: "danger-full-access", approvalPolicy: "never")
                standaloneIDs.insert(thread.id)
                defaults.set(Array(standaloneIDs), forKey: "chat.standalone-ids")
                allThreads.removeAll { $0.id == thread.id }
                allThreads.insert(thread, at: 0)
                updateChatCatalogs()
                chatGPTInteraction = ListInteractionState(selectedID: thread.id)
                // Open in reading mode, exactly like an ordinary Codex chat.
                open(thread)
            } catch {
                standaloneError = "Sohbet açılamadı: \(error.localizedDescription)"
            }
        }
    }

    var visibleDetailItems: [CodexMessage] {
        if let cachedDetailItems { return cachedDetailItems }
        let items = ChatTimeline.visible(activity: detailActivityItems, conversation: detailMessages,
                                         commandsVisible: detailShowsActivity)
        cachedDetailItems = items
        timelineBuildCount &+= 1
        return items
    }

    var visibleDetailLoading: Bool {
        visibleDetailItems.isEmpty && (detailLoading || detailActivityLoading)
    }

    var detailRunState: ChatRunDisplayState {
        guard let threadID = detailThread?.id else { return .idle }
        return runState(for: threadID)
    }

    func runState(for threadID: String) -> ChatRunDisplayState {
        if pendingInteractions.contains(where: { $0.threadID == threadID }) {
            return .waiting
        }
        if sendingThreadIDs.contains(threadID) || activeTurnIDsByThreadID[threadID] != nil {
            return .working
        }
        return .idle
    }

    var canSteerCurrentTurn: Bool {
        guard let threadID = detailThread?.id else { return false }
        return activeInteraction == nil
            && !steerSending
            && sendingThreadIDs.contains(threadID)
            && activeTurnIDsByThreadID[threadID] != nil
    }

    var shouldQueueCurrentMessage: Bool {
        guard let threadID = detailThread?.id else { return false }
        return sendingThreadIDs.contains(threadID)
    }

    var composerInputEnabled: Bool {
        true
    }

    var composerAttachments: [ComposerAttachment] { detailThread.map { composerAttachments(for: $0.id) } ?? [] }
    var composerHasPayload: Bool { !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerAttachments.isEmpty }
    var composerImporting: Bool {
        guard let id = detailThread?.id else { return false }
        return attachmentImports.contains { $0.value > 0 && attachmentDestination($0.key) == id }
    }
    var composerAttachmentError: String? { detailThread.flatMap { attachmentErrors[$0.id] } }
    var composerMode: CodexCollaborationMode { detailThread.map { draftExtras(for: $0.id).mode } ?? .default }
    var composerGoal: CodexThreadGoal? { detailThread.flatMap { goalsByThreadID[$0.id] } }
    var composerGoalBusy: Bool { detailThread.map { goalBusyThreadIDs.contains($0.id) } ?? false }
    var composerGoalError: String? { detailThread.flatMap { goalErrorsByThreadID[$0.id] } }

    private func draftExtras(for id: String) -> ComposerDraftExtras {
        if let cached = composerExtras[id] { return cached }
        return defaults.data(forKey: "composer.extras.\(id)")
            .flatMap { try? JSONDecoder().decode(ComposerDraftExtras.self, from: $0) } ?? ComposerDraftExtras()
    }
    private func saveExtras(_ extras: ComposerDraftExtras, for id: String) {
        composerExtras[id] = extras
        if let data = try? JSONEncoder().encode(extras) { defaults.set(data, forKey: "composer.extras.\(id)") }
    }
    func composerAttachments(for threadID: String) -> [ComposerAttachment] { draftExtras(for: threadID).attachments }
    private func setComposerAttachments(_ attachments: [ComposerAttachment], for id: String) {
        var extras = draftExtras(for: id)
        extras.attachments = attachments
        saveExtras(extras, for: id)
    }
    func addComposerAttachments(_ attachments: [ComposerAttachment], to threadID: String) {
        var items = composerAttachments(for: threadID)
        var seen = Set(items.map(\.path))
        for item in attachments where seen.insert(item.path).inserted { items.append(item) }
        if items.count > AttachmentIntake.maximumCount {
            attachmentErrors[threadID] = "Bir mesaja en fazla \(AttachmentIntake.maximumCount) dosya ekleyebilirsin."
        }
        setComposerAttachments(Array(items.prefix(AttachmentIntake.maximumCount)), for: threadID)
    }
    func removeComposerAttachment(id: String) {
        guard let threadID = detailThread?.id else { return }
        setComposerAttachments(composerAttachments.filter { $0.id != id }, for: threadID)
        attachmentErrors[threadID] = nil
        // Only remove the reference. A sent/queued message may still own this
        // same durable file; never delete it while background work can use it.
    }
    func setComposerMode(_ mode: CodexCollaborationMode) {
        guard let id = detailThread?.id else { return }
        setComposerMode(mode, for: id)
    }
    private func setComposerMode(_ mode: CodexCollaborationMode, for id: String) {
        var extras = draftExtras(for: id)
        extras.mode = mode
        saveExtras(extras, for: id)
    }
    @discardableResult
    func importComposerPasteboard(_ pasteboard: NSPasteboard, for thread: CodexThread) -> Bool {
        guard AttachmentIntake.accepts(pasteboard) else { return false }
        let id = thread.id
        // Capture the destination now, not when a promised screenshot arrives.
        focusDetailWindow(thread)
        closeComposerTools(restoreFocus: false)
        beginWriting(from: .detail)
        attachmentImports[id, default: 0] += 1
        attachmentErrors[id] = nil
        let accepted = attachmentIntake.importPasteboard(pasteboard) { [weak self] result in
            self?.finishAttachmentImport(result, for: id)
        }
        if !accepted { attachmentImports[id, default: 0] -= 1 }
        return accepted
    }
    func chooseComposerFiles() {
        guard let thread = detailThread, let window = NSApp.keyWindow else { return }
        closeComposerTools(restoreFocus: false)
        let panel = NSOpenPanel()
        panel.title = "Fotoğraf veya belge ekle"
        panel.prompt = "Ekle"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            // The sheet is still resigning key status inside its completion.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.detailThread?.id == thread.id, self.composerVisible,
                      self.activeInteraction == nil, window?.isKeyWindow == true else { return }
                self.requestComposerFocus(threadID: thread.id)
            }
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                guard let self else { return }
                attachmentImports[thread.id, default: 0] += 1
                attachmentErrors[thread.id] = nil
                let result = await attachmentIntake.ingest(urls: urls)
                finishAttachmentImport(result, for: thread.id)
            }
        }
    }
    private func finishAttachmentImport(_ result: AttachmentIntakeResult, for id: String) {
        attachmentImports[id] = max(0, attachmentImports[id, default: 0] - 1)
        let target = attachmentDestination(id)
        if !result.errors.isEmpty { attachmentErrors[target] = result.errors.joined(separator: "\n") }
        addComposerAttachments(result.attachments, to: target)
    }
    private func attachmentDestination(_ id: String) -> String {
        var target = id
        let redirects = defaults.dictionary(forKey: "thread.redirects") as? [String: String] ?? [:]
        var visited = Set<String>()
        while let next = redirects[target], visited.insert(target).inserted { target = next }
        return target
    }

    func toggleComposerTools() {
        guard detailThread != nil, composerVisible else { return }
        if composerToolsVisible { closeComposerTools(); return }
        composerToolsVisible = true
        composerGoalEditing = false
        composerToolIndex = 0
        NSApp.keyWindow?.makeFirstResponder(nil)
        refreshComposerGoal()
    }
    func closeComposerTools(restoreFocus: Bool = true) {
        let wasOpen = composerToolsVisible
        composerToolsVisible = false
        composerGoalEditing = false
        if wasOpen && restoreFocus, let id = detailThread?.id { requestComposerFocus(threadID: id) }
    }
    func navigateComposerTools(delta: Int) { composerToolIndex = min(3, max(0, composerToolIndex + delta)) }
    func activateComposerTool() {
        switch composerToolIndex {
        case 0: chooseComposerFiles()
        case 1: setComposerMode(.default); closeComposerTools()
        case 2: setComposerMode(.plan); closeComposerTools()
        default: beginComposerGoalEditing()
        }
    }
    func beginComposerGoalEditing() {
        guard let id = detailThread?.id else { return }
        goalObjective = defaults.string(forKey: "composer.goal-draft.\(id)") ?? composerGoal?.objective ?? ""
        composerToolsVisible = true
        composerGoalEditing = true
    }
    func updateGoalObjective(_ value: String) {
        goalObjective = value
        if let id = detailThread?.id { defaults.set(value, forKey: "composer.goal-draft.\(id)") }
    }
    func cancelComposerGoalEditing() {
        composerGoalEditing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func refreshComposerGoal() {
        guard let id = detailThread?.id, !goalBusyThreadIDs.contains(id) else { return }
        goalReadGeneration[id, default: 0] += 1
        let generation = goalReadGeneration[id]!
        Task { [weak self] in
            guard let self else { return }
            do {
                let goal = try await client.readThreadGoal(threadID: id)
                guard goalReadGeneration[id] == generation else { return }
                goalsByThreadID[id] = goal
                goalErrorsByThreadID[id] = nil
            } catch {
                guard goalReadGeneration[id] == generation else { return }
                goalErrorsByThreadID[id] = "Goal okunamadı: \(error.localizedDescription)"
            }
        }
    }
    func saveComposerGoal() {
        guard let id = detailThread?.id, !goalBusyThreadIDs.contains(id) else { return }
        let objective = goalObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { cancelComposerGoalEditing(); return }
        goalBusyThreadIDs.insert(id)
        goalReadGeneration[id, default: 0] += 1
        goalErrorsByThreadID[id] = nil
        Task { [weak self] in
            guard let self else { return }
            defer { goalBusyThreadIDs.remove(id) }
            do {
                let goal = try await client.setThreadGoal(threadID: id, objective: objective)
                goalsByThreadID[id] = goal
                defaults.removeObject(forKey: "composer.goal-draft.\(id)")
                if detailThread?.id == id { cancelComposerGoalEditing() }
            } catch { goalErrorsByThreadID[id] = "Goal kaydedilemedi: \(error.localizedDescription)" }
        }
    }
    func clearComposerGoal() {
        guard let id = detailThread?.id, !goalBusyThreadIDs.contains(id) else { return }
        goalBusyThreadIDs.insert(id)
        goalReadGeneration[id, default: 0] += 1
        goalErrorsByThreadID[id] = nil
        Task { [weak self] in
            guard let self else { return }
            defer { goalBusyThreadIDs.remove(id) }
            do {
                _ = try await client.clearThreadGoal(threadID: id)
                goalsByThreadID[id] = nil
                defaults.removeObject(forKey: "composer.goal-draft.\(id)")
            } catch { goalErrorsByThreadID[id] = "Goal kaldırılamadı: \(error.localizedDescription)" }
        }
    }

    var currentQueuedPrompts: [QueuedPrompt] {
        guard let threadID = detailThread?.id else { return [] }
        return queuedPromptsByThreadID[threadID] ?? []
    }

    var currentQueueCount: Int { currentQueuedPrompts.count }
    var queueIsReordering: Bool { queueInteraction.isReordering }

    func toggleQueueMode() {
        guard detailThread != nil,
              !composerVisible,
              activeInteraction == nil
        else { return }
        queueModeVisible.toggle()
        queueInteraction = ListInteractionState(
            selectedID: queueModeVisible ? currentQueuedPrompts.first?.id : nil
        )
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func navigateQueue(delta: Int) {
        guard queueModeVisible else { return }
        let prompts = currentQueuedPrompts
        let ids = prompts.map(\.id)
        guard !ids.isEmpty, let threadID = detailThread?.id else { return }
        if queueInteraction.isReordering {
            let current = index(of: queueInteraction.selectedID, in: ids)
            let moved = StableOrdering.moved(prompts, from: current, delta: delta)
            queuedPromptsByThreadID[threadID] = moved.items
            queueInteraction.selectedID = moved.items[moved.index].id
        } else {
            queueInteraction.selectedID = adjacentID(
                current: queueInteraction.selectedID,
                ids: ids,
                delta: delta
            )
        }
    }

    func beginQueueSpace() -> Bool {
        guard queueModeVisible, canSteerCurrentTurn else { return false }
        let ids = currentQueuedPrompts.map(\.id)
        guard !ids.isEmpty else { return false }
        _ = queueInteraction.beginSpace(visibleIDs: ids)
        return true
    }

    func crossQueueLongPressThreshold() {
        guard queueModeVisible else { return }
        _ = queueInteraction.crossLongPressThreshold(visibleIDs: currentQueuedPrompts.map(\.id))
    }

    func finishQueueSpace(longPressTriggered: Bool) {
        guard queueModeVisible else {
            cancelQueueSpacePress(revert: true)
            return
        }
        if longPressTriggered {
            queueInteraction.mode = .browsing
            return
        }
        if case .activate(let id) = queueInteraction.releaseSpace() {
            steerQueuedPrompt(id: id)
        }
    }

    func cancelQueueSpacePress(revert: Bool) {
        if revert,
           let originalIDs = queueInteraction.originalIDs,
           let threadID = detailThread?.id {
            queuedPromptsByThreadID[threadID] = StableOrdering.reconcile(
                currentQueuedPrompts,
                preferredIDs: originalIDs
            )
        }
        queueInteraction.mode = .browsing
    }

    func editSelectedQueuedPrompt() {
        guard queueModeVisible,
              let threadID = detailThread?.id,
              let selectedID = queueInteraction.selectedID,
              var queue = queuedPromptsByThreadID[threadID],
              let index = queue.firstIndex(where: { $0.id == selectedID })
        else { return }
        let prompt = queue.remove(at: index)
        let hadDraft = composerHasPayload
        if hadDraft {
            // Editing a queued item must not erase a newer text/image draft.
            queue.insert(QueuedPrompt(id: "bavbav-draft-\(UUID().uuidString)", threadID: threadID,
                text: composerText, model: activeOverrides.model, effort: activeOverrides.effort,
                attachments: composerAttachments, collaborationMode: composerMode, requiresRetry: true), at: index)
        }
        queuedPromptsByThreadID[threadID] = queue
        updateQueuedThreadRegistration(threadID)
        queueModeVisible = false
        queueInteraction = ListInteractionState()
        composerText = prompt.text
        setComposerAttachments(prompt.attachments, for: threadID)
        setComposerMode(prompt.collaborationMode, for: threadID)
        persistDraft(prompt.text, for: threadID)
        composerVisible = true
        composerError = hadDraft ? "Önceki taslağın kuyrukta korundu; kendiliğinden gönderilmez." : nil
        DispatchQueue.main.async { [weak self] in self?.composerFocusToken &+= 1 }
    }

    func detailSnapshot() -> ChatWindowSnapshot? {
        guard let thread = detailThread, detailHost == .centered else { return nil }
        return ChatWindowSnapshot(
            thread: thread,
            items: visibleDetailItems,
            conversation: detailMessages,
            activity: detailActivityItems,
            showsActivity: detailShowsActivity,
            loading: visibleDetailLoading,
            error: composerError
        )
    }

    func focusDetailWindow(_ thread: CodexThread) {
        // Native focus notifications may repeat without changing conversations.
        // They must not reload history, rebuild a view, or steal text selection.
        guard detailThread?.id != thread.id || detailHost != .centered else { return }
        open(thread)
    }

    func clearCurrentDetail(threadID: String) {
        guard detailThread?.id == threadID else { return }
        closeComposerTools(restoreFocus: false)
        detailFocusGeneration &+= 1
        defaults.set(detailShowsActivity, forKey: "commands-visible.\(threadID)")
        detailLoadTask?.cancel()
        activityLoadTask?.cancel()
        runtimeLoadTask?.cancel()
        detailLoadGeneration &+= 1
        activityLoadGeneration &+= 1
        runtimeLoadGeneration &+= 1
        detailReadInFlight = false
        activityReadInFlight = false
        detailThread = nil
        detailMessages = []
        detailActivityItems = []
        detailShowsActivity = false
        detailOperation = nil
        detailLoading = false
        detailActivityLoading = false
        composerText = ""
        composerVisible = false
        queueModeVisible = false
        queueInteraction = ListInteractionState()
        composerError = nil
        activeOverrides = .inherited
        inheritedRuntime = .inherited
        resetInteractionNavigation()
    }

    var activeInteraction: CodexInteractionRequest? {
        guard let threadID = detailThread?.id else { return nil }
        return pendingInteractions.first(where: { $0.threadID == threadID })
    }

    var currentInteractionQuestion: CodexInteractionQuestion? {
        guard let request = activeInteraction,
              request.questions.indices.contains(interactionQuestionIndex)
        else { return nil }
        return request.questions[interactionQuestionIndex]
    }

    var currentInteractionOptions: [CodexInteractionOption] {
        if let question = currentInteractionQuestion {
            var options = question.options
            if question.allowsOther {
                options.append(CodexInteractionOption(
                    id: "__other__",
                    label: question.options.isEmpty ? "TYPE ANSWER" : "OTHER",
                    detail: "Klavyeyle özel bir yanıt yaz"
                ))
            }
            if question.allowsMultiple {
                options.append(CodexInteractionOption(
                    id: "__done__",
                    label: "DONE",
                    detail: "Seçimleri kaydet ve devam et"
                ))
            }
            if !question.isRequired {
                options.append(CodexInteractionOption(
                    id: "__skip__",
                    label: "SKIP",
                    detail: "Bu isteğe bağlı alanı boş bırak"
                ))
            }
            return options
        }
        return activeInteraction?.options ?? []
    }

    var interactionInputIsSecret: Bool {
        currentInteractionQuestion?.isSecret ?? false
    }

    func isInteractionOptionChosen(_ optionID: String) -> Bool {
        guard let question = currentInteractionQuestion else { return false }
        return interactionAnswers[question.id, default: []].contains(optionID)
    }

    func toggleDetailActivity() {
        guard let threadID = detailThread?.id else { return }
        detailShowsActivity.toggle()
        defaults.set(detailShowsActivity, forKey: "commands-visible.\(threadID)")
        if !detailShowsActivity {
            detailActivityItems.removeAll { !$0.isChatVisible }
        }
        guard detailShowsActivity else { return }
        startActivityLoad(threadID: threadID)
    }

    func navigateInteraction(delta: Int) {
        guard activeInteraction != nil,
              !interactionTextVisible,
              !interactionResolving
        else { return }
        let count = currentInteractionOptions.count
        guard count > 0 else { return }
        interactionSelection = max(0, min(count - 1, interactionSelection + delta))
    }

    func activateInteractionSelection() {
        guard let request = activeInteraction,
              !interactionTextVisible,
              !interactionResolving
        else { return }
        let options = currentInteractionOptions
        guard !options.isEmpty else { return }
        let option = options[max(0, min(interactionSelection, options.count - 1))]

        if let question = currentInteractionQuestion {
            if option.id == "__skip__" {
                interactionAnswers.removeValue(forKey: question.id)
                advanceInteractionQuestion(request)
                return
            }
            if option.id == "__done__" {
                guard !(interactionAnswers[question.id] ?? []).isEmpty else {
                    interactionError = "En az bir seçenek seç."
                    return
                }
                advanceInteractionQuestion(request)
                return
            }
            if option.id == "__other__" {
                interactionText = ""
                interactionTextVisible = true
                interactionError = nil
                DispatchQueue.main.async { [weak self] in self?.interactionFocusToken &+= 1 }
                return
            }
            if question.allowsMultiple {
                var selected = interactionAnswers[question.id, default: []]
                if let index = selected.firstIndex(of: option.id) {
                    selected.remove(at: index)
                } else {
                    selected.append(option.id)
                }
                interactionAnswers[question.id] = selected
                interactionError = nil
                return
            }
            interactionAnswers[question.id] = [option.id]
            advanceInteractionQuestion(request)
            return
        }

        if request.kind == .mcpURL,
           option.id == "accept",
           let url = URL(string: request.detail),
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        resolveInteraction(request, with: .option(option.id))
    }

    func submitInteractionText() {
        guard let request = activeInteraction,
              let question = currentInteractionQuestion,
              interactionTextVisible,
              !interactionResolving
        else { return }
        let value = interactionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            cancelInteractionText()
            return
        }
        guard validateInteractionText(value, for: question) else { return }
        if question.allowsMultiple {
            var values = interactionAnswers[question.id, default: []]
            if !values.contains(value) { values.append(value) }
            interactionAnswers[question.id] = values
        } else {
            interactionAnswers[question.id] = [value]
        }
        interactionText = ""
        interactionTextVisible = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        if question.allowsMultiple {
            interactionSelection = max(0, currentInteractionOptions.count - 1)
            interactionError = nil
        } else {
            advanceInteractionQuestion(request)
        }
    }

    func cancelInteractionText() {
        interactionText = ""
        interactionTextVisible = false
        interactionError = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func declineActiveInteraction() {
        guard let request = activeInteraction,
              !interactionTextVisible,
              !interactionResolving
        else { return }
        let decision: String
        switch request.kind {
        case .mcpForm, .mcpURL: decision = "decline"
        case .commandApproval, .fileApproval, .permissionApproval: decision = "decline"
        case .userInput:
            interactionError = "Bu soruya yanıt vermeden pencere kapatılamaz; bir seçenek seç veya turu Codex'ten durdur."
            return
        }
        resolveInteraction(request, with: .option(decision))
    }

    private func advanceInteractionQuestion(_ request: CodexInteractionRequest) {
        if interactionQuestionIndex + 1 < request.questions.count {
            interactionQuestionIndex += 1
            interactionSelection = 0
            interactionError = nil
            return
        }
        switch request.kind {
        case .mcpForm:
            guard let content = makeMCPFormContent(request) else { return }
            resolveInteraction(
                request,
                with: .form(
                    action: "accept",
                    content: content
                )
            )
        default:
            resolveInteraction(request, with: .answers(interactionAnswers))
        }
    }

    private func validateInteractionText(
        _ text: String,
        for question: CodexInteractionQuestion
    ) -> Bool {
        switch question.valueType {
        case .integer where Int(text) == nil:
            interactionError = "Tam sayı girmen gerekiyor."
            return false
        case .number where Double(text) == nil:
            interactionError = "Sayısal bir değer girmen gerekiyor."
            return false
        case .boolean where Bool(text.lowercased()) == nil:
            interactionError = "TRUE veya FALSE seç."
            return false
        default:
            return true
        }
    }

    private func makeMCPFormContent(
        _ request: CodexInteractionRequest
    ) -> [String: CodexFormValue]? {
        var content: [String: CodexFormValue] = [:]
        for question in request.questions {
            let values = interactionAnswers[question.id, default: []]
            guard let first = values.first else {
                if !question.isRequired { continue }
                interactionError = "\(question.header) alanı eksik."
                return nil
            }
            switch question.valueType {
            case .string: content[question.id] = .string(first)
            case .integer:
                guard let value = Int(first) else {
                    interactionError = "\(question.header) tam sayı olmalı."
                    return nil
                }
                content[question.id] = .integer(value)
            case .number:
                guard let value = Double(first) else {
                    interactionError = "\(question.header) sayı olmalı."
                    return nil
                }
                content[question.id] = .number(value)
            case .boolean:
                guard let value = Bool(first.lowercased()) else {
                    interactionError = "\(question.header) TRUE/FALSE olmalı."
                    return nil
                }
                content[question.id] = .boolean(value)
            case .stringArray:
                content[question.id] = .stringArray(values)
            }
        }
        return content
    }

    private func resolveInteraction(
        _ request: CodexInteractionRequest,
        with response: CodexInteractionResponse
    ) {
        interactionResolving = true
        interactionError = nil
        Task {
            do {
                try await client.resolveInteraction(requestID: request.requestID, response: response)
                completeInteraction(requestID: request.requestID)
            } catch {
                interactionResolving = false
                interactionError = "Yanıt gönderilemedi: \(error.localizedDescription)"
            }
        }
    }

    private func completeInteraction(requestID: CodexRequestID) {
        pendingInteractions.removeAll { $0.requestID == requestID }
        resetInteractionNavigation()
    }

    private func resetInteractionNavigation() {
        interactionSelection = 0
        interactionQuestionIndex = 0
        interactionAnswers = [:]
        interactionText = ""
        interactionTextVisible = false
        interactionResolving = false
        interactionError = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectDefaultInteractionOption()
    }

    private func selectDefaultInteractionOption() {
        guard let request = activeInteraction,
              request.questions.isEmpty,
              let defaultID = request.defaultOptionID,
              let index = request.options.firstIndex(where: { $0.id == defaultID })
        else { return }
        interactionSelection = index
    }

    func refreshSettingsData(refreshModelCatalog: Bool = false) async {
        guard !settingsRefreshing else { return }
        settingsRefreshing = true
        settingsLoading = true
        settingsError = nil
        defer {
            settingsRefreshing = false
            settingsLoading = false
        }

        var failures: [String] = []
        do {
            let models: [CodexModelDescriptor]
            if refreshModelCatalog,
               lastFreshModelCatalogAt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                models = try await CodexAppServer.readFreshModelCatalog()
                lastFreshModelCatalogAt = Date()
            } else if refreshModelCatalog, !codexModels.isEmpty {
                models = codexModels
            } else {
                models = try await client.listModels(limit: 100)
            }
            // A catalog update must not change the choice under the user's cursor.
            let selectedID = settingsIsChoosing && settingsRow == .model ? settingsPreviewChoice?.id : nil
            codexModels = models
            if let selectedID {
                settingsChoiceIndex = settingsChoices.firstIndex(where: { $0.id == selectedID }) ?? 0
            }
        } catch {
            failures.append("Model listesi alınamadı: \(error.localizedDescription)")
        }
        do {
            rateLimits = try await client.readRateLimits()
        } catch {
            failures.append("Limit bilgisi alınamadı: \(error.localizedDescription)")
        }
        do {
            accountUsage = try await client.readAccountUsage()
        } catch {
            // Token activity is supplemental. Rate-limit windows are the real
            // remaining allowance and remain usable when this endpoint is absent.
            NSLog("[Bavbav] Account usage unavailable: %@", error.localizedDescription)
        }
        settingsError = failures.first
    }

    func beginWriting(from panel: OverlayKind) {
        switch panel {
        case .projects:
            switch leftRoute {
            case .projects:
                guard
                    let id = leftInteraction.selectedID,
                    let project = projects.first(where: { $0.id == id })
                else { return }
                createWritableThread(in: project)
            case .chats:
                guard
                    let id = leftInteraction.selectedID,
                    let thread = projectChats.first(where: { $0.id == id })
                else { return }
                open(thread, beginWriting: true)
            }

        case .recents:
            guard
                let id = recentInteraction.selectedID,
                let thread = recentChats.first(where: { $0.id == id })
            else { return }
            open(thread, beginWriting: true)

        case .detail, .settings:
            guard activeInteraction == nil,
                  detailThread != nil
            else { return }
            detailHost = .centered
            queueModeVisible = false
            queueInteraction = ListInteractionState()
            composerVisible = true
            composerError = nil
            onOpenDetail?()
            if let threadID = detailThread?.id { requestComposerFocus(threadID: threadID) }

        case .chatgpt:
            activateSelection(.chatgpt)
            return
        }
    }

    func cancelWriting() {
        if let threadID = detailThread?.id {
            persistDraft(composerText, for: threadID)
        }
        composerVisible = false
        closeComposerTools(restoreFocus: false)
        composerError = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func submitMessage() {
        guard !composerImporting else {
            composerError = "Dosyalar hazırlanıyor; bitince gönderebilirsin."
            return
        }
        if !composerHasPayload {
            if let threadID = detailThread?.id {
                persistDraft("", for: threadID)
            }
            composerText = ""
            composerVisible = false
            closeComposerTools(restoreFocus: false)
            composerError = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
            return
        }
        guard
            let thread = detailThread,
            composerVisible
        else { return }

        let text = composerText
        let overrides = activeOverrides
        let attachments = composerAttachments
        let mode = composerMode
        setComposerAttachments([], for: thread.id)
        composerText = ""
        persistDraft("", for: thread.id)
        composerVisible = false
        closeComposerTools(restoreFocus: false)
        composerError = nil
        NSApp.keyWindow?.makeFirstResponder(nil)

        if shouldQueueCurrentMessage {
            enqueuePrompt(text: text, thread: thread, overrides: overrides, attachments: attachments, mode: mode)
            return
        }
        startNewTurn(thread: thread, text: text, overrides: overrides, attachments: attachments, mode: mode)
    }

    private func enqueuePrompt(
        text: String,
        thread: CodexThread,
        overrides: ThreadRuntimeOverrides,
        attachments: [ComposerAttachment] = [],
        mode: CodexCollaborationMode = .default
    ) {
        let prompt = QueuedPrompt(
            id: "bavbav-queue-\(UUID().uuidString)",
            threadID: thread.id,
            text: text,
            model: overrides.model,
            effort: overrides.effort,
            attachments: attachments,
            collaborationMode: mode
        )
        var queue = queuedPromptsByThreadID[thread.id] ?? []
        queue.append(prompt)
        queuedPromptsByThreadID[thread.id] = queue
        updateQueuedThreadRegistration(thread.id)
        if queueInteraction.selectedID == nil { queueInteraction.selectedID = prompt.id }
    }

    private func startNewTurn(
        thread: CodexThread,
        text: String,
        overrides: ThreadRuntimeOverrides,
        queuedOnFailure: QueuedPrompt? = nil,
        attachments: [ComposerAttachment] = [],
        mode: CodexCollaborationMode = .default
    ) {
        let localID = "bavbav-user-\(UUID().uuidString)"
        let threadID = thread.id
        let displayText = ComposerInput.displayText(text: text, attachments: attachments)
        if detailThread?.id == threadID {
            detailLoadTask?.cancel()
            detailLoadGeneration &+= 1
            detailLoading = false
            composerError = nil
            detailMessages.removeAll { $0.id == "read-error" }
            detailMessages.append(CodexMessage(id: localID, role: .user, text: displayText, timestamp: Date()))
        }
        // Notifications may precede the start RPC response. Capture the mode
        // before exposing a running turn, and never overwrite it with a late ack.
        turnModesByThreadID[threadID] = mode
        markThreadSending(threadID)
        optimisticUserMessages.append(OptimisticUserMessage(
            threadID: threadID,
            localID: localID,
            text: displayText
        ))

        Task {
            var destinationThread = thread
            do {
                let turn: CodexTurnStart
                do {
                    turn = try await client.startTurn(
                        threadID: threadID,
                        text: text,
                        model: overrides.model,
                        effort: overrides.effort,
                        clientUserMessageID: localID,
                        cwd: thread.cwd,
                        executionMode: .fullAccess,
                        attachments: attachments,
                        collaborationMode: mode
                    )
                } catch let clientError as CodexClientError where clientError.isActiveWriterConflict {
                    let previousRuntime = inheritedRuntime
                    let fork = try await client.forkThread(
                        id: threadID,
                        cwd: thread.cwd,
                        model: overrides.model,
                        ephemeral: false,
                        executionMode: .fullAccess
                    )
                    destinationThread = fork.thread
                    adoptFork(
                        fork,
                        replacing: thread,
                        overrides: overrides,
                        fallbackRuntime: previousRuntime
                    )
                    moveSendingState(from: threadID, to: fork.thread.id)
                    turnModesByThreadID[fork.thread.id] = mode
                    if let index = optimisticUserMessages.firstIndex(where: { $0.localID == localID }) {
                        optimisticUserMessages[index].threadID = fork.thread.id
                    }
                    turn = try await client.startTurn(
                        threadID: fork.thread.id,
                        text: text,
                        model: overrides.model,
                        effort: overrides.effort,
                        clientUserMessageID: localID,
                        cwd: fork.thread.cwd,
                        executionMode: .fullAccess,
                        attachments: attachments,
                        collaborationMode: mode
                    )
                }
                let destinationID = destinationThread.id
                if detailThread?.id == destinationID {
                    inheritedRuntime = ThreadRuntimeOverrides(
                        model: overrides.model ?? inheritedRuntime.model,
                        effort: overrides.effort ?? inheritedRuntime.effort
                    )
                }
                if sendingThreadIDs.contains(destinationID) {
                    activeTurnIDsByThreadID[destinationID] = turn.id
                }
                if turn.status != "inProgress" || !sendingThreadIDs.contains(destinationID) {
                    _ = clearThreadSending(destinationID, matching: turn.id)
                    let hasNext = !(queuedPromptsByThreadID[destinationID] ?? []).isEmpty
                    if detailThread?.id == destinationID, !hasNext {
                        reloadDetail(threadID: destinationID)
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.startNextQueuedPromptIfNeeded(threadID: destinationID)
                    }
                }
            } catch {
                let destinationID = destinationThread.id
                _ = clearThreadSending(threadID)
                _ = clearThreadSending(destinationID)
                let failedEchoID = optimisticUserMessages.first(where: { $0.localID == localID })?.serverID
                optimisticUserMessages.removeAll { $0.localID == localID }
                if detailThread?.id == destinationID {
                    detailMessages.removeAll { $0.id == localID || $0.id == failedEchoID }
                }
                if var queuedOnFailure {
                    queuedOnFailure.threadID = destinationID
                    queuedOnFailure.requiresRetry = true
                    insertQueuedPrompt(queuedOnFailure, at: 0)
                    if detailThread?.id == destinationID {
                        composerError = "Sıradaki prompt başlatılamadı: \(error.localizedDescription)"
                        reloadDetail(threadID: destinationID)
                    }
                } else {
                    // A late error must not overwrite a newer draft, including
                    // screenshots dropped while the original request was pending.
                    if !savedDraft(for: destinationID).isEmpty || !composerAttachments(for: destinationID).isEmpty {
                        insertQueuedPrompt(QueuedPrompt(id: localID, threadID: destinationID, text: text,
                            model: overrides.model, effort: overrides.effort, attachments: attachments,
                            collaborationMode: mode, requiresRetry: true), at: 0)
                        if detailThread?.id == destinationID {
                            composerError = "Gönderilemeyen mesaj kuyrukta korundu. Yeni taslağın değişmedi; Q ile kuyruğun içinden düzenleyebilirsin."
                        }
                        return
                    }
                    persistDraft(text, for: destinationID)
                    setComposerAttachments(attachments, for: destinationID)
                    setComposerMode(mode, for: destinationID)
                    if detailThread?.id == destinationID {
                        composerText = text
                        composerVisible = true
                        composerFocusToken &+= 1
                        composerError = writingErrorMessage(error)
                        reloadDetail(threadID: destinationID)
                    }
                }
            }
        }
    }

    private func steerQueuedPrompt(id: String) {
        guard let thread = detailThread,
              let turnID = activeTurnIDsByThreadID[thread.id],
              canSteerCurrentTurn,
              let originalIndex = currentQueuedPrompts.firstIndex(where: { $0.id == id })
        else { return }
        let prompt = currentQueuedPrompts[originalIndex]
        guard prompt.collaborationMode == turnModesByThreadID[thread.id] else {
            composerError = "Çalışma modu tur ortasında değişmez. Bu mesaj seçtiğin modla sıradaki turda gönderilecek."
            return
        }
        var queue = currentQueuedPrompts
        queue.remove(at: originalIndex)
        queuedPromptsByThreadID[thread.id] = queue
        updateQueuedThreadRegistration(thread.id)
        queueInteraction.selectedID = queue.indices.contains(originalIndex)
            ? queue[originalIndex].id
            : queue.last?.id

        let text = prompt.text
        let displayText = prompt.displayText
        let localID = "bavbav-steer-\(UUID().uuidString)"
        let threadID = thread.id
        detailLoadTask?.cancel()
        detailLoadGeneration &+= 1
        detailLoading = false
        composerError = nil
        steerSending = true
        optimisticUserMessages.append(OptimisticUserMessage(
            threadID: threadID,
            localID: localID,
            text: displayText
        ))
        detailMessages.removeAll { $0.id == "read-error" }
        detailMessages.append(CodexMessage(id: localID, role: .user, text: displayText, timestamp: Date()))
        Task {
            defer { steerSending = false }
            do {
                let returnedTurnID = try await client.steerTurn(
                    threadID: threadID,
                    turnID: turnID,
                    text: text,
                    clientUserMessageID: localID,
                    attachments: prompt.attachments
                )
                guard returnedTurnID == turnID else {
                    throw CodexClientError.invalidResponse("turn/steer farklı bir tur döndürdü")
                }
            } catch {
                let failedEchoID = optimisticUserMessages.first(where: { $0.localID == localID })?.serverID
                optimisticUserMessages.removeAll { $0.localID == localID }
                if detailThread?.id == threadID {
                    detailMessages.removeAll { $0.id == localID || $0.id == failedEchoID }
                    insertQueuedPrompt(prompt, at: originalIndex)
                    queueInteraction.selectedID = prompt.id
                    composerError = "Steer gönderilemedi: \(error.localizedDescription)"
                } else {
                    insertQueuedPrompt(prompt, at: originalIndex)
                }
            }
        }
    }

    private func insertQueuedPrompt(_ prompt: QueuedPrompt, at index: Int) {
        var queue = queuedPromptsByThreadID[prompt.threadID] ?? []
        guard !queue.contains(where: { $0.id == prompt.id }) else { return }
        queue.insert(prompt, at: min(max(0, index), queue.count))
        queuedPromptsByThreadID[prompt.threadID] = queue
        updateQueuedThreadRegistration(prompt.threadID)
    }

    private func startNextQueuedPromptIfNeeded(threadID: String) {
        guard !sendingThreadIDs.contains(threadID),
              activeTurnIDsByThreadID[threadID] == nil
        else { return }
        let nextThreadID: String
        if !(queuedPromptsByThreadID[threadID] ?? []).isEmpty {
            nextThreadID = threadID
        } else if let queued = queuedThreadOrder.first(where: {
            !(queuedPromptsByThreadID[$0] ?? []).isEmpty
                && !sendingThreadIDs.contains($0)
                && activeTurnIDsByThreadID[$0] == nil
        }) {
            nextThreadID = queued
        } else {
            return
        }
        guard var queue = queuedPromptsByThreadID[nextThreadID], !queue.isEmpty else { return }
        guard !queue[0].requiresRetry else { return }
        let prompt = queue.removeFirst()
        queuedPromptsByThreadID[nextThreadID] = queue
        updateQueuedThreadRegistration(nextThreadID)
        if detailThread?.id == nextThreadID {
            queueInteraction.selectedID = queue.first?.id
        }
        guard let thread = threadForID(nextThreadID) else {
            insertQueuedPrompt(prompt, at: 0)
            return
        }
        startNewTurn(
            thread: thread,
            text: prompt.text,
            overrides: ThreadRuntimeOverrides(model: prompt.model, effort: prompt.effort),
            queuedOnFailure: prompt,
            attachments: prompt.attachments,
            mode: prompt.collaborationMode
        )
    }

    func queuedPromptCount(for threadID: String) -> Int {
        queuedPromptsByThreadID[threadID]?.count ?? 0
    }

    private func updateQueuedThreadRegistration(_ threadID: String) {
        let hasPrompts = !(queuedPromptsByThreadID[threadID] ?? []).isEmpty
        if hasPrompts {
            if !queuedThreadOrder.contains(threadID) { queuedThreadOrder.append(threadID) }
        } else {
            queuedThreadOrder.removeAll { $0 == threadID }
        }
    }

    private func threadForID(_ threadID: String) -> CodexThread? {
        if detailThread?.id == threadID { return detailThread }
        return allThreads.first(where: { $0.id == threadID })
            ?? recentChats.first(where: { $0.id == threadID })
            ?? projectChats.first(where: { $0.id == threadID })
    }

    private func markThreadSending(_ threadID: String, turnID: String? = nil) {
        sendingThreadIDs.insert(threadID)
        if let turnID { activeTurnIDsByThreadID[threadID] = turnID }
        messageSending = !sendingThreadIDs.isEmpty
        updateRunningChatCount()
    }

    private func updateRunningChatCount() {
        let running = sendingThreadIDs.union(activeTurnIDsByThreadID.keys)
        let waiting = Set(pendingInteractions.map(\.threadID))
        let count = running.subtracting(waiting).count
        if runningChatCount != count { runningChatCount = count }
    }

    private func moveSendingState(from sourceThreadID: String, to destinationThreadID: String) {
        let turnID = activeTurnIDsByThreadID.removeValue(forKey: sourceThreadID)
        sendingThreadIDs.remove(sourceThreadID)
        markThreadSending(destinationThreadID, turnID: turnID)
    }

    @discardableResult
    private func clearThreadSending(_ threadID: String, matching turnID: String? = nil) -> Bool {
        if let turnID,
           let trackedTurnID = activeTurnIDsByThreadID[threadID],
           trackedTurnID != turnID {
            return false
        }
        let wasTracked = sendingThreadIDs.remove(threadID) != nil
            || activeTurnIDsByThreadID[threadID] != nil
        activeTurnIDsByThreadID.removeValue(forKey: threadID)
        messageSending = !sendingThreadIDs.isEmpty
        updateRunningChatCount()
        return wasTracked
    }

    var settingsChoices: [SettingsChoice] {
        switch settingsRow {
        case .model:
            let models = codexModels.filter { $0.model == "gpt-6-astra" }
                + codexModels.filter { $0.model != "gpt-6-astra" }
            return [SettingsChoice(
                id: "model.inherit",
                label: "AUTO · \(automaticModelName.uppercased())",
                detail: "FOLLOWS CHAT'S LAST MODEL",
                value: nil
            )] + models.map { model in
                SettingsChoice(
                    id: "model.\(model.id)",
                    label: model.model == "gpt-6-astra" ? "GPT-6 ASTRA" : model.displayName.uppercased(),
                    detail: model.description,
                    value: model.model
                )
            }
        case .effort:
            return [SettingsChoice(
                id: "effort.inherit",
                label: "AUTO · \(automaticEffortName.uppercased())",
                detail: "FOLLOWS CHAT'S LAST EFFORT",
                value: nil
            )] + supportedEfforts.map { effort in
                SettingsChoice(
                    id: "effort.\(effort.id)",
                    label: effort.id.uppercased(),
                    detail: effort.description,
                    value: effort.id
                )
            }
        }
    }

    var settingsPreviewChoice: SettingsChoice? {
        let choices = settingsChoices
        guard !choices.isEmpty else { return nil }
        return choices[max(0, min(settingsChoiceIndex, choices.count - 1))]
    }

    var modelIsSet: Bool { activeOverrides.model != nil }
    var effortIsSet: Bool { activeOverrides.effort != nil }
    var modelIsAutomatic: Bool { activeOverrides.model == nil && inheritedRuntime.model != nil }
    var effortIsAutomatic: Bool { activeOverrides.effort == nil && inheritedRuntime.effort != nil }

    var effectiveModelName: String {
        guard detailThread != nil else { return "—" }
        let identifier = activeOverrides.model ?? inheritedRuntime.model ?? defaultModel?.model
        guard let identifier else { return "DETECTING" }
        return codexModels.first(where: { $0.model == identifier })?.displayName ?? identifier
    }

    var effectiveEffortName: String {
        guard detailThread != nil else { return "—" }
        return activeOverrides.effort
            ?? inheritedRuntime.effort
            ?? effectiveModel?.defaultReasoningEffort
            ?? "DETECTING"
    }

    private var defaultModel: CodexModelDescriptor? {
        codexModels.first(where: \.isDefault) ?? codexModels.first
    }

    private var effectiveModel: CodexModelDescriptor? {
        guard let configured = activeOverrides.model ?? inheritedRuntime.model else { return defaultModel }
        return codexModels.first(where: { $0.model == configured }) ?? defaultModel
    }

    private var automaticModelName: String {
        guard let identifier = inheritedRuntime.model ?? defaultModel?.model else { return "DETECTING" }
        return codexModels.first(where: { $0.model == identifier })?.displayName ?? identifier
    }

    private var automaticEffortName: String {
        inheritedRuntime.effort ?? effectiveModel?.defaultReasoningEffort ?? "DETECTING"
    }

    private var supportedEfforts: [CodexReasoningEffort] {
        effectiveModel?.supportedReasoningEfforts ?? []
    }

    private func settingsNavigate(delta: Int) {
        if settingsIsChoosing {
            let count = settingsChoices.count
            guard count > 0 else { return }
            settingsChoiceIndex = max(0, min(count - 1, settingsChoiceIndex + delta))
            return
        }
        let rows = SettingsRow.allCases
        let current = rows.firstIndex(of: settingsRow) ?? 0
        settingsRow = rows[max(0, min(rows.count - 1, current + delta))]
    }

    private func settingsSpace() {
        guard detailThread != nil else {
            settingsError = "Önce yazılabilir bir Codex sohbeti aç."
            return
        }
        let choices = settingsChoices
        guard !choices.isEmpty else { return }

        if !settingsIsChoosing {
            let selectedValue = settingsRow == .model ? activeOverrides.model : activeOverrides.effort
            settingsChoiceIndex = choices.firstIndex(where: { $0.value == selectedValue }) ?? 0
            settingsIsChoosing = true
            return
        }

        let value = choices[max(0, min(settingsChoiceIndex, choices.count - 1))].value
        switch settingsRow {
        case .model:
            activeOverrides.model = value
            let allowed = Set(supportedEfforts.map(\.id))
            if let effort = activeOverrides.effort, !allowed.contains(effort) {
                activeOverrides.effort = nil
            }
        case .effort:
            activeOverrides.effort = value
        }
        saveCurrentOverrides()
        settingsIsChoosing = false
        settingsChoiceIndex = 0
        settingsError = nil
    }

    private func createWritableThread(in project: CodexProject) {
        guard !creatingWritableThread else { return }
        creatingWritableThread = true
        Task {
            defer { creatingWritableThread = false }
            do {
                let thread = try await client.startThread(
                    cwd: project.path,
                    sandbox: "danger-full-access",
                    approvalPolicy: "never"
                )
                allThreads.insert(thread, at: 0)
                updateChatCatalogs()
                open(thread, beginWriting: true)
            } catch {
                connection = .failed("Yeni sohbet açılamadı: \(error.localizedDescription)")
            }
        }
    }

    private func createNamedChat(_ name: String, in project: CodexProject) async throws {
        let thread = try await client.startThread(
            cwd: project.path,
            sandbox: "danger-full-access",
            approvalPolicy: "never"
        )
        try await client.setThreadName(id: thread.id, name: name)
        let namedThread = renamedThread(thread, name: name)
        allThreads.removeAll { $0.id == namedThread.id }
        allThreads.insert(namedThread, at: 0)
        projectChats.removeAll { $0.id == namedThread.id }
        projectChats.insert(namedThread, at: 0)
        updateChatCatalogs()
        leftInteraction = ListInteractionState(selectedID: namedThread.id)
        open(namedThread, beginWriting: true)
    }

    private func createNamedProject(_ name: String) async throws {
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw NSError(
                domain: "Bavbav.ProjectCreation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Proje adında / veya : kullanma."]
            )
        }
        let parent: URL = {
            if let selectedID = leftInteraction.selectedID,
               let selected = projects.first(where: { $0.id == selectedID }) {
                return URL(fileURLWithPath: selected.path).deletingLastPathComponent()
            }
            if let first = projects.first {
                return URL(fileURLWithPath: first.path).deletingLastPathComponent()
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("ChatGPT", isDirectory: true)
        }()
        let projectURL = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: projectURL.path) else {
            throw NSError(
                domain: "Bavbav.ProjectCreation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Bu isimde bir proje klasörü zaten var."]
            )
        }

        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let thread = try await client.startThread(
            cwd: projectURL.path,
            sandbox: "danger-full-access",
            approvalPolicy: "never"
        )
        try await client.setThreadName(id: thread.id, name: "Yeni sohbet")
        let namedThread = renamedThread(thread, name: "Yeni sohbet")
        let project = CodexProject(
            id: thread.projectID ?? "cwd:\(projectURL.path)",
            name: name,
            path: projectURL.path,
            chatCount: 1
        )
        projects.removeAll { ProjectCatalog.canonicalPath($0.path) == projectURL.path }
        projects.append(project)
        saveOrder(projects.map(\.id), key: "order.projects")
        allThreads.removeAll { $0.id == namedThread.id }
        allThreads.insert(namedThread, at: 0)
        updateChatCatalogs()
        leftRoute = .chats(project)
        projectChats = [namedThread]
        leftInteraction = ListInteractionState(selectedID: namedThread.id)
        open(namedThread, beginWriting: true)
    }

    private func renamedThread(_ thread: CodexThread, name: String, updatedAt: Date = Date()) -> CodexThread {
        CodexThread(
            id: thread.id,
            projectID: thread.projectID,
            cwd: thread.cwd,
            title: name,
            preview: thread.preview,
            updatedAt: updatedAt,
            state: thread.state,
            hasMessages: thread.hasMessages
        )
    }

    func handleServerEvent(_ event: CodexServerEvent) {
        // Capture above the selected-thread guards: Q and window switching must
        // not affect the journal. Only conversation items, never commands/tools.
        switch event {
        case .turnStarted(let threadID, let turnID):
            observeJournal(threadID: threadID, turnID: turnID)
        case .itemStarted(let threadID, let turnID, let message) where message.role == .user && message.kind.isConversation:
            observeJournal(threadID: threadID, turnID: turnID, message: message)
        case .itemCompleted(let threadID, let turnID, let message) where message.kind.isConversation:
            observeJournal(threadID: threadID, turnID: turnID, message: message)
        case .turnCompleted(let threadID, let turnID, let status, _):
            journal.finish(threadID: threadID, turnID: turnID, succeeded: status == "completed")
        default: break
        }
        switch event {
        case .turnStarted(let threadID, let turnID):
            markThreadSending(threadID, turnID: turnID)

        case .itemStarted(let threadID, _, let message):
            guard detailThread?.id == threadID else { return }
            detailOperation = message.title ?? (message.kind == .reasoning ? "THINKING" : "WORKING")
            upsertActivity(message)
            if message.kind.isConversation { mergeConversationEvent(message, threadID: threadID) }

        case .agentMessageDelta(let threadID, _, let itemID, let delta):
            guard detailThread?.id == threadID else { return }
            appendDelta(
                id: itemID,
                delta: delta,
                kind: .agent,
                title: nil,
                includeInConversation: true
            )

        case .itemTextDelta(let threadID, _, let itemID, let kind, let title, let delta):
            guard detailThread?.id == threadID else { return }
            appendDelta(
                id: itemID,
                delta: delta,
                kind: kind,
                title: title,
                includeInConversation: false
            )

        case .itemCompleted(let threadID, _, let message):
            guard detailThread?.id == threadID else { return }
            upsertActivity(message)
            if message.kind.isConversation {
                mergeConversationEvent(message, threadID: threadID)
            }

        case .turnDiffUpdated(let threadID, let turnID, let diff):
            guard detailThread?.id == threadID else { return }
            upsertActivity(CodexMessage(
                id: "turn-diff-\(turnID)",
                role: .agent,
                text: diff,
                kind: .diff,
                title: "WORKTREE DIFF",
                status: "UPDATED"
            ))

        case .turnCompleted(let threadID, let turnID, let status, let error):
            let finishedTrackedTurn = clearThreadSending(threadID, matching: turnID)
            optimisticUserMessages.removeAll { $0.threadID == threadID }
            let continuesWithQueue = finishedTrackedTurn
                && !(queuedPromptsByThreadID[threadID] ?? []).isEmpty
            if finishedTrackedTurn {
                DispatchQueue.main.async { [weak self] in
                    self?.startNextQueuedPromptIfNeeded(threadID: threadID)
                }
            }
            guard detailThread?.id == threadID else { return }
            if status == "failed" || status == "interrupted" {
                composerError = error ?? "Codex yanıtı \(status)."
            }
            refreshComposerGoal()
            Task {
                if !continuesWithQueue {
                    reloadDetail(threadID: threadID)
                    startActivityLoad(threadID: threadID)
                }
                await refreshRateLimitsOnly()
            }

        case .rateLimitsUpdated(let limits):
            rateLimits = limits

        case .interactionRequested(let request):
            pendingInteractions.removeAll { $0.requestID == request.requestID }
            pendingInteractions.append(request)
            if detailThread?.id == request.threadID {
                composerVisible = false
                closeComposerTools(restoreFocus: false)
                queueModeVisible = false
                queueInteraction = ListInteractionState()
                composerError = nil
                resetInteractionNavigation()
            }

        case .interactionResolved(let requestID, _):
            completeInteraction(requestID: requestID)

        case .warning(let threadID, let message):
            if threadID == nil || detailThread?.id == threadID {
                let warning = CodexMessage(
                    id: "warning-\(UUID().uuidString)",
                    role: .agent,
                    text: message,
                    kind: .system,
                    title: "SYSTEM WARNING",
                    status: "ATTENTION"
                )
                detailActivityItems.append(warning)
                if detailShowsActivity { composerError = message }
            }

        case .transportClosed(let message):
            let interruptedThreadIDs = sendingThreadIDs
            activeTurnIDsByThreadID = [:]
            sendingThreadIDs = []
            messageSending = false
            optimisticUserMessages = []
            pendingInteractions = []
            resetInteractionNavigation()
            connection = .failed(message)
            if let detailThreadID = detailThread?.id,
               interruptedThreadIDs.contains(detailThreadID) {
                composerError = "Codex bağlantısı kapandı; son mesajın durumu doğrulanamadı."
            }
        }
    }

    private func observeJournal(threadID: String, turnID: String, message: CodexMessage? = nil) {
        guard let thread = allThreads.first(where: { $0.id == threadID })
                ?? (detailThread?.id == threadID ? detailThread : nil)
                ?? standaloneChats.first(where: { $0.id == threadID }) else { return }
        journal.observe(thread: thread, turnID: turnID, channel: isStandalone(thread) ? "ChatGPT" : "CODEX", message: message)
    }

    private func upsertConversation(_ message: CodexMessage) {
        let message = datedMessage(message, isLive: true)
        conversationRevision &+= 1
        if let index = detailMessages.firstIndex(where: { $0.id == message.id }) {
            detailMessages[index] = message
        } else {
            detailMessages.append(message)
        }
    }

    private func mergeConversationEvent(_ message: CodexMessage, threadID: String) {
        let message = datedMessage(message, isLive: true)
        conversationRevision &+= 1
        if MessageReconciler.mergeUserEcho(
            messages: &detailMessages,
            incoming: message,
            threadID: threadID,
            pending: &optimisticUserMessages
        ) {
            return
        }
        upsertConversation(message)
    }

    private func upsertActivity(_ message: CodexMessage) {
        guard detailShowsActivity || message.isChatVisible else { return }
        let message = datedMessage(message, isLive: true)
        activityRevision &+= 1
        if let index = detailActivityItems.firstIndex(where: { $0.id == message.id }) {
            detailActivityItems[index] = message
        } else {
            detailActivityItems.append(message)
        }
    }

    private func appendDelta(
        id: String,
        delta: String,
        kind: CodexMessageKind,
        title: String?,
        includeInConversation: Bool
    ) {
        guard detailShowsActivity || kind.isChatVisible || includeInConversation else { return }
        let currentActivity = detailActivityItems.first(where: { $0.id == id })
        let activity = CodexMessage(
            id: id,
            role: kind == .user ? .user : .agent,
            text: (currentActivity?.text ?? "") + delta,
            kind: kind,
            title: currentActivity?.title ?? title,
            status: currentActivity?.status
        )
        upsertActivity(activity)
        guard includeInConversation else { return }
        let currentMessage = detailMessages.first(where: { $0.id == id })
        upsertConversation(CodexMessage(
            id: id,
            role: .agent,
            text: (currentMessage?.text ?? "") + delta,
            kind: .agent
        ))
    }

    private func reloadDetail(threadID: String) {
        startDetailLoad(threadID: threadID)
    }

    private func startDetailLoad(threadID: String) {
        detailLoadTask?.cancel()
        detailLoadGeneration &+= 1
        let generation = detailLoadGeneration
        let revision = conversationRevision
        detailReadInFlight = true
        detailLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == detailLoadGeneration { detailReadInFlight = false }
            }
            do {
                try Task.checkCancellation()
                let messages = try await client.readThread(id: threadID)
                guard !Task.isCancelled,
                      detailThread?.id == threadID,
                      generation == detailLoadGeneration
                else { return }
                if revision == conversationRevision {
                    detailMessages = messages.filter { $0.kind.isConversation }.map { self.datedMessage($0) }
                }
                detailLoading = false
            } catch {
                guard !Task.isCancelled,
                      detailThread?.id == threadID,
                      generation == detailLoadGeneration
                else { return }
                composerError = "Sohbet yenilenemedi: \(error.localizedDescription)"
                detailLoading = false
            }
        }
    }

    private func startActivityLoad(threadID: String) {
        activityLoadTask?.cancel()
        activityLoadGeneration &+= 1
        let generation = activityLoadGeneration
        let revision = activityRevision
        activityReadInFlight = true
        detailActivityLoading = detailActivityItems.isEmpty
        activityLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == activityLoadGeneration { activityReadInFlight = false }
            }
            do {
                try Task.checkCancellation()
                let items = try await client.readThreadActivity(id: threadID)
                guard !Task.isCancelled,
                      detailThread?.id == threadID,
                      generation == activityLoadGeneration
                else { return }
                let retained = items.filter { self.detailShowsActivity || $0.isChatVisible }
                    .map { self.datedMessage($0) }
                if revision == activityRevision {
                    detailActivityItems = retained
                } else {
                    // History may finish after live deltas. Keep the loaded prefix
                    // and overlay newer rows rather than dropping all history.
                    let live = Dictionary(detailActivityItems.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    let loadedIDs = Set(retained.map(\.id))
                    detailActivityItems = retained.map { live[$0.id] ?? $0 }
                        + detailActivityItems.filter { !loadedIDs.contains($0.id) }
                }
                detailActivityLoading = false
            } catch {
                guard !Task.isCancelled,
                      detailThread?.id == threadID,
                      generation == activityLoadGeneration
                else { return }
                interactionError = "Etkinlik geçmişi yüklenemedi: \(error.localizedDescription)"
                detailActivityLoading = false
            }
        }
    }

    private func datedMessage(_ message: CodexMessage, isLive: Bool = false) -> CodexMessage {
        guard message.kind.isConversation, let threadID = detailThread?.id else { return message }
        var result = message
        let key = "message-time.\(threadID).\(message.id)"
        let stored = defaults.object(forKey: key) as? Double
        result.timestamp = message.timestamp
            ?? stored.map { Date(timeIntervalSince1970: $0) }
            ?? (isLive ? Date() : nil)
        if stored == nil, let timestamp = result.timestamp {
            defaults.set(timestamp.timeIntervalSince1970, forKey: key)
        }
        return result
    }

    private func refreshRateLimitsOnly() async {
        do {
            rateLimits = try await client.readRateLimits()
        } catch {
            NSLog("[Bavbav] Rate limit refresh failed: %@", error.localizedDescription)
        }
    }

    private func writingErrorMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        return "Mesaj gönderilemedi: \(description)"
    }

    private func loadOverrides(for threadID: String) {
        guard
            let data = defaults.data(forKey: overridesKey(threadID)),
            let decoded = try? JSONDecoder().decode(ThreadRuntimeOverrides.self, from: data)
        else {
            activeOverrides = .inherited
            return
        }
        activeOverrides = decoded
    }

    private func saveCurrentOverrides() {
        guard let threadID = detailThread?.id else { return }
        if let data = try? JSONEncoder().encode(activeOverrides) {
            defaults.set(data, forKey: overridesKey(threadID))
        }
    }

    private func overridesKey(_ threadID: String) -> String {
        "runtime.overrides.\(threadID)"
    }

    private func persistDraft(_ text: String, for threadID: String) {
        if text.isEmpty {
            draftsByThreadID.removeValue(forKey: threadID)
            defaults.removeObject(forKey: draftKey(threadID))
        } else {
            draftsByThreadID[threadID] = text
            defaults.set(text, forKey: draftKey(threadID))
        }
    }

    private func savedDraft(for threadID: String) -> String {
        if let cached = draftsByThreadID[threadID] { return cached }
        let saved = defaults.string(forKey: draftKey(threadID)) ?? ""
        if !saved.isEmpty { draftsByThreadID[threadID] = saved }
        return saved
    }

    private func draftKey(_ threadID: String) -> String {
        "draft.\(threadID)"
    }

    private func startRuntimeLoad(threadID: String) {
        runtimeLoadTask?.cancel()
        runtimeLoadGeneration &+= 1
        let generation = runtimeLoadGeneration
        inheritedRuntime = .inherited
        runtimeLoadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let runtime = try await client.readPersistedRuntime(threadID: threadID)
                guard !Task.isCancelled,
                      detailThread?.id == threadID,
                      generation == runtimeLoadGeneration
                else { return }
                inheritedRuntime = ThreadRuntimeOverrides(
                    model: runtime.model,
                    effort: runtime.effort
                )
            } catch {
                NSLog("[Bavbav] Runtime detection failed: %@", error.localizedDescription)
            }
        }
    }

    private func adoptFork(
        _ fork: CodexThreadFork,
        replacing source: CodexThread,
        overrides: ThreadRuntimeOverrides,
        fallbackRuntime: ThreadRuntimeOverrides
    ) {
        let target = fork.thread
        var movedExtras = draftExtras(for: source.id)
        let targetExtras = draftExtras(for: target.id)
        movedExtras.attachments += targetExtras.attachments.filter { next in !movedExtras.attachments.contains { $0.id == next.id } }
        saveExtras(movedExtras, for: target.id)
        saveExtras(ComposerDraftExtras(), for: source.id)
        if isStandalone(source) {
            standaloneIDs.insert(target.id)
            defaults.set(Array(standaloneIDs), forKey: "chat.standalone-ids")
        }
        saveThreadRedirect(from: source.id, to: target.id)

        if let sourceQueue = queuedPromptsByThreadID.removeValue(forKey: source.id) {
            let redirected = sourceQueue.map { prompt in
                QueuedPrompt(
                    id: prompt.id,
                    threadID: target.id,
                    text: prompt.text,
                    model: prompt.model,
                    effort: prompt.effort,
                    attachments: prompt.attachments,
                    collaborationMode: prompt.collaborationMode,
                    requiresRetry: prompt.requiresRetry
                )
            }
            queuedPromptsByThreadID[target.id, default: []].append(contentsOf: redirected)
            if let sourceIndex = queuedThreadOrder.firstIndex(of: source.id) {
                queuedThreadOrder[sourceIndex] = target.id
                var seen = Set<String>()
                queuedThreadOrder = queuedThreadOrder.filter { seen.insert($0).inserted }
            }
            updateQueuedThreadRegistration(source.id)
            updateQueuedThreadRegistration(target.id)
        }

        allThreads.removeAll { $0.id == source.id || $0.id == target.id }
        allThreads.insert(target, at: 0)
        projectChats = projectChats.map { $0.id == source.id ? target : $0 }
        recentChats = recentChats.map { $0.id == source.id ? target : $0 }
        if !recentChats.contains(where: { $0.id == target.id }) {
            recentChats.insert(target, at: 0)
            recentChats = Array(recentChats.prefix(8))
        }
        if leftInteraction.selectedID == source.id { leftInteraction.selectedID = target.id }
        if recentInteraction.selectedID == source.id { recentInteraction.selectedID = target.id }
        if chatGPTInteraction.selectedID == source.id { chatGPTInteraction.selectedID = target.id }
        updateChatCatalogs()

        if detailThread?.id == source.id {
            detailThread = target
            // Goals belong to server thread identities; do not display a source
            // goal as active on a fork without reading the actual destination.
            refreshComposerGoal()
            activeOverrides = overrides
            let detected = ThreadRuntimeOverrides(model: fork.runtime.model, effort: fork.runtime.effort)
            inheritedRuntime = detected == .inherited ? fallbackRuntime : detected
            onDetailThreadIdentityChanged?(source, target)
        }
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesKey(target.id))
        }
        let sourceDraft = savedDraft(for: source.id)
        if !sourceDraft.isEmpty, savedDraft(for: target.id).isEmpty { persistDraft(sourceDraft, for: target.id) }
        persistDraft("", for: source.id)
        if let goalDraft = defaults.string(forKey: "composer.goal-draft.\(source.id)"),
           defaults.string(forKey: "composer.goal-draft.\(target.id)") == nil {
            defaults.set(goalDraft, forKey: "composer.goal-draft.\(target.id)")
        }
    }

    private func visibleThreads(_ threads: [CodexThread]) -> [CodexThread] {
        guard let redirects = defaults.dictionary(forKey: "thread.redirects") as? [String: String]
        else { return threads }
        let ids = Set(threads.map(\.id))
        let hidden = Set(redirects.compactMap { source, target in ids.contains(target) ? source : nil })
        return threads.filter { !hidden.contains($0.id) }
    }

    private func saveThreadRedirect(from sourceID: String, to targetID: String) {
        var redirects = defaults.dictionary(forKey: "thread.redirects") as? [String: String] ?? [:]
        redirects[sourceID] = targetID
        defaults.set(redirects, forKey: "thread.redirects")
    }

    private func activate(id: String, in panel: OverlayKind) {
        switch panel {
        case .projects:
            switch leftRoute {
            case .projects:
                guard let project = projects.first(where: { $0.id == id }) else { return }
                leftRoute = .chats(project)
                projectChats = []
                leftInteraction = ListInteractionState()
                Task { await loadChats(for: project, preserveSelection: false) }
            case .chats:
                guard let thread = projectChats.first(where: { $0.id == id }) else { return }
                open(thread)
            }
        case .recents:
            guard let thread = recentChats.first(where: { $0.id == id }) else { return }
            open(thread)
        case .chatgpt:
            guard chatGPTMenuIDs.contains(id) else { return }
            if id == Self.chatGPTLauncherID {
                createStandaloneChat()
            } else if let thread = standaloneChats.first(where: { $0.id == id }) {
                open(thread)
            }
        case .settings:
            settingsSpace()
        case .detail:
            break
        }
    }

    private func open(
        _ thread: CodexThread,
        presentDetail: Bool = true,
        beginWriting: Bool = false
    ) {
        let targetHost: ChatDetailHost = presentDetail ? .centered : .dock
        if detailThread?.id == thread.id, detailHost == targetHost {
            detailHost = targetHost
            if beginWriting {
                queueModeVisible = false
                queueInteraction = ListInteractionState()
                composerVisible = true
                composerError = nil
            }
            if beginWriting {
                requestComposerFocus(threadID: thread.id)
            }
            syncVisibleConversation()
            if presentDetail { onOpenDetail?() }
            return
        }
        onWillOpenDetail?(thread, targetHost)
        closeComposerTools(restoreFocus: false)
        composerExtras[thread.id] = draftExtras(for: thread.id)
        detailFocusGeneration &+= 1
        let cached = onDetailSnapshotRequested?(thread.id)
        if let currentID = detailThread?.id, currentID != thread.id {
            persistDraft(composerText, for: currentID)
            defaults.set(detailShowsActivity, forKey: "commands-visible.\(currentID)")
        }
        detailThread = thread
        composerText = savedDraft(for: thread.id)
        detailHost = targetHost
        loadOverrides(for: thread.id)
        detailMessages = cached?.conversation ?? []
        detailShowsActivity = defaults.bool(forKey: "commands-visible.\(thread.id)")
        detailActivityItems = (cached?.activity ?? []).filter { detailShowsActivity || $0.isChatVisible }
        detailOperation = nil
        detailLoading = cached?.items.isEmpty != false
        detailActivityLoading = false
        activityLoadTask?.cancel()
        activityLoadGeneration &+= 1
        activityReadInFlight = false
        composerVisible = beginWriting
        queueModeVisible = false
        queueInteraction = ListInteractionState()
        composerError = nil
        resetInteractionNavigation()
        if presentDetail { onOpenDetail?() }
        startDetailLoad(threadID: thread.id)
        startActivityLoad(threadID: thread.id)
        startRuntimeLoad(threadID: thread.id)
        if beginWriting {
            requestComposerFocus(threadID: thread.id)
        }
    }

    private func requestComposerFocus(threadID: String) {
        let generation = detailFocusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.detailThread?.id == threadID,
                  self.detailFocusGeneration == generation, self.composerVisible else { return }
            self.composerFocusToken &+= 1
        }
    }

    private func loadChats(for project: CodexProject, preserveSelection: Bool) async {
        projectChatsLoadGeneration &+= 1
        let generation = projectChatsLoadGeneration
        let nameRevision = threadNameRevision
        do {
            let fetched = reconcileFetchedNames(visibleThreads(try await client.listThreads(limit: 2_000, cwd: project.path)), since: nameRevision)
            guard case .chats(let currentProject) = leftRoute,
                  currentProject.id == project.id,
                  generation == projectChatsLoadGeneration
            else { return }
            let ordered = applySavedOrder(fetched.filter { !self.isStandalone($0) }, key: threadOrderKey(project.id))
            projectChats = ordered
            if !preserveSelection || !ordered.contains(where: { $0.id == leftInteraction.selectedID }) {
                leftInteraction.selectedID = ordered.first?.id
            }
        } catch {
            guard case .chats(let currentProject) = leftRoute,
                  currentProject.id == project.id,
                  generation == projectChatsLoadGeneration
            else { return }
            projectChats = []
            connection = .failed(error.localizedDescription)
        }
    }

    private func reorderLeft(delta: Int) {
        let current = index(of: leftInteraction.selectedID, in: leftVisibleIDs)
        switch leftRoute {
        case .projects:
            let moved = StableOrdering.moved(projects, from: current, delta: delta)
            projects = moved.items
            leftInteraction.selectedID = projects[moved.index].id
        case .chats:
            let moved = StableOrdering.moved(projectChats, from: current, delta: delta)
            projectChats = moved.items
            leftInteraction.selectedID = projectChats[moved.index].id
        }
    }

    private func restoreLeftOrder() {
        guard let original = leftInteraction.originalIDs else { return }
        switch leftRoute {
        case .projects:
            projects = StableOrdering.reconcile(projects, preferredIDs: original)
        case .chats:
            projectChats = StableOrdering.reconcile(projectChats, preferredIDs: original)
        }
    }

    private func saveLeftOrder() {
        switch leftRoute {
        case .projects:
            saveOrder(projects.map(\.id), key: "order.projects")
        case .chats(let project):
            saveOrder(projectChats.map(\.id), key: threadOrderKey(project.id))
        }
    }

    private func threadOrderKey(_ projectID: String) -> String {
        "order.threads.\(projectID)"
    }

    private func applySavedOrder<T: Identifiable>(_ items: [T], key: String) -> [T] where T.ID == String {
        StableOrdering.reconcile(items, preferredIDs: defaults.stringArray(forKey: key) ?? [])
    }

    private func saveOrder(_ ids: [String], key: String) {
        defaults.set(ids, forKey: key)
    }

    private func ensureSelections() {
        if !projects.contains(where: { $0.id == leftInteraction.selectedID }) {
            leftInteraction.selectedID = projects.first?.id
        }
        if !recentChats.contains(where: { $0.id == recentInteraction.selectedID }) {
            recentInteraction.selectedID = recentChats.first?.id
        }
        if !chatGPTMenuIDs.contains(where: { $0 == chatGPTInteraction.selectedID }) {
            chatGPTInteraction.selectedID = Self.chatGPTLauncherID
        }
    }

    private func adjacentID(current: String?, ids: [String], delta: Int) -> String {
        let currentIndex = index(of: current, in: ids)
        let next = max(0, min(ids.count - 1, currentIndex + delta))
        return ids[next]
    }

    private func index(of id: String?, in ids: [String]) -> Int {
        guard let id, let index = ids.firstIndex(of: id) else { return 0 }
        return index
    }
}
