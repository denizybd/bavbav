import AppKit
import BavbavOffline
import SwiftUI

@MainActor
final class OfflineAIWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let service: OfflineAIService
    private var monitor: Any?
    init(service: OfflineAIService, preferences: AppPreferences) {
        self.service = service
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 690),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Bavbav · Yerel AI eklentisi \(OfflinePlugin.version)"
        window.identifier = NSUserInterfaceItemIdentifier("bavbav.offline-ai")
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .normal; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 510)
        window.delegate = self
        window.center()
        PanelWindowAppearance.apply(to: window, opacity: preferences.backgroundOpacity)
        let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        container.setContent(NSHostingView(rootView: PanelAppearanceRoot(preferences: preferences, content: OfflineAIView(service: service))))
        window.contentView = container
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let editable = (self.window.firstResponder as? NSTextView)?.isEditable == true
                    || self.window.firstResponder is NSTextField
                if !editable, event.keyCode == 12, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.window.close(); return nil
                }
                return event
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        // Closing is presentation only. The durable background job continues.
    }
    func shutdown() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

struct OfflineAIView: View {
    @ObservedObject var service: OfflineAIService
    private var selected: OfflineTaskRecord? { service.selected }
    private var activeWork: Bool { service.busy || service.jobs.contains { $0.phase == .running } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL AI / OFFLINE HANDOFF").font(BavbavTheme.mono(12, weight: .semibold))
                        .foregroundStyle(BavbavTheme.accent).readableForeground()
                    Text("Qwen3 14B · eklenti \(service.version) · tek yerel ajan")
                        .font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted).readableForeground()
                }
                Spacer()
                if activeWork { ProgressView().controlSize(.small).accessibilityIdentifier("offline.activity") }
            }
            HStack(spacing: 16) {
                Toggle("Yerel eklenti", isOn: $service.enabled)
                Toggle("İnternet yokken uygun yeni mesajları devret", isOn: $service.automatic)
                    .disabled(!service.enabled)
            }.toggleStyle(.checkbox).font(BavbavTheme.mono(9))
            Text(service.status).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.text).readableForeground()
                .accessibilityIdentifier("offline.status")
            Text(service.connectivity).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).readableForeground()
            if let error = service.error {
                Text(error).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning).readableForeground().textSelection(.enabled)
            }
            HStack {
                Text(service.repositoryPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Repo seç") { service.chooseRepository() }.disabled(activeWork)
                Button("Kur / doğrula / başlat") { service.prepareRuntime() }.disabled(activeWork)
            }.font(BavbavTheme.mono(8))
            Divider().overlay(BavbavTheme.border)
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(service.jobs) { job in
                            Button { service.selectedID = job.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.request.objective).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(Self.phase(job.phase)).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.accent)
                                }
                                .padding(9).background((service.selectedID == job.id ? BavbavTheme.raised : BavbavTheme.surface).panelBackdrop())
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).font(BavbavTheme.mono(9))
                        }
                        if service.jobs.isEmpty { Text("Henüz yerel görev yok").font(BavbavTheme.mono(9)).padding(12) }
                    }
                }.frame(width: 210)
                VStack(alignment: .leading, spacing: 9) {
                    if let selected {
                        HStack {
                            Text(Self.phase(selected.phase)).foregroundStyle(BavbavTheme.accent)
                            Spacer()
                            Text("\(selected.receipts.count) kayıt")
                        }.font(BavbavTheme.mono(9))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(selected.result?.output ?? selected.errorMessage ?? "İşlem kayıtları aşağıda görünecek.")
                                    .font(BavbavTheme.mono(10)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(selected.receipts) { receipt in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(receipt.summary).foregroundStyle(BavbavTheme.accent)
                                        if !receipt.details.isEmpty { Text(receipt.details).textSelection(.enabled) }
                                    }.font(BavbavTheme.mono(8)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(BavbavTheme.surface.panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                        HStack {
                            Button("Devam et") { service.resumeSelected() }
                                .disabled(![OfflineTaskPhase.paused, .failed, .waitingForNetwork].contains(selected.phase))
                            Button(selected.phase == .awaitingCloudResolution ? "Yerel kaydı iptal et" : "Durdur") { service.cancelSelected() }
                                .disabled([OfflineTaskPhase.completed, .cancelled, .handedBack].contains(selected.phase))
                                .help(selected.phase == .awaitingCloudResolution ? "Sadece yerel izleme kaydını kapatır; buluttaki işlemi durdurmaz." : "Yerel görevi iptal eder.")
                            Spacer()
                            Button("Kaynak sohbete aktar") { service.handoffSelected() }
                                .disabled(selected.phase != .completed || selected.request.sourceThreadID == "standalone-local"
                                          || selected.request.sourceThreadID.hasPrefix("account-local-"))
                                .help(selected.request.sourceThreadID.hasPrefix("account-local-") ? "Bu sonucu Kimin hesabı penceresinden seçtiğin hesaba aktar." : "Raporu kaynak sohbetin boş taslağına ekler; göndermez.")
                        }.font(BavbavTheme.mono(8))
                    } else {
                        Text("Bir görev seç. Sonuçlar buluta kendiliğinden gönderilmez.")
                            .font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
            Divider().overlay(BavbavTheme.border)
            HStack {
                Text("KAYNAK / \(service.sourceTitle)").lineLimit(1)
                Spacer()
                Button("Çalışma klasörü") { service.chooseWorkspace() }
            }.font(BavbavTheme.mono(8))
            Text(service.workspacePath).font(BavbavTheme.mono(7)).foregroundStyle(BavbavTheme.muted).lineLimit(1).truncationMode(.middle)
            TextEditor(text: $service.objective).font(BavbavTheme.mono(11)).frame(height: 66)
                .scrollContentBackground(.hidden).padding(5).background(BavbavTheme.raised.panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityIdentifier("offline.objective")
            HStack {
                Text("Salt okunur dosya araçları + değişiklik taslakları. Orijinal dosyalara yazmaz.")
                    .font(BavbavTheme.mono(7)).foregroundStyle(BavbavTheme.muted)
                Spacer()
                Button("Yerelde çalıştır") { service.submitDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!service.enabled || service.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(BavbavTheme.mono(9, weight: .semibold)).accessibilityIdentifier("offline.submit")
            }
        }.padding(16).foregroundStyle(BavbavTheme.text).readableForeground()
            .background(BavbavTheme.background.panelBackdrop()).preferredColorScheme(.dark)
    }
    static func phase(_ value: OfflineTaskPhase) -> String {
        switch value {
        case .queued: return "Sırada"
        case .running: return "Yerelde çalışıyor"
        case .paused: return "Duraklatıldı · açık devam gerekli"
        case .waitingForNetwork: return "Bağlantı / uygun araç bekliyor"
        case .awaitingCloudResolution: return "Bulut sonucu belirsiz · tekrar çalıştırılmaz"
        case .completed: return "Sonuç hazır · henüz buluta gönderilmedi"
        case .failed: return "Başarısız · kayıt korundu"
        case .cancelled: return "İptal edildi"
        case .handedBack: return "Kaynak sohbetin taslağına aktarıldı"
        }
    }
}
