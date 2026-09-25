import Foundation

/// Puts H.264 first in an offer and raises the H.264 level it states.
///
/// The level is not decoration. A host that cannot meet the level in the offer does not refuse: it
/// quietly encodes VP8 in software instead, and the only symptom is a picture that costs several
/// times the bandwidth at a fraction of the frame rate. libwebrtc offers level 3.1 on a Mac and in
/// the iOS Simulator, and 3.1 stops at 1280x720, so every full-size desktop arrived as VP8 until the
/// level was raised here. The Android app found the same thing first; this is its SdpPreference.kt.
///
/// Only the order and the level change. Nothing is removed, so a peer without H.264 still finds
/// common ground.
public enum SdpPreference {
    /// Level 5.2, written as SDP writes it: the level number times ten, in hexadecimal. It covers
    /// 4096x2176, beyond any desktop, and the Macs and iPhones this runs on decode it in hardware.
    /// It is also the ceiling: libwebrtc's parser knows nothing higher, and an offer claiming 6.x
    /// has its whole H.264 line discarded, which ends the session during negotiation.
    public static let level = "34"

    public static func preferH264(_ sdp: String, level: String = SdpPreference.level) -> String {
        // The level is raised first, and that result is what is returned even when H.264 already
        // leads: returning the original there would quietly undo it, which is a bug Android had.
        let raised = raiseH264Level(sdp, level: level)
        var lines = raised.components(separatedBy: "\r\n")
        guard let videoIndex = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return raised }

        let h264 = payloadTypes(for: "H264", in: lines)
        guard !h264.isEmpty else { return raised }

        let parts = lines[videoIndex].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return raised }
        let payloads = Array(parts.dropFirst(3))
        let reordered = h264.filter(payloads.contains) + payloads.filter { !h264.contains($0) }
        guard reordered != payloads else { return raised }
        lines[videoIndex] = (parts.prefix(3) + reordered).joined(separator: " ")
        return lines.joined(separator: "\r\n")
    }

    /// Raises every H.264 `profile-level-id` below `level` to it, keeping the profile. Never lowers.
    static func raiseH264Level(_ sdp: String, level: String) -> String {
        guard let wanted = Int(level, radix: 16) else { return sdp }
        return sdp.components(separatedBy: "\r\n").map { line in
            guard line.hasPrefix("a=fmtp:"), let range = line.range(of: "profile-level-id=") else { return line }
            let id = String(line[range.upperBound...].prefix(6))
            guard id.count == 6, let offered = Int(id.suffix(2), radix: 16), offered < wanted else { return line }
            return line.replacingOccurrences(of: "profile-level-id=\(id)", with: "profile-level-id=\(id.prefix(4))\(level)")
        }.joined(separator: "\r\n")
    }

    /// Every payload type whose rtpmap names this codec, in the order the offer lists them.
    private static func payloadTypes(for codec: String, in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard line.hasPrefix("a=rtpmap:") else { return nil }
            let body = line.dropFirst("a=rtpmap:".count)
            guard let space = body.firstIndex(of: " ") else { return nil }
            let payload = String(body[..<space])
            let name = body[body.index(after: space)...].split(separator: "/").first.map(String.init) ?? ""
            return name.caseInsensitiveCompare(codec) == .orderedSame ? payload : nil
        }
    }
}
