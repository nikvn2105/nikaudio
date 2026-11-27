import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var storage: UserDefaults?
    private var receivedVideo = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        storage = ScreenProbe.storage
        receivedVideo = false
        guard let storage = storage else {
            finishBroadcastWithError(NSError(
                domain: "NiKAudio.ScreenBroadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Chữ ký extension không cấp được App Group NiKAudio."]
            ))
            return
        }
        storage.set(ScreenProbe.State.started.rawValue, forKey: ScreenProbe.stateKey)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, !receivedVideo, CMSampleBufferIsValid(sampleBuffer) else { return }
        receivedVideo = true
        storage?.set(ScreenProbe.State.video.rawValue, forKey: ScreenProbe.stateKey)
    }

    override func broadcastFinished() {
        if !receivedVideo {
            storage?.set(ScreenProbe.State.stopped.rawValue, forKey: ScreenProbe.stateKey)
        }
    }
}
