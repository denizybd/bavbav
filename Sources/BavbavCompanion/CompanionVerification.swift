/// Build/fixture results and availability probes are not live acceptance.
/// Keep the four requested product gates independent so a successful text
/// exchange cannot hide a blocked or failed image/audio check.
public struct CompanionVerification {
    public var accountMessage = false
    public var selectedWindowToModel = false
    public var turkishMicrophoneRecognition = false
    public var audibleTurkishResponse = false

    public init() {}
    public var automatedGatesPassed: Bool { accountMessage && selectedWindowToModel }
    public var productComplete: Bool {
        automatedGatesPassed && turkishMicrophoneRecognition && audibleTurkishResponse
    }
}
