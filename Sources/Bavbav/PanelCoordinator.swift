import AppKit
import BavbavCore
import SwiftUI

enum WindowDirection: Equatable {
    case up
    case left
    case down
    case right
}

/// AppKit can emit several key-window changes in one run-loop turn. Only the
/// latest still-current window may activate a conversation after that turn.
@MainActor
final class DeferredWindowFocus {
    private var generation = 0

    func cancel() { generation &+= 1 }

    func request(_ window: NSWindow,
                 isCurrent: @escaping @MainActor (NSWindow) -> Bool = { NSApp.keyWindow === $0 && $0.isVisible },
                 perform: @escaping @MainActor () -> Void) {
        cancel()
        let requestedGeneration = generation
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.generation == requestedGeneration,
                  let window, isCurrent(window) else { return }
            perform()
        }
    }
}

final class OverlayPanel: NSPanel, CornerResizeCommitHandler {
    let overlayKind: OverlayKind
    var representedThread: CodexThread?
    var chatPresentation: ChatWindowPresentation?
    var onUserResize: ((OverlayPanel) -> Void)?
    func cornerResizeDidFinish() { onUserResize?(self) }

    override var contentView: NSView? {
        get { super.contentView }
        set {
            guard let newValue else { super.contentView = nil; return }
            if newValue === super.contentView { return }
            // Keep corner drag targets alive when content is initially mounted.
            if let container = super.contentView as? CornerResizeContainer {
                container.setContent(newValue)
            } else {
                let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: frame.size))
                container.setContent(newValue)
                super.contentView = container
            }
        }
    }

    init(kind: OverlayKind, contentRect: NSRect) {
        self.overlayKind = kind
        super.init(
            contentRect: contentRect,
            // Keep the borderless, keyboard-first presentation, but participate
            // in the ordinary macOS window stack. Other apps must be able to
            // cover Bavbav as soon as the user returns to them.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .documentWindow
        collectionBehavior = [.moveToActiveSpace]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PanelCoordinator: NSObject, NSWindowDelegate {
    private(set) var activePanel: OverlayKind?
    var onPanelResigned: (() -> Void)?

    private let store: OverlayStore
    let appPreferences: AppPreferences
    let appSettings: AppSettingsController
    let journalWindow: JournalWindowController
    private let windowSizeDefaults: UserDefaults
    private let projectPanel: OverlayPanel
    private let recentPanel: OverlayPanel
    private let chatGPTPanel: OverlayPanel
    private let settingsPanel: OverlayPanel
    private let primaryDetailPanel: OverlayPanel
    private var activeDetailPanel: OverlayPanel?
    private var pendingDetailPanel: OverlayPanel?
    private var detailPanels: [String: OverlayPanel] = [:]
    private var detailOrder: [String] = []
    private var screenObserver: NSObjectProtocol?
    private var settingsReturnPanel: OverlayKind?
    private let deferredFocus = DeferredWindowFocus()

    var openDetailWindowCount: Int { detailPanels.count }

    private var managedWindows: [NSWindow] {
        [projectPanel, recentPanel, chatGPTPanel, settingsPanel, appSettings.window, journalWindow.window] + Array(detailPanels.values)
    }

    var hasVisibleWindows: Bool {
        !NSApp.isHidden && managedWindows.contains(where: { $0.isVisible && $0.alphaValue > 0 })
    }

    var allWindowsUseNormalLevel: Bool {
        (managedWindows + [primaryDetailPanel])
            .allSatisfy { ($0 as? NSPanel)?.isFloatingPanel != true && $0.level == .normal }
    }

    func isGroupOrderedAtFront(_ kind: OverlayKind) -> Bool {
        let primary = panel(for: kind)
        let related = relatedPanels(for: kind)
        guard related.allSatisfy(\.isVisible),
              activePanel == kind
        else { return false }
        let relatedIDs = Set(related.map(ObjectIdentifier.init))
        let ordered = NSApp.orderedWindows.compactMap { $0 as? OverlayPanel }
        // orderedWindows is empty for the launcher's no-menu headless test
        // process. Visibility + key ownership above still verify the group;
        // live builds additionally verify relative ordering here.
        guard !ordered.isEmpty else { return true }
        guard ordered.first === primary else { return false }
        let relatedIndexes = ordered.indices.filter {
            relatedIDs.contains(ObjectIdentifier(ordered[$0]))
        }
        let unrelatedIndexes = ordered.indices.filter {
            !relatedIDs.contains(ObjectIdentifier(ordered[$0]))
        }
        guard let lastRelated = relatedIndexes.max() else { return false }
        return unrelatedIndexes.min().map { lastRelated < $0 } ?? true
    }

    func groupOrderDescription() -> String {
        let panels = [projectPanel, recentPanel, chatGPTPanel, settingsPanel] + Array(detailPanels.values)
        return panels.map { panel in
            "\(panel.overlayKind):\(panel.isVisible ? "visible" : "hidden"):key=\(panel.isKeyWindow)"
        }.joined(separator: ",")
    }

    func isVisible(_ kind: OverlayKind) -> Bool {
        if kind == .detail { return activeDetailPanel?.isVisible == true }
        return panel(for: kind).isVisible
    }

    init(store: OverlayStore, windowSizeDefaults: UserDefaults = .standard) {
        self.store = store
        self.windowSizeDefaults = windowSizeDefaults
        appPreferences = AppPreferences(defaults: windowSizeDefaults)
        appSettings = AppSettingsController(preferences: appPreferences, defaults: windowSizeDefaults)
        journalWindow = JournalWindowController(service: store.journal, preferences: appPreferences, defaults: windowSizeDefaults)
        projectPanel = OverlayPanel(
            kind: .projects,
            contentRect: NSRect(x: 0, y: 0, width: 382, height: 438)
        )
        recentPanel = OverlayPanel(
            kind: .recents,
            contentRect: NSRect(x: 0, y: 0, width: 394, height: 438)
        )
        chatGPTPanel = OverlayPanel(
            kind: .chatgpt,
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 282)
        )
        settingsPanel = OverlayPanel(
            kind: .settings,
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280)
        )
        primaryDetailPanel = OverlayPanel(
            kind: .detail,
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 640)
        )
        super.init()

        projectPanel.contentView = NSHostingView(rootView: PanelAppearanceRoot(preferences: appPreferences, content: ProjectPanelView(store: store)))
        recentPanel.contentView = NSHostingView(rootView: PanelAppearanceRoot(preferences: appPreferences, content: RecentsPanelView(store: store)))
        chatGPTPanel.contentView = NSHostingView(rootView: PanelAppearanceRoot(preferences: appPreferences, content: ChatGPTPanelView(store: store)))
        settingsPanel.contentView = NSHostingView(rootView: PanelAppearanceRoot(preferences: appPreferences, content: ModelSettingsPanelView(store: store)))

        for panel in [projectPanel, recentPanel, chatGPTPanel, settingsPanel, primaryDetailPanel] {
            panel.delegate = self
            configureResizing(panel)
            applyTransparency(to: panel)
        }
        appSettings.window.delegate = self
        journalWindow.window.delegate = self
        appPreferences.onTransparencyChanged = { [weak self] _ in self?.applyTransparencyToAll() }
        appSettings.onCloseWithoutReturnWindow = { [weak self] in
            guard let self else { return }
            self.activePanel = nil
            if let detail = self.activeDetailPanel, detail.isVisible, detail.alphaValue > 0 {
                detail.makeKeyAndOrderFront(nil)
            } else {
                self.focusVisibleControlPanel()
            }
        }

        store.onWillOpenDetail = { [weak self] thread, host in
            self?.prepareDetailOpen(thread: thread, host: host)
        }
        store.onOpenDetail = { [weak self] in self?.completeDetailOpen() }
        store.onDetailSnapshotRequested = { [weak self] id in self?.detailPanels[id]?.chatPresentation?.snapshot }
        store.onDetailThreadIdentityChanged = { [weak self] source, target in
            self?.replaceDetailIdentity(from: source, to: target)
        }
        store.onThreadRenamed = { [weak self] thread in
            guard let panel = self?.detailPanels[thread.id] else { return }
            panel.representedThread = thread
            if let snapshot = panel.chatPresentation?.snapshot {
                panel.chatPresentation?.snapshot = snapshot.replacingThread(thread)
            }
            panel.title = thread.title
        }
        store.onChatGPTLayoutChanged = { [weak self] expanded in
            self?.setChatGPTExpanded(expanded, animated: true)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanels() }
        }
        positionPanels()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func toggle(_ kind: OverlayKind) {
        showGroup(kind)
    }

    /// Raise a numbered window and all of its still-open companion windows.
    /// The numbered window is ordered last so it receives keyboard focus.
    func showGroup(_ kind: OverlayKind) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let primary = panel(for: kind)
        for related in relatedPanels(for: kind) where related !== primary {
            related.orderFront(nil)
        }
        show(kind)
        // Explicit numbered shortcuts activate us; ordinary app switching stays
        // under macOS control, without ordering above an unrelated active app.
        primary.orderFront(nil)
        primary.makeKey()
        activePanel = kind
    }

    func show(_ kind: OverlayKind) {
        if kind == .detail {
            completeDetailOpen()
            return
        }
        if kind == .settings, activePanel != .settings {
            settingsReturnPanel = activePanel
        }
        let panel = panel(for: kind)
        if !panel.isVisible { position(panel, kind: kind) }
        panel.makeKeyAndOrderFront(nil)
        activePanel = kind
        if kind == .settings {
            Task { await store.refreshSettingsData(refreshModelCatalog: true) }
        }
    }

    func hide(_ kind: OverlayKind) {
        if kind == .detail {
            activeDetailPanel?.orderOut(nil)
        } else {
            panel(for: kind).orderOut(nil)
        }
        if kind == .settings,
           let returnKind = settingsReturnPanel,
           panel(for: returnKind).isVisible {
            settingsReturnPanel = nil
            activePanel = nil
            show(returnKind)
            return
        }
        if activePanel == kind {
            activePanel = nil
        }
    }

    func dismiss(_ kind: OverlayKind) {
        let returnToProjects: Bool
        if kind == .projects, case .chats = store.leftRoute {
            returnToProjects = true
        } else {
            returnToProjects = false
        }
        store.prepareToClose(kind)
        if returnToProjects { return }
        if kind == .detail {
            closeActiveDetail()
            return
        }
        hide(kind)
    }

    func hideAll() {
        // Native hiding retains window order and keyboard ownership so Cmd-Tab
        // can restore the same windows. Q remains the per-window close action.
        NSApp.hide(nil)
    }

    @discardableResult
    func focusWindow(in direction: WindowDirection) -> Bool {
        let keyed = NSApp.keyWindow.flatMap { key in managedWindows.first { $0 === key } }
        let active = activePanel.map { panel(for: $0) }
        guard let current = keyed ?? active,
              current.isVisible, current.alphaValue > 0
        else { return false }
        let currentCenter = NSPoint(x: current.frame.midX, y: current.frame.midY)
        var visible: [NSWindow] = []
        for panel in managedWindows
        where panel.isVisible && panel.alphaValue > 0 && panel !== current {
            if !visible.contains(where: { $0 === panel }) { visible.append(panel) }
        }

        let target = visible.compactMap { panel -> (NSWindow, CGFloat)? in
            let candidate = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let dx = candidate.x - currentCenter.x
            let dy = candidate.y - currentCenter.y
            let primary: CGFloat
            let perpendicular: CGFloat
            switch direction {
            case .up:
                primary = dy
                perpendicular = abs(dx)
            case .left:
                primary = -dx
                perpendicular = abs(dy)
            case .down:
                primary = -dy
                perpendicular = abs(dx)
            case .right:
                primary = dx
                perpendicular = abs(dy)
            }
            guard primary > 4 else { return nil }
            let distance = hypot(dx, dy)
            // Favor the intended row/column. A slightly offset window on the
            // wrong diagonal must not beat the clearly aligned destination.
            return (panel, distance + perpendicular * 4.0)
        }
        .min { $0.1 < $1.1 }?.0

        guard let target else { return false }
        target.makeKeyAndOrderFront(nil)
        let overlay = target as? OverlayPanel
        activePanel = overlay?.overlayKind
        // windowDidBecomeKey owns the single deferred conversation handoff.
        return true
    }

    func showInitialPanel() {
        show(.projects)
    }

    func showAppSettings() {
        onPanelResigned?()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        appSettings.show(in: targetScreen().visibleFrame)
        activePanel = nil
    }

    func showJournal() {
        onPanelResigned?()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        journalWindow.show(in: targetScreen().visibleFrame)
        activePanel = nil
    }

    private func applyTransparency(to panel: OverlayPanel) {
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.hasShadow = appPreferences.backgroundOpacity > 0
    }

    private func applyTransparencyToAll() {
        journalWindow.window.alphaValue = 1
        journalWindow.window.hasShadow = appPreferences.backgroundOpacity > 0
        for panel in [projectPanel, recentPanel, chatGPTPanel, settingsPanel, primaryDetailPanel] + Array(detailPanels.values) {
            applyTransparency(to: panel)
        }
    }

    func positionPanels() {
        journalWindow.position(in: targetScreen().visibleFrame)
        appSettings.position(in: targetScreen().visibleFrame)
        position(projectPanel, kind: .projects)
        position(recentPanel, kind: .recents)
        position(chatGPTPanel, kind: .chatgpt)
        position(settingsPanel, kind: .settings)
        for (index, id) in detailOrder.enumerated() {
            if let panel = detailPanels[id] { positionDetail(panel, cascadeIndex: index) }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        deferredFocus.cancel()
        if notification.object as? NSWindow === appSettings.window || notification.object as? NSWindow === journalWindow.window {
            activePanel = nil
            onPanelResigned?()
            return
        }
        guard let panel = notification.object as? OverlayPanel else { return }
        activePanel = panel.overlayKind
        guard panel.overlayKind == .detail,
              panel !== activeDetailPanel,
              let thread = panel.representedThread
        else { return }
        deferredFocus.request(panel) { [weak self, weak panel] in
            guard let self, panel?.representedThread?.id == thread.id else { return }
            self.store.focusDetailWindow(thread)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === appSettings.window || notification.object as? NSWindow === journalWindow.window { onPanelResigned?(); return }
        guard let panel = notification.object as? OverlayPanel, activePanel == panel.overlayKind else { return }
        onPanelResigned?()
    }

    private func panel(for kind: OverlayKind) -> OverlayPanel {
        switch kind {
        case .projects: return projectPanel
        case .recents: return recentPanel
        case .chatgpt: return chatGPTPanel
        case .settings: return settingsPanel
        case .detail: return activeDetailPanel ?? primaryDetailPanel
        }
    }

    private func relatedPanels(for kind: OverlayKind) -> [OverlayPanel] {
        let details = detailOrder.compactMap { detailPanels[$0] }
        switch kind {
        case .projects:
            return details + [projectPanel]
        case .recents:
            return details + [recentPanel]
        case .chatgpt:
            return [chatGPTPanel]
        case .settings:
            return (activeDetailPanel.map { [$0] } ?? []) + [settingsPanel]
        case .detail:
            return activeDetailPanel.map { [$0] } ?? []
        }
    }

    private func position(_ panel: NSPanel, kind: OverlayKind) {
        let screen = targetScreen()
        let frame = screen.visibleFrame
        let margin: CGFloat = 14

        switch kind {
        case .projects:
            let size = restoredSize(for: kind, fallback: NSSize(width: 382, height: 438), in: frame)
            panel.setFrame(NSRect(
                x: frame.minX + margin,
                y: frame.maxY - size.height - margin,
                width: size.width,
                height: size.height
            ), display: true)
        case .recents:
            let size = restoredSize(for: kind, fallback: NSSize(width: 394, height: 438), in: frame)
            panel.setFrame(NSRect(
                x: frame.maxX - size.width - margin,
                y: frame.maxY - size.height - margin,
                width: size.width,
                height: size.height
            ), display: true)
        case .chatgpt:
            panel.setFrame(chatGPTFrame(in: frame, expanded: store.chatGPTExpanded), display: true)
        case .settings:
            let size = restoredSize(for: kind, fallback: NSSize(width: 340, height: 280), in: frame)
            panel.setFrame(NSRect(
                x: frame.minX + margin,
                y: frame.minY + margin,
                width: size.width,
                height: size.height
            ), display: true)
        case .detail:
            let index = (panel as? OverlayPanel)?.representedThread
                .flatMap { detailOrder.firstIndex(of: $0.id) } ?? 0
            positionDetail(panel, cascadeIndex: index)
        }
    }

    private func prepareDetailOpen(thread: CodexThread, host: ChatDetailHost) {
        if store.detailHost == .centered,
           store.detailThread?.id != thread.id,
           let panel = activeDetailPanel,
            let snapshot = store.detailSnapshot() {
            panel.representedThread = snapshot.thread
            panel.chatPresentation?.snapshot = snapshot
            panel.chatPresentation?.isActive = false
        }

        guard host == .centered else {
            activeDetailPanel = nil
            pendingDetailPanel = nil
            return
        }

        let panel: OverlayPanel
        if let existing = detailPanels[thread.id] {
            panel = existing
        } else if !detailPanels.values.contains(where: { $0 === primaryDetailPanel }) {
            panel = primaryDetailPanel
            panel.representedThread = thread
            detailPanels[thread.id] = panel
            detailOrder.append(thread.id)
            positionDetail(panel, cascadeIndex: detailOrder.count - 1)
        } else {
            panel = OverlayPanel(
                kind: .detail,
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 640)
            )
            panel.delegate = self
            configureResizing(panel)
            applyTransparency(to: panel)
            panel.representedThread = thread
            detailPanels[thread.id] = panel
            detailOrder.append(thread.id)
            positionDetail(panel, cascadeIndex: detailOrder.count - 1)
        }
        panel.representedThread = thread
        pendingDetailPanel = panel
    }

    func completeDetailOpen(present: Bool = true) {
        guard store.detailHost == .centered, let thread = store.detailThread else { return }
        if pendingDetailPanel == nil {
            prepareDetailOpen(thread: thread, host: .centered)
        }
        guard let panel = pendingDetailPanel ?? detailPanels[thread.id] else { return }
        pendingDetailPanel = nil
        panel.representedThread = thread
        if panel.chatPresentation == nil, let snapshot = store.detailSnapshot() {
            let presentation = ChatWindowPresentation(snapshot: snapshot)
            panel.chatPresentation = presentation
            panel.contentView = NSHostingView(rootView: PanelAppearanceRoot(preferences: appPreferences,
                content: ChatWindowRoot(store: store, presentation: presentation)))
        }
        if panel.chatPresentation?.isActive != true { panel.chatPresentation?.isActive = true }
        activeDetailPanel = panel
        if let index = detailOrder.firstIndex(of: thread.id) {
            detailOrder.remove(at: index)
            detailOrder.append(thread.id)
        }
        if present, !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        activePanel = .detail
    }

    private func replaceDetailIdentity(from source: CodexThread, to target: CodexThread) {
        guard let panel = detailPanels.removeValue(forKey: source.id) else { return }
        let oldSizeKey = sizeKey(for: .detail, threadID: source.id)
        if let saved = windowSizeDefaults.array(forKey: oldSizeKey) {
            windowSizeDefaults.set(saved, forKey: sizeKey(for: .detail, threadID: target.id))
        }
        detailPanels[target.id] = panel
        panel.representedThread = target
        // ChatWindowRoot passes this thread into the live detail view too.
        // Updating only the registry left the header, input routing and drop
        // target bound to the old (now redirected) conversation after a fork.
        if let snapshot = panel.chatPresentation?.snapshot {
            panel.chatPresentation?.snapshot = snapshot.replacingThread(target)
        }
        panel.title = target.title
        if let index = detailOrder.firstIndex(of: source.id) { detailOrder[index] = target.id }
    }

    private func closeActiveDetail() {
        guard let panel = activeDetailPanel, let thread = panel.representedThread else { return }
        panel.orderOut(nil)
        deferredFocus.cancel()
        panel.chatPresentation?.scroll.detach()
        panel.contentView = nil
        panel.chatPresentation = nil
        panel.representedThread = nil
        detailPanels.removeValue(forKey: thread.id)
        detailOrder.removeAll { $0 == thread.id }
        activeDetailPanel = nil
        pendingDetailPanel = nil
        store.clearCurrentDetail(threadID: thread.id)

        if let nextID = detailOrder.last,
           let nextThread = detailPanels[nextID]?.representedThread {
            store.focusDetailWindow(nextThread)
        } else {
            activePanel = nil
            focusVisibleControlPanel()
        }
    }

    private func focusVisibleControlPanel() {
        if journalWindow.window.isVisible {
            journalWindow.window.makeKeyAndOrderFront(nil)
            activePanel = nil
            return
        }
        if appSettings.window.isVisible {
            appSettings.window.makeKeyAndOrderFront(nil)
            activePanel = nil
            return
        }
        for (kind, panel) in [
            (OverlayKind.projects, projectPanel),
            (.recents, recentPanel),
            (.chatgpt, chatGPTPanel),
            (.settings, settingsPanel)
        ] where panel.isVisible && panel.alphaValue > 0 {
            panel.makeKeyAndOrderFront(nil)
            activePanel = kind
            return
        }
    }

    private func positionDetail(_ panel: NSPanel, cascadeIndex: Int) {
        let frame = targetScreen().visibleFrame
        let margin: CGFloat = 14
        let size = restoredSize(for: .detail,
                                threadID: (panel as? OverlayPanel)?.representedThread?.id,
                                fallback: NSSize(width: 650, height: 640), in: frame)
        let step = CGFloat(cascadeIndex % 7) * 24
        let desiredX = frame.midX - size.width / 2 + step
        let desiredY = frame.midY - size.height / 2 - step
        let x = min(max(desiredX, frame.minX + margin), frame.maxX - size.width - margin)
        let y = min(max(desiredY, frame.minY + margin), frame.maxY - size.height - margin)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func fittedSize(_ requested: NSSize, in visibleFrame: NSRect, margin: CGFloat) -> NSSize {
        NSSize(
            width: min(requested.width, max(1, visibleFrame.width - margin * 2)),
            height: min(requested.height, max(1, visibleFrame.height - margin * 2))
        )
    }

    private func setChatGPTExpanded(_ expanded: Bool, animated: Bool) {
        chatGPTPanel.minSize = minimumSize(for: .chatgpt, expanded: expanded)
        let screen = chatGPTPanel.screen ?? targetScreen()
        let target = chatGPTFrame(in: screen.visibleFrame, expanded: expanded)
        guard animated, chatGPTPanel.isVisible else {
            chatGPTPanel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            chatGPTPanel.animator().setFrame(target, display: true)
        }
    }

    private func chatGPTFrame(in visibleFrame: NSRect, expanded: Bool) -> NSRect {
        let margin: CGFloat = 14
        let size: NSSize
        if expanded {
            let availableWidth = max(1, visibleFrame.width - margin * 2)
            let availableHeight = max(1, visibleFrame.height - margin * 2)
            let desiredWidth = max(760, visibleFrame.width * 0.72)
            size = NSSize(
                width: min(1_020, min(desiredWidth, availableWidth)),
                height: availableHeight
            )
        } else {
            size = NSSize(
                width: min(336, max(1, visibleFrame.width - margin * 2)),
                height: min(282, max(1, visibleFrame.height - margin * 2))
            )
        }
        let restored = restoredSize(for: .chatgpt, expanded: expanded, fallback: size, in: visibleFrame)
        return NSRect(
            x: visibleFrame.maxX - margin - restored.width,
            y: visibleFrame.minY + margin,
            width: restored.width,
            height: restored.height
        )
    }

    private func configureResizing(_ panel: OverlayPanel) {
        panel.minSize = minimumSize(for: panel.overlayKind)
        panel.onUserResize = { [weak self] panel in
            guard let self else { return }
            let key = self.sizeKey(for: panel.overlayKind, threadID: panel.representedThread?.id,
                                   expanded: panel.overlayKind == .chatgpt && self.store.chatGPTExpanded)
            self.windowSizeDefaults.set([Double(panel.frame.width), Double(panel.frame.height)], forKey: key)
        }
    }

    private func sizeKey(for kind: OverlayKind, threadID: String? = nil, expanded: Bool = false) -> String {
        switch kind {
        case .projects: return "window-size.projects"
        case .recents: return "window-size.recents"
        case .settings: return "window-size.settings"
        case .chatgpt: return expanded ? "window-size.chat.expanded" : "window-size.chat.compact"
        case .detail: return "window-size.detail.\(threadID ?? "default")"
        }
    }

    private func minimumSize(for kind: OverlayKind, expanded: Bool = false) -> NSSize {
        switch kind {
        case .projects, .recents: return NSSize(width: 280, height: 220)
        case .settings: return NSSize(width: 300, height: 280)
        case .detail: return NSSize(width: 400, height: 320)
        case .chatgpt: return expanded ? NSSize(width: 480, height: 360) : NSSize(width: 280, height: 220)
        }
    }

    private func restoredSize(for kind: OverlayKind, threadID: String? = nil, expanded: Bool = false,
                              fallback: NSSize, in screen: NSRect) -> NSSize {
        let key = sizeKey(for: kind, threadID: threadID, expanded: expanded)
        guard let saved = windowSizeDefaults.array(forKey: key) as? [Double], saved.count == 2,
              saved.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return fittedSize(fallback, in: screen, margin: 14)
        }
        let minimum = minimumSize(for: kind, expanded: expanded)
        return fittedSize(NSSize(width: max(minimum.width, saved[0]), height: max(minimum.height, saved[1])),
                          in: screen, margin: 14)
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

}
