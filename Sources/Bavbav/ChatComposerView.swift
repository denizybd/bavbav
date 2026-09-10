import AppKit
import BavbavCore
import SwiftUI

/// The + drawer is part of the conversation, never a separate utility window.
struct ChatComposerView: View {
    @ObservedObject var store: OverlayStore
    var menuHeight: CGFloat = 300
    @Environment(\.shortcutLabels) private var shortcuts
    private var scope: String { "chat.write." + (store.composerHasPayload ? "full" : "empty") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.composerAttachments.isEmpty {
                AttachmentStrip(attachments: store.composerAttachments, onRemove: { store.removeComposerAttachment(id: $0) })
            }
            if store.composerImporting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini).tint(BavbavTheme.accent)
                    Text("Preparing files…").font(BavbavTheme.mono(9))
                }.foregroundStyle(BavbavTheme.accent).readableForeground()
            }
            if let error = store.composerAttachmentError {
                Text(error).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning).readableForeground().lineLimit(3)
            }
            HStack(spacing: 8) {
                Text(store.shouldQueueCurrentMessage ? "QUEUE" : "WRITE")
                    .foregroundStyle(BavbavTheme.accent)
                if store.composerMode == .plan { badge("PLAN", color: BavbavTheme.cyan) }
                if store.composerGoal?.status == "active" { badge("GOAL", color: BavbavTheme.warning) }
                Spacer(minLength: 0)
                Text("\(shortcuts.key(scope + ".send.key")) \(store.composerHasPayload ? (store.shouldQueueCurrentMessage ? "ADD" : "SEND") : "CLOSE") · \(shortcuts.key(scope + ".newline.key")) LINE")
                    .foregroundStyle(BavbavTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }.font(BavbavTheme.mono(7, weight: .bold)).readableForeground()

            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if store.composerText.isEmpty {
                        Text(store.composerAttachments.isEmpty ? "Write a message or drop files…" : "Add a message about your attachments…")
                            .font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.muted)
                            .readableForeground().padding(.horizontal, 10).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: $store.composerText, focusToken: store.composerFocusToken,
                                     enabled: store.composerInputEnabled,
                                     onActivate: { store.closeComposerTools(restoreFocus: false) })
                }.frame(height: 72)
                Button { store.toggleComposerTools() } label: {
                    Image(systemName: store.composerToolsVisible ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(store.composerToolsVisible ? BavbavTheme.accent : BavbavTheme.text)
                        .readableForeground().frame(width: 34, height: 34)
                        .background((store.composerToolsVisible ? BavbavTheme.accent.opacity(0.10) : BavbavTheme.surface).panelBackdrop())
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).padding(6)
                .accessibilityLabel("Attachments and Codex tools")
                .help("Images, documents, Plan, and Goal · \(shortcuts.key(scope + ".composerTools.key"))")
            }
            .background(BavbavTheme.raised.panelBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(BavbavTheme.accent.opacity(0.35), lineWidth: 0.8))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(BavbavTheme.surface.opacity(0.8).panelBackdrop())
        .overlay(alignment: .bottom) {
            if store.composerToolsVisible {
                toolsDrawer.padding(.horizontal, 14).padding(.bottom, 110)
            }
        }
    }

    private var toolsDrawer: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ATTACHMENTS & TOOLS").foregroundStyle(BavbavTheme.accent)
                    Spacer()
                    Text("THIS CHAT").foregroundStyle(BavbavTheme.muted)
                }.font(BavbavTheme.mono(8, weight: .bold)).readableForeground()
                toolRow(index: 0, symbol: "paperclip", title: "Image or document",
                        subtitle: "Drop a screenshot directly into the chat.") { store.chooseComposerFiles() }
                HStack(spacing: 6) {
                    modeButton(index: 1, mode: .default, symbol: "bolt", title: "Normal", subtitle: "Build together")
                    modeButton(index: 2, mode: .plan, symbol: "list.bullet.rectangle", title: "Plan", subtitle: "Plan first")
                }
                toolRow(index: 3, symbol: "scope", title: "Goal",
                        subtitle: store.composerGoal.map { "\($0.status.uppercased()) · \($0.objective)" } ?? "Give Codex a clear objective to work toward.") {
                    store.beginComposerGoalEditing()
                }
                if store.composerGoalEditing {
                    VStack(alignment: .leading, spacing: 7) {
                        RenameNameField(text: Binding(get: { store.goalObjective }, set: { store.updateGoalObjective($0) }),
                                        enabled: !store.composerGoalBusy, accessibilityLabel: "Conversation goal",
                                        placeholder: "What should Codex accomplish?")
                            .frame(height: 26).padding(.horizontal, 8)
                            .background(BavbavTheme.background.panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 5))
                        HStack {
                            Text("Saved to this chat. Send a message to start working toward the goal.")
                                .font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).readableForeground()
                            Spacer()
                            Button("Save") { store.saveComposerGoal() }
                                .buttonStyle(.plain).font(BavbavTheme.mono(9, weight: .semibold))
                                .foregroundStyle(BavbavTheme.accent).readableForeground().disabled(store.composerGoalBusy)
                        }
                    }
                    .id("goal.editor")
                    .onAppear {
                        // The field is inserted in this update; scrolling in
                        // onChange alone can run before its anchor exists.
                        DispatchQueue.main.async { proxy.scrollTo("goal.editor", anchor: .center) }
                    }
                }
                if let goal = store.composerGoal {
                    HStack(spacing: 6) {
                        Text(goal.remainingTokens.map { "\($0) tokens remaining" } ?? "\(goal.tokensUsed) tokens used")
                            .font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).readableForeground()
                        Spacer()
                        Button("Clear goal") { store.clearComposerGoal() }
                            .buttonStyle(.plain).font(BavbavTheme.mono(8))
                            .foregroundStyle(BavbavTheme.warning).readableForeground().disabled(store.composerGoalBusy)
                    }
                }
                if store.composerGoalBusy { ProgressView().controlSize(.mini).tint(BavbavTheme.warning) }
                if let error = store.composerGoalError {
                    Text(error).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.warning).readableForeground().fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(BavbavTheme.border)
                Text(store.composerGoalEditing
                     ? "\(shortcuts.key("composer.goal.write.composerGoalSave.key")) SAVE · \(shortcuts.key("composer.goal.write.composerGoalCancel.key")) BACK"
                     : "\(shortcuts.key("composer.tools.up.key")) ↑ · \(shortcuts.key("composer.tools.down.key")) ↓ · \(shortcuts.key("composer.tools.composerToolOpen.space")) SELECT · \(shortcuts.key("composer.tools.composerToolsClose.key")) CLOSE")
                    .font(BavbavTheme.mono(7, weight: .semibold)).foregroundStyle(BavbavTheme.muted).readableForeground()
                Text("Up to 12 files · 25 MiB each · Shared only when sent")
                    .font(BavbavTheme.mono(7)).foregroundStyle(BavbavTheme.muted).readableForeground()
            }.padding(12)
        }
        .frame(height: min(menuHeight, store.composerGoalEditing || store.composerGoal != nil ? 300 : 238))
        .background(BavbavTheme.background.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BavbavTheme.accent.opacity(0.4), lineWidth: 0.8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.tools.drawer")
        .onChange(of: store.composerToolIndex) { index in
            proxy.scrollTo("tool.\(index)", anchor: .center)
        }
        .onChange(of: store.composerGoalEditing) { editing in
            proxy.scrollTo(editing ? "goal.editor" : "tool.\(store.composerToolIndex)", anchor: .center)
        }
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title).foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.10).panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private func toolRow(index: Int, symbol: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 22)
                    .foregroundStyle(BavbavTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(BavbavTheme.mono(10, weight: .semibold)).foregroundStyle(BavbavTheme.text)
                    Text(subtitle).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(BavbavTheme.muted)
            }.readableForeground().padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(BavbavTheme.raised.panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(store.composerToolIndex == index ? BavbavTheme.accent.opacity(0.65) : .clear, lineWidth: 0.8))
        }.buttonStyle(.plain).id("tool.\(index)")
    }
    private func modeButton(index: Int, mode: CodexCollaborationMode, symbol: String, title: String, subtitle: String) -> some View {
        Button { store.setComposerMode(mode); store.closeComposerTools() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                    Text(title)
                    Spacer(minLength: 0)
                    if store.composerMode == mode { Image(systemName: "checkmark.circle.fill").foregroundStyle(BavbavTheme.accent) }
                }.font(BavbavTheme.mono(10, weight: .semibold)).foregroundStyle(BavbavTheme.text)
                Text(subtitle).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted)
            }.readableForeground().padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(BavbavTheme.raised.panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(store.composerToolIndex == index ? BavbavTheme.accent.opacity(0.65) : .clear, lineWidth: 0.8))
        }.buttonStyle(.plain).id("tool.\(index)")
    }
}
