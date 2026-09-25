import Testing
@testable import OwnDeskControllerCore

/// The same cases as the Android app's SdpPreferenceTest.kt.
@Suite struct SdpPreferenceTests {
    func sdp(_ videoLine: String, _ rest: String...) -> String {
        (["v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", videoLine] + rest).joined(separator: "\r\n")
    }

    func videoLine(_ sdp: String) -> String? {
        sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("m=video") }
    }

    @Test func h264MovesToTheFrontOfTheVideoLine() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 96 98 100", "a=rtpmap:96 VP8/90000", "a=rtpmap:98 H264/90000", "a=rtpmap:100 VP9/90000")
        #expect(videoLine(SdpPreference.preferH264(offer)) == "m=video 9 UDP/TLS/RTP/SAVPF 98 96 100")
    }

    @Test func everyH264PayloadTypeIsPromotedKeepingTheirOrder() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 96 98 102 104", "a=rtpmap:96 VP8/90000", "a=rtpmap:98 H264/90000",
                        "a=rtpmap:102 H264/90000", "a=rtpmap:104 AV1/90000")
        #expect(videoLine(SdpPreference.preferH264(offer)) == "m=video 9 UDP/TLS/RTP/SAVPF 98 102 96 104")
    }

    @Test func theLevelIsRaisedSoAFullSizeDesktopIsAllowed() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 96 98", "a=rtpmap:96 VP8/90000", "a=rtpmap:98 H264/90000",
                        "a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f")
        let out = SdpPreference.preferH264(offer)
        #expect(out.contains("profile-level-id=42e034"), "level was left at 3.1: \(out)")
        #expect(out.contains("packetization-mode=1"), "other parameters were lost")
    }

    @Test func aLevelAlreadyHighEnoughIsLeftAlone() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 98", "a=rtpmap:98 H264/90000", "a=fmtp:98 profile-level-id=640c34")
        #expect(SdpPreference.preferH264(offer, level: "2a").contains("profile-level-id=640c34"))
    }

    /// Android had this bug: with H.264 already first, the original offer came back, and the raised
    /// level with it went missing.
    @Test func theLevelIsRaisedEvenWhenH264AlreadyLeads() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 98 96", "a=rtpmap:98 H264/90000", "a=rtpmap:96 VP8/90000",
                        "a=fmtp:98 profile-level-id=42e01f")
        #expect(SdpPreference.preferH264(offer).contains("profile-level-id=42e034"))
    }

    @Test func anOfferWithoutH264IsUnchanged() {
        let offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 VP8/90000")
        #expect(SdpPreference.preferH264(offer) == offer)
    }
}
