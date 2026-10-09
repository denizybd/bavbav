import AppKit

/// State-only checks: no website navigation, media request or OS permission.
@MainActor enum CompanionWebMediaCheck {
    static func run() -> Bool {
        let session = ChatGPTWebSession()
        let initial = session.voicePermissionGeneration
        session.companionVoiceVisible = true
        guard session.voicePermissionGeneration == initial else { return false }
        session.stopCompanionMedia(revokeRoute: false)
        guard session.companionVoiceVisible,
              session.voicePermissionGeneration != initial else { return false }
        let afterMediaStop = session.voicePermissionGeneration
        session.stopCompanionMedia()
        guard !session.companionVoiceVisible,
              session.voicePermissionGeneration != afterMediaStop else { return false }
        let afterClose = session.voicePermissionGeneration
        session.companionVoiceVisible = true
        session.companionVoiceVisible = false
        guard session.voicePermissionGeneration != afterClose else { return false }
        print("COMPANION WEB: media stop retains visible route; close revokes it; all stops revoke pending consent (6 assertions, state only)")
        return true
    }
}
