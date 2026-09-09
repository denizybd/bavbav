import AppKit
import Foundation

@main
enum BavbavMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = BavbavAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(ProcessInfo.processInfo.environment["BAVBAV_APP_ICON_CHECK"] == "1" ? .prohibited : .regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class BavbavAppDelegate: NSObject, NSApplicationDelegate {
    private var store: OverlayStore!
    private var panels: PanelCoordinator!
    private var hotKeys: HotKeyCenter?
    private var inputRouter: InputRouter!
    private var statusItem: NSStatusItem!
    private var appIconController: AppIconController?
    private var refreshTimer: Timer?
    private var conversationSyncTimer: Timer?
    private var terminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if environment["BAVBAV_LINK_CHECK"] == "1" {
            Task { Foundation.exit(await MessageLinkCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_APP_ICON_CHECK"] == "1" {
            Task { Foundation.exit(await AppIconCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_ATTACHMENT_INTAKE_CHECK"] == "1" {
            Task { Foundation.exit(await AttachmentIntakeCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_COMPOSER_CHECK"] == "1" {
            Task { Foundation.exit(await ComposerActionsCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_RENAME_CHECK"] == "1" {
            Task { Foundation.exit(await RenameCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_PERFORMANCE_CHECK"] == "1" {
            Task { Foundation.exit(await InteractionPerformanceCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_SHORTCUT_CHECK"] == "1" {
            Task { Foundation.exit(await ShortcutCustomizationCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_JOURNAL_LIVE_CHECK"] == "1" {
            Task { Foundation.exit(await JournalCheck.runLive() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_JOURNAL_CHECK"] == "1" {
            Task { Foundation.exit(await JournalCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_SCROLL_CHECK"] == "1" {
            Task { Foundation.exit(await ScrollBehaviorCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_STANDALONE_CHECK"] == "1" || environment["BAVBAV_CHATGPT_BOUNDARY_CHECK"] == "1" {
            setenv("BAVBAV_STANDALONE_CHECK", "1", 1)
            Task { Foundation.exit(await StandaloneChatCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_COMMANDS_CHECK"] == "1" {
            Task { Foundation.exit(await CommandVisibilityCheck.run() ? 0 : 1) }
            return
        }
        if environment["BAVBAV_PREFERENCES_CHECK"] == "1" {
            ApplicationMenu.install()
            Foundation.exit(AppPreferencesCheck.run() ? 0 : 1)
        }
        if environment["BAVBAV_RICH_MESSAGE_CHECK"] == "1" {
            Foundation.exit(RichMessageCheck.run() ? 0 : 1)
        }
        if environment["BAVBAV_RESIZE_CHECK"] == "1" {
            Foundation.exit(WindowResizeCheck.run() ? 0 : 1)
        }
        let multiWindowCheck = environment["BAVBAV_MULTIWINDOW_CHECK"] == "1"
        let messageCheck = environment["BAVBAV_MESSAGE_CHECK"] == "1"
        let steerCheck = environment["BAVBAV_STEER_CHECK"] == "1"
        let windowLevelCheck = environment["BAVBAV_WINDOW_LEVEL_CHECK"] == "1"
        let navigationCheck = environment["BAVBAV_NAV_CHECK"] == "1"
        let qCloseCheck = environment["BAVBAV_Q_CLOSE_CHECK"] == "1"
        let groupFrontCheck = environment["BAVBAV_GROUP_FRONT_CHECK"] == "1"
        let historyWriteCheck = environment["BAVBAV_HISTORY_WRITE_CHECK"] == "1"
        let backgroundCheck = environment["BAVBAV_BACKGROUND_CHECK"] == "1"
        let chatGPTBoundaryCheck = environment["BAVBAV_CHATGPT_BOUNDARY_CHECK"] == "1"
        let headlessCheck = environment["BAVBAV_HEADLESS_CHECK"] == "1"
            || multiWindowCheck
            || messageCheck
            || steerCheck
            || windowLevelCheck
            || navigationCheck
            || qCloseCheck
            || groupFrontCheck
            || historyWriteCheck
            || backgroundCheck
            || chatGPTBoundaryCheck
        let isCheckRun = environment.keys.contains { $0.hasPrefix("BAVBAV_") && $0.contains("CHECK") }
        store = OverlayStore(journal: isCheckRun ? nil : JournalService(directory: JournalService.defaultDirectory))
        panels = PanelCoordinator(store: store)
        inputRouter = InputRouter(store: store, coordinator: panels)
        panels.onPanelResigned = { [weak self] in
            self?.inputRouter.cancelPendingPress()
            if self?.panels.appSettings.window.isKeyWindow != true {
                self?.panels.appPreferences.keyBindings.cancelEditing()
            }
        }
        store.chatGPTSession.onClose = { [weak self] in self?.panels.dismiss(.chatgpt) }
        store.chatGPTSession.onWindowDirection = { [weak self] direction in
            self?.inputRouter.cancelPendingPress()
            _ = self?.panels.focusWindow(in: direction)
        }
        if environment["BAVBAV_APP_SWITCH_CHECK"] == "1" {
            ApplicationMenu.install()
            Foundation.exit(AppSwitchCheck.run(router: inputRouter, panels: panels) ? 0 : 1)
        }
        if environment["BAVBAV_ASTRA_CATALOG_CHECK"] == "1" {
            Task {
                await store.refreshSettingsData(refreshModelCatalog: true)
                guard let astra = store.codexModels.first(where: { $0.model == "gpt-6-astra" }),
                      store.settingsChoices.dropFirst().first?.value == astra.model,
                      !astra.supportedReasoningEfforts.isEmpty,
                      store.activeOverrides == .inherited
                else {
                    fputs("BAVBAV ASTRA CHECK FAILED: catalog or picker entry missing\n", stderr)
                    Foundation.exit(1)
                }
                print("BAVBAV ASTRA CHECK PASSED: \(astra.model); efforts: \(astra.supportedReasoningEfforts.map(\.id).joined(separator: ", ")); current model unchanged")
                await store.shutdown()
                Foundation.exit(0)
            }
            return
        }
        if environment["BAVBAV_CHATGPT_WEB_CHECK"] == "1" || environment["BAVBAV_CHATGPT_LIVE_CHECK"] == "1" {
            Task {
                let passed = await ChatGPTWebCheck.run(store: store, live: environment["BAVBAV_CHATGPT_LIVE_CHECK"] == "1")
                Foundation.exit(passed ? 0 : 1)
            }
            return
        }
        if environment["BAVBAV_TEXT_SHORTCUT_CHECK"] == "1" {
            Foundation.exit(TextShortcutCheck.run(router: inputRouter) ? 0 : 1)
        }
        if !isCheckRun {
            appIconController = AppIconController()
            appIconController?.start()
        }

        if windowLevelCheck {
            guard panels.allWindowsUseNormalLevel else {
                fputs("BAVBAV WINDOW LEVEL CHECK FAILED: a panel is still floating\n", stderr)
                Foundation.exit(1)
            }
            print("BAVBAV WINDOW LEVEL CHECK PASSED")
            Foundation.exit(0)
        }

        if !headlessCheck {
            do {
                hotKeys = try HotKeyCenter(bindings: panels.appPreferences.keyBindings) { [weak self] number in
                    guard let self else { return }
                    switch number {
                    // Command shortcuts are focus keys. Repeating one never
                    // closes a window; Q is the only close command.
                    case 1: self.panels.showGroup(.projects)
                    case 2: self.panels.showGroup(.recents)
                    case 3: self.panels.showGroup(.chatgpt)
                    case 4: self.panels.showGroup(.settings)
                    case 5: self.panels.showJournal()
                    default: break
                    }
                }
            } catch {
                showShortcutError(error.localizedDescription)
            }

            let bindings = panels.appPreferences.keyBindings
            bindings.validateExternal = { [weak self] values in try self?.hotKeys?.reconfigure(values) }
            bindings.onRecordingChanged = { [weak self] recording in
                do { try self?.hotKeys?.setSuspended(recording) }
                catch { self?.panels.appPreferences.keyBindings.error = error.localizedDescription }
            }
            bindings.onChanged = { [weak self] in
                guard let self else { return }
                self.inputRouter.cancelPendingPress()
                ApplicationMenu.update(NSApp.mainMenu, bindings: self.panels.appPreferences.keyBindings)
                ApplicationMenu.update(self.statusItem?.menu, bindings: self.panels.appPreferences.keyBindings)
            }
            ApplicationMenu.install(bindings: bindings)
            installStatusMenu()
            DispatchQueue.main.async { [weak self] in
                guard NSApp.isActive else { return }
                self?.panels.showInitialPanel()
            }
        }

        Task {
            await store.connectAndLoad()
            if headlessCheck {
                switch store.connection {
                case .failed(let message):
                    fputs("BAVBAV HEADLESS CHECK FAILED: \(message)\n", stderr)
                    Foundation.exit(1)
                default:
                    if backgroundCheck {
                        guard let thread = store.recentChats.first else { Foundation.exit(1) }
                        store.focusDetailWindow(thread)
                        store.beginWriting(from: .detail)
                        store.composerText = "STEER_BASE"
                        store.submitMessage()
                        for _ in 0..<100 where !store.canSteerCurrentTurn {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.canSteerCurrentTurn else { Foundation.exit(1) }
                        panels.dismiss(.detail)
                        guard store.runState(for: thread.id) == .working,
                              store.detailThread == nil,
                              store.detailMessages.isEmpty,
                              store.detailActivityItems.isEmpty,
                              panels.openDetailWindowCount == 0,
                              !self.applicationShouldTerminateAfterLastWindowClosed(NSApp)
                        else {
                            fputs("BACKGROUND CHECK FAILED: closing stopped work or retained content\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(thread)
                        for _ in 0..<100 where store.visibleDetailLoading {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.canSteerCurrentTurn,
                              !store.detailShowsActivity,
                              store.visibleDetailItems.contains(where: { $0.text == "STEER_BASE" })
                        else {
                            fputs("BACKGROUND CHECK FAILED: active work/history was not restored\n", stderr)
                            Foundation.exit(1)
                        }
                        store.beginWriting(from: .detail)
                        store.composerText = "STEER_FOLLOWUP"
                        store.submitMessage()
                        store.toggleQueueMode()
                        guard store.beginQueueSpace() else { Foundation.exit(1) }
                        store.finishQueueSpace(longPressTriggered: false)
                        panels.dismiss(.detail)
                        for _ in 0..<100 where store.messageSending {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard !store.messageSending, store.detailMessages.isEmpty,
                              store.detailActivityItems.isEmpty else { Foundation.exit(1) }
                        store.focusDetailWindow(thread)
                        for _ in 0..<100 where store.visibleDetailLoading {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.visibleDetailItems.contains(where: { $0.text == "BAVBAV_STEER_OK" }) else {
                            fputs("BACKGROUND CHECK FAILED: completed background reply was lost\n", stderr)
                            Foundation.exit(1)
                        }
                        print("BAVBAV BACKGROUND CHECK PASSED: close, continue, reopen, persisted reply")
                    } else if historyWriteCheck {
                        guard store.recentChats.count >= 2 else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: two chats are required\n", stderr)
                            Foundation.exit(1)
                        }
                        let activeThread = store.recentChats[0]
                        let historyThread = store.recentChats[1]

                        store.focusDetailWindow(activeThread)
                        store.beginWriting(from: .detail)
                        guard store.composerVisible else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: active composer did not open\n", stderr)
                            Foundation.exit(1)
                        }
                        store.composerText = "STEER_BASE"
                        store.submitMessage()
                        for _ in 0..<100 where !store.canSteerCurrentTurn {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.canSteerCurrentTurn else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: base turn did not start\n", stderr)
                            Foundation.exit(1)
                        }

                        store.focusDetailWindow(historyThread)
                        store.beginWriting(from: .detail)
                        guard store.detailThread?.id == historyThread.id,
                              store.composerVisible,
                              store.composerInputEnabled,
                              !store.shouldQueueCurrentMessage
                        else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: historical chat inherited another chat's queue state\n", stderr)
                            Foundation.exit(1)
                        }
                        store.composerText = "ECHO"
                        store.submitMessage()
                        guard store.queuedPromptCount(for: historyThread.id) == 0 else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: historical message was incorrectly queued\n", stderr)
                            Foundation.exit(1)
                        }

                        for _ in 0..<150 {
                            if store.detailMessages.contains(where: {
                                $0.role == .agent && $0.text == "BAVBAV_ECHO_OK"
                            }) { break }
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.detailMessages.contains(where: {
                            $0.role == .agent && $0.text == "BAVBAV_ECHO_OK"
                        }) else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: historical message did not start immediately\n", stderr)
                            Foundation.exit(1)
                        }

                        store.focusDetailWindow(activeThread)
                        guard store.canSteerCurrentTurn else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: parallel historical send lost the active turn\n", stderr)
                            Foundation.exit(1)
                        }
                        store.beginWriting(from: .detail)
                        store.composerText = "STEER_FOLLOWUP"
                        store.submitMessage()
                        store.toggleQueueMode()
                        guard store.beginQueueSpace() else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: completion steer did not arm\n", stderr)
                            Foundation.exit(1)
                        }
                        store.finishQueueSpace(longPressTriggered: false)
                        for _ in 0..<250 {
                            if store.queuedPromptCount(for: historyThread.id) == 0,
                               !store.messageSending {
                                break
                            }
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.queuedPromptCount(for: historyThread.id) == 0,
                        !store.messageSending
                        else {
                            fputs("BAVBAV HISTORY WRITE CHECK FAILED: parallel turns did not finish cleanly\n", stderr)
                            Foundation.exit(1)
                        }
                        print("BAVBAV HISTORY WRITE CHECK PASSED")
                    } else if groupFrontCheck {
                        guard let thread = store.recentChats.first else {
                            fputs("BAVBAV GROUP FRONT CHECK FAILED: a chat is required\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(thread)
                        panels.show(.recents)
                        panels.show(.chatgpt)
                        panels.hideAll()
                        panels.showGroup(.projects)
                        guard panels.isVisible(.projects),
                              panels.isVisible(.detail),
                              panels.isGroupOrderedAtFront(.projects)
                        else {
                            fputs(
                                "BAVBAV GROUP FRONT CHECK FAILED: Command+1 did not restore its chat group; \(panels.groupOrderDescription())\n",
                                stderr
                            )
                            Foundation.exit(1)
                        }

                        panels.show(.recents)
                        panels.show(.chatgpt)
                        panels.showGroup(.projects)
                        guard panels.isGroupOrderedAtFront(.projects) else {
                            fputs("BAVBAV GROUP FRONT CHECK FAILED: Command+1 group stayed behind another panel\n", stderr)
                            Foundation.exit(1)
                        }

                        panels.showGroup(.settings)
                        guard panels.isVisible(.settings),
                              panels.isVisible(.detail),
                              panels.isGroupOrderedAtFront(.settings)
                        else {
                            fputs("BAVBAV GROUP FRONT CHECK FAILED: Command+4 did not raise the active chat\n", stderr)
                            Foundation.exit(1)
                        }
                        print("BAVBAV GROUP FRONT CHECK PASSED")
                    } else if qCloseCheck {
                        guard let project = store.projects.first else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: a project is required\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.show(.projects)
                        store.selectLeft(id: project.id)
                        store.activateSelection(.projects)
                        guard case .chats = store.leftRoute else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: project chats did not open\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.dismiss(.projects)
                        guard panels.isVisible(.projects), case .projects = store.leftRoute,
                              store.leftInteraction.selectedID == project.id else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: first Q did not return to selected project\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.dismiss(.projects)
                        guard !panels.isVisible(.projects), case .projects = store.leftRoute else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: second Q did not close projects\n", stderr)
                            Foundation.exit(1)
                        }

                        let originalRecents = store.recentChats.map(\.id)
                        panels.show(.recents)
                        if originalRecents.count >= 2 {
                            guard store.beginSpace(.recents) else {
                                fputs("BAVBAV Q CLOSE CHECK FAILED: recent reorder did not arm\n", stderr)
                                Foundation.exit(1)
                            }
                            store.crossLongPressThreshold(.recents)
                            store.navigate(.recents, delta: 1)
                        }
                        panels.dismiss(.recents)
                        guard !panels.isVisible(.recents),
                              !store.recentIsReordering,
                              store.recentChats.map(\.id) == originalRecents
                        else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: closing reorder did not restore state\n", stderr)
                            Foundation.exit(1)
                        }

                        panels.show(.chatgpt)
                        store.selectChatGPT(id: OverlayStore.chatGPTLauncherID)
                        store.activateSelection(.chatgpt)
                        panels.dismiss(.chatgpt)
                        guard !panels.isVisible(.chatgpt), !store.chatGPTExpanded else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: expanded CHAT did not close\n", stderr)
                            Foundation.exit(1)
                        }

                        panels.show(.settings)
                        panels.dismiss(.settings)
                        guard !panels.isVisible(.settings), !store.settingsIsChoosing else {
                            fputs("BAVBAV Q CLOSE CHECK FAILED: settings did not close\n", stderr)
                            Foundation.exit(1)
                        }
                        print("BAVBAV Q CLOSE CHECK PASSED")
                    } else if navigationCheck {
                        panels.show(.projects)
                        panels.show(.recents)
                        panels.show(.settings)
                        panels.show(.chatgpt)
                        panels.show(.projects)
                        let rightTop = panels.focusWindow(in: .right)
                        let rightTopPanel = panels.activePanel
                        let leftTop = panels.focusWindow(in: .left)
                        let leftTopPanel = panels.activePanel
                        let leftBottom = panels.focusWindow(in: .down)
                        let leftBottomPanel = panels.activePanel
                        let rightBottom = panels.focusWindow(in: .right)
                        let rightBottomPanel = panels.activePanel
                        guard rightTop, rightTopPanel == .recents,
                              leftTop, leftTopPanel == .projects,
                              leftBottom, leftBottomPanel == .settings,
                              rightBottom, rightBottomPanel == .chatgpt
                        else {
                            fputs(
                                "BAVBAV NAV CHECK FAILED: \(String(describing: rightTopPanel)) -> \(String(describing: leftTopPanel)) -> \(String(describing: leftBottomPanel)) -> \(String(describing: rightBottomPanel))\n",
                                stderr
                            )
                            Foundation.exit(1)
                        }
                        print("BAVBAV NAV CHECK PASSED")
                    } else if steerCheck {
                        guard let thread = store.recentChats.first else {
                            fputs("BAVBAV STEER CHECK FAILED: a chat is required\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(thread)
                        store.beginWriting(from: .detail)
                        store.composerText = "STEER_BASE"
                        store.submitMessage()
                        for _ in 0..<100 where !store.canSteerCurrentTurn {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard store.detailRunState == .working, store.canSteerCurrentTurn else {
                            fputs("BAVBAV STEER CHECK FAILED: active turn was not steerable\n", stderr)
                            Foundation.exit(1)
                        }
                        store.beginWriting(from: .detail)
                        guard store.composerVisible,
                              store.composerInputEnabled,
                              store.shouldQueueCurrentMessage
                        else {
                            fputs("BAVBAV STEER CHECK FAILED: composer did not open during active turn\n", stderr)
                            Foundation.exit(1)
                        }
                        store.composerText = "ECHO"
                        store.submitMessage()
                        store.beginWriting(from: .detail)
                        store.composerText = "STEER_FOLLOWUP"
                        store.submitMessage()
                        guard store.currentQueueCount == 2 else {
                            fputs("BAVBAV STEER CHECK FAILED: prompts did not enter queue\n", stderr)
                            Foundation.exit(1)
                        }

                        store.toggleQueueMode()
                        store.navigateQueue(delta: 1)
                        store.editSelectedQueuedPrompt()
                        guard store.composerVisible,
                              store.composerText == "STEER_FOLLOWUP",
                              store.currentQueueCount == 1
                        else {
                            fputs("BAVBAV STEER CHECK FAILED: Q edit flow did not restore prompt\n", stderr)
                            Foundation.exit(1)
                        }
                        store.submitMessage()
                        store.toggleQueueMode()
                        store.navigateQueue(delta: 1)
                        guard store.beginQueueSpace() else {
                            fputs("BAVBAV STEER CHECK FAILED: queue reorder did not start\n", stderr)
                            Foundation.exit(1)
                        }
                        store.crossQueueLongPressThreshold()
                        store.navigateQueue(delta: -1)
                        store.finishQueueSpace(longPressTriggered: true)
                        guard store.currentQueuedPrompts.first?.text == "STEER_FOLLOWUP" else {
                            fputs("BAVBAV STEER CHECK FAILED: held-space reorder failed\n", stderr)
                            Foundation.exit(1)
                        }
                        guard store.beginQueueSpace() else {
                            fputs("BAVBAV STEER CHECK FAILED: immediate steer did not arm\n", stderr)
                            Foundation.exit(1)
                        }
                        store.finishQueueSpace(longPressTriggered: false)
                        for _ in 0..<200 {
                            let steerDone = store.detailMessages.contains {
                                $0.role == .agent && $0.text == "BAVBAV_STEER_OK"
                            }
                            let queueDone = store.detailMessages.contains {
                                $0.role == .agent && $0.text == "BAVBAV_ECHO_OK"
                            }
                            if steerDone, queueDone, store.currentQueueCount == 0, !store.messageSending { break }
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        let baseEchoes = store.detailMessages.filter {
                            $0.role == .user && $0.text == "STEER_BASE"
                        }
                        let steerEchoes = store.detailMessages.filter {
                            $0.role == .user && $0.text == "STEER_FOLLOWUP"
                        }
                        let agentEchoes = store.detailMessages.filter {
                            $0.role == .agent && $0.text == "BAVBAV_STEER_OK"
                        }
                        let queuedEchoes = store.detailMessages.filter {
                            $0.role == .user && $0.text == "ECHO"
                        }
                        let queuedAgentEchoes = store.detailMessages.filter {
                            $0.role == .agent && $0.text == "BAVBAV_ECHO_OK"
                        }
                        guard baseEchoes.count == 1,
                              steerEchoes.count == 1,
                              agentEchoes.count == 1,
                              queuedEchoes.count == 1,
                              queuedAgentEchoes.count == 1,
                              store.currentQueueCount == 0,
                              store.detailRunState == .idle
                        else {
                            fputs(
                                "BAVBAV STEER CHECK FAILED: base=\(baseEchoes.count) steer=\(steerEchoes.count) agent=\(agentEchoes.count) queued=\(queuedEchoes.count)\n",
                                stderr
                            )
                            Foundation.exit(1)
                        }
                        print("BAVBAV STEER CHECK PASSED")
                    } else if messageCheck {
                        guard let thread = store.recentChats.first else {
                            fputs("BAVBAV MESSAGE CHECK FAILED: a chat is required\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(thread)
                        store.beginWriting(from: .detail)
                        store.composerText = "ECHO"
                        store.submitMessage()
                        for _ in 0..<100 where store.messageSending {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        let userEchoes = store.detailMessages.filter {
                            $0.role == .user && $0.text == "ECHO"
                        }
                        let agentEchoes = store.detailMessages.filter {
                            $0.role == .agent && $0.text == "BAVBAV_ECHO_OK"
                        }
                        guard userEchoes.count == 1, agentEchoes.count == 1,
                              userEchoes.first?.timestamp == Date(timeIntervalSince1970: 1_788_000_000),
                              agentEchoes.first?.timestamp == Date(timeIntervalSince1970: 1_788_000_001)
                        else {
                            fputs(
                                "BAVBAV MESSAGE CHECK FAILED: user=\(userEchoes.count) agent=\(agentEchoes.count)\n",
                                stderr
                            )
                            Foundation.exit(1)
                        }
                        print("BAVBAV MESSAGE CHECK PASSED")
                    } else if multiWindowCheck {
                        guard store.recentChats.count >= 2 else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: two chats are required\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.show(.projects)
                        panels.show(.projects)
                        guard panels.isVisible(.projects) else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: repeated focus hid projects\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(store.recentChats[0])
                        store.focusDetailWindow(store.recentChats[1])
                        guard panels.openDetailWindowCount == 2 else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: second chat replaced first\n", stderr)
                            Foundation.exit(1)
                        }
                        store.focusDetailWindow(store.recentChats[0])
                        guard panels.openDetailWindowCount == 2 else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: reopening duplicated a chat\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.dismiss(.detail)
                        guard panels.openDetailWindowCount == 1 else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: Q did not close only active chat\n", stderr)
                            Foundation.exit(1)
                        }
                        panels.dismiss(.detail)
                        guard panels.openDetailWindowCount == 0 else {
                            fputs("BAVBAV MULTIWINDOW CHECK FAILED: final Q did not close chat\n", stderr)
                            Foundation.exit(1)
                        }
                        print("BAVBAV MULTIWINDOW CHECK PASSED")
                    } else {
                        print("BAVBAV HEADLESS CHECK PASSED")
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        guard !headlessCheck else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.panels.hasVisibleWindows else { return }
                await self.store.refresh()
            }
        }
        refreshTimer?.tolerance = 3
        conversationSyncTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panels.isVisible(.detail) else { return }
                self.store.syncVisibleConversation()
            }
        }
        conversationSyncTimer?.tolerance = 1
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard store != nil else { return }
        // The system restores hidden windows. Only create an entry point when
        // every panel was explicitly closed with Q; never reorder existing chats.
        if !NSApp.isHidden, !panels.hasVisibleWindows { panels.showInitialPanel() }
        Task { @MainActor in
            await store.refresh()
            store.syncVisibleConversation()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        inputRouter?.cancelPendingPress()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard panels != nil else { return true }
        sender.unhide(nil)
        if !panels.hasVisibleWindows { panels.showInitialPanel() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appIconController?.stop()
        refreshTimer?.invalidate()
        conversationSyncTimer?.invalidate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        refreshTimer?.invalidate()
        conversationSyncTimer?.invalidate()
        Task {
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func showProjects() {
        panels.showGroup(.projects)
    }

    @objc private func showRecents() {
        panels.showGroup(.recents)
    }

    @objc private func showChatGPT() {
        panels.showGroup(.chatgpt)
    }

    @objc private func showSettings() {
        panels.showGroup(.settings)
    }

    @objc func showAppSettings(_ sender: Any?) {
        panels.showAppSettings()
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func installStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Bavbav")
            image?.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Projects", action: #selector(showProjects), keyEquivalent: "").representedObject = "*.projects.key"
        menu.addItem(withTitle: "Recent 8", action: #selector(showRecents), keyEquivalent: "").representedObject = "*.recents.key"
        menu.addItem(withTitle: "ChatGPT", action: #selector(showChatGPT), keyEquivalent: "").representedObject = "*.standalone.key"
        menu.addItem(withTitle: "Write Control", action: #selector(showSettings), keyEquivalent: "").representedObject = "*.models.key"
        menu.addItem(withTitle: "Takvim", action: #selector(showJournal), keyEquivalent: "").representedObject = "*.journal.key"
        menu.addItem(withTitle: "Ayarlar", action: #selector(showAppSettings(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Refresh Codex", action: #selector(refreshNow), keyEquivalent: "").representedObject = "*.refresh.key"
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Bavbav", action: #selector(quit), keyEquivalent: "").representedObject = "*.quit.key"
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        ApplicationMenu.update(menu, bindings: panels.appPreferences.keyBindings)
    }

    private func showShortcutError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Kısayol çakışması"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showJournal() { panels.showJournal() }
}
