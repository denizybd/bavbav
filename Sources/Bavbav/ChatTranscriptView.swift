import AppKit
import BavbavCore
import SwiftUI

extension Notification.Name {
    static let chatJumpToBottom = Notification.Name("Bavbav.ChatJumpToBottom")
}

/// One controller per transcript/window. Follow layout changes, not message
/// count: history, math, wrapping and streamed text can all grow the document.
@MainActor
final class ChatScrollController: NSObject, ObservableObject {
    @Published private(set) var awayFromBottom = false
    private(set) var followingBottom = true
    private weak var scrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private var correctionScheduled = false
    private var attachmentGeneration = 0
    private var adjusting = false
    private var eventMonitor: Any?
    private var scrollEndWork: DispatchWorkItem?
    private var liveScrolling = false
    private var touchScrolling = false
    private var momentumScrolling = false
    private var interactionGeneration = 0
    private var readingOffset: CGFloat?
    private var restoringReadingPosition = false
    private weak var attachmentOwner: AnyObject?
    private var gestureActive: Bool { liveScrolling || touchScrolling || momentumScrolling }

    func attach(_ scroll: NSScrollView, owner: AnyObject? = nil) {
        guard let document = scroll.documentView else { return }
        if scrollView === scroll && observedDocument === document {
            attachmentOwner = owner
            return
        }
        detach()
        attachmentOwner = owner
        scrollView = scroll
        observedDocument = document
        restoringReadingPosition = !followingBottom && readingOffset != nil
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        document.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: document)
        center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(liveScrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(userDidScroll), name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(jumpNotification(_:)), name: .chatJumpToBottom, object: nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let scroll = self.scrollView, event.window === scroll.window else { return event }
            if event.type == .scrollWheel {
                let point = scroll.convert(event.locationInWindow, from: nil)
                // AppKit delivers an entire gesture to its original view even
                // if the pointer leaves that view during touch or momentum.
                guard scroll.bounds.contains(point) || self.gestureActive else { return event }
                self.observeWheel(phase: event.phase, momentum: event.momentumPhase)
                return event
            } else {
                guard [115, 116, 121, 125, 126].contains(event.keyCode),
                      let responder = event.window?.firstResponder as? NSView,
                      responder.isDescendant(of: scroll),
                      (responder as? NSTextView)?.isEditable != true else { return event }
            }
            self.userWillScroll()
            self.observeAfterEvent()
            return event
        }
        contentChanged()
    }

    func detach() {
        if !followingBottom, !restoringReadingPosition, let scrollView {
            readingOffset = scrollView.contentView.bounds.minY
        }
        attachmentGeneration &+= 1
        interactionGeneration &+= 1
        liveScrolling = false
        touchScrolling = false
        momentumScrolling = false
        correctionScheduled = false
        scrollEndWork?.cancel()
        scrollEndWork = nil
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        scrollView = nil
        observedDocument = nil
        attachmentOwner = nil
    }

    func detach(owner: AnyObject) {
        guard attachmentOwner === owner else { return }
        detach()
    }

    deinit {
        scrollEndWork?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    var bottomOffset: CGFloat {
        guard let scrollView else { return 0 }
        let clip = scrollView.contentView
        return scrollView.documentView?.isFlipped == true
            ? max(clip.documentRect.minY, clip.documentRect.maxY - clip.bounds.height)
            : clip.documentRect.minY
    }

    var isAtBottom: Bool {
        guard let scrollView else { return true }
        return abs(scrollView.contentView.bounds.minY - bottomOffset) <= 1
    }

    func jumpToBottom() {
        interactionGeneration &+= 1
        liveScrolling = false
        touchScrolling = false
        momentumScrolling = false
        scrollEndWork?.cancel()
        scrollEndWork = nil
        followingBottom = true
        restoringReadingPosition = false
        readingOffset = nil
        setAwayFromBottom(false)
        contentChanged()
    }

    func contentChanged() {
        guard scrollView != nil, !correctionScheduled else { return }
        correctionScheduled = true
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attachmentGeneration == generation else { return }
            self.correctionScheduled = false
            self.correctAfterLayout()
        }
    }

    func correctAfterLayout() {
        guard let scrollView else { return }
        if followingBottom || (restoringReadingPosition && !gestureActive) {
            adjusting = true
            scrollView.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            let clipMaximum = max(clip.documentRect.minY, clip.documentRect.maxY - clip.bounds.height)
            let desired = followingBottom ? bottomOffset : (readingOffset ?? clip.bounds.minY)
            let target = min(clipMaximum, max(clip.documentRect.minY, desired))
            if abs(clip.bounds.minY - target) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scrollView.reflectScrolledClipView(clip)
            }
            adjusting = false
            // A replacement SwiftUI document may initially be empty. Keep the
            // saved position until layout has enough content to restore it.
            if !followingBottom && abs(target - desired) <= 0.5 {
                restoringReadingPosition = false
            }
        }
        setAwayFromBottom(!followingBottom && !isAtBottom)
    }

    private func setAwayFromBottom(_ value: Bool) {
        // Publishing identical values invalidated the entire transcript on
        // every bounds notification, including our own bottom corrections.
        if awayFromBottom != value { awayFromBottom = value }
    }

    @objc private func layoutChanged() { if !adjusting { contentChanged() } }
    @objc private func boundsChanged() {
        guard !adjusting else { return }
        if followingBottom { contentChanged() }
        else { setAwayFromBottom(!isAtBottom) }
    }
    @objc func userWillScroll() {
        interactionGeneration &+= 1
        scrollEndWork?.cancel()
        scrollEndWork = nil
        followingBottom = false
        restoringReadingPosition = false
    }
    @objc func userDidScroll() {
        if let scrollView, !restoringReadingPosition {
            readingOffset = scrollView.contentView.bounds.minY
        }
        if gestureActive { followingBottom = false }
        setAwayFromBottom(!followingBottom && !isAtBottom)
        scrollEndWork?.cancel()
        scrollEndWork = nil
        // No idle timer can prove that fingers have left the trackpad or that
        // AppKit's live-scroll/momentum animation has ended.
        guard !gestureActive else { return }
        let generation = interactionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.interactionGeneration == generation, !self.gestureActive else { return }
            self.scrollEndWork = nil
            // A gesture owns the viewport through its momentum phase. Do not
            // snap a small upward movement back just because it is within 24pt.
            self.followingBottom = self.isAtBottom
            self.setAwayFromBottom(!self.followingBottom)
        }
        scrollEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @objc private func liveScrollBegan() {
        liveScrolling = true
        userWillScroll()
    }

    @objc private func liveScrollEnded() {
        liveScrolling = false
        userDidScroll()
    }

    func observeWheel(phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        if !phase.intersection([.mayBegin, .began, .changed, .stationary]).isEmpty { touchScrolling = true }
        if !phase.intersection([.ended, .cancelled]).isEmpty { touchScrolling = false }
        if !momentum.intersection([.began, .changed, .stationary]).isEmpty { momentumScrolling = true }
        if !momentum.intersection([.ended, .cancelled]).isEmpty { momentumScrolling = false }
        userWillScroll()
        observeAfterEvent()
    }

    private func observeAfterEvent() {
        let generation = interactionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.interactionGeneration == generation else { return }
            self.userDidScroll()
        }
    }
    @objc private func jumpNotification(_ notification: Notification) {
        guard let target = notification.object as? NSWindow, target === scrollView?.window else { return }
        jumpToBottom()
    }
}

private struct TranscriptScrollProbe: NSViewRepresentable {
    let controller: ChatScrollController
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.connectAfterLayout() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.isDismantled = true
        view.controller?.detach(owner: view)
    }

    final class Probe: NSView {
        weak var controller: ChatScrollController?
        private var connectionScheduled = false
        var isDismantled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connectAfterLayout() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectAfterLayout() }
        override func layout() { super.layout(); connectAfterLayout() }
        func connectAfterLayout() {
            guard !isDismantled, !connectionScheduled else { return }
            connectionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionScheduled = false
                guard !self.isDismantled, let scroll = self.enclosingScrollView else { return }
                self.controller?.attach(scroll, owner: self)
            }
        }
    }
}

struct ChatTranscriptView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    let items: [CodexMessage]
    @StateObject private var scroll: ChatScrollController

    init(items: [CodexMessage], scroll: ChatScrollController? = nil) {
        self.items = items
        _scroll = StateObject(wrappedValue: scroll ?? ChatScrollController())
    }

    private struct Revision: Equatable {
        let count: Int
        let last: CodexMessage?
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(items) { message in MessageBlock(message: message).id(message.id) }
            }
            .padding(16)
            .background(TranscriptScrollProbe(controller: scroll))
        }
        .onAppear { scroll.contentChanged() }
        .onChange(of: Revision(count: items.count, last: items.last)) { _ in scroll.contentChanged() }
        .overlay(alignment: .bottomTrailing) {
            if scroll.awayFromBottom {
                Button { scroll.jumpToBottom() } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BavbavTheme.accent).readableForeground()
                        .frame(width: 30, height: 28)
                        .background(BavbavTheme.surface.panelBackdrop())
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(BavbavTheme.accent.opacity(0.7), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("Jump to latest · \(shortcuts.key("chat.read.bottom.key")) · \(shortcuts.key("chat.read.bottom.end"))")
                .accessibilityLabel("Jump to the latest message")
                .padding(12)
            }
        }
    }
}
