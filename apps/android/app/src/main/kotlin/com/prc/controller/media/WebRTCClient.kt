package com.prc.controller.media

import android.content.Context
import com.prc.controller.protocol.DataChannel
import org.json.JSONObject
import org.webrtc.AudioTrack
import org.webrtc.DataChannel as RtcDataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

/**
 * The phone's peer connection: it offers, receives the Mac's screen, and owns the three data
 * channels (spec section 12). The Mac answers. That direction is not arbitrary: the side that
 * creates the channels is the side that decides their delivery rules, and those rules are what
 * keep pointer moves ahead of key presses.
 */
class WebRTCClient(
    context: Context,
    private val eglBase: EglBase,
    private val listener: Listener,
) {
    interface Listener {
        fun onVideoTrack(track: VideoTrack)
        fun onIceCandidate(candidate: IceCandidate)
        fun onConnectionState(state: PeerConnection.PeerConnectionState)
        fun onChannelOpen(label: String)
        /** One frame the Mac sent, still as text: the session layer decides what it means. */
        fun onControlFrame(label: String, text: String)
        fun onLog(line: String)
    }

    private val factory: PeerConnectionFactory
    private val connection: PeerConnection
    private val channels = HashMap<String, RtcDataChannel>()

    init {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                .createInitializationOptions()
        )
        factory = PeerConnectionFactory.builder()
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .createPeerConnectionFactory()

        val config = PeerConnection.RTCConfiguration(emptyList()).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }

        connection = factory.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) = listener.onIceCandidate(candidate)
            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) =
                listener.onConnectionState(newState)

            override fun onTrack(transceiver: RtpTransceiver) {
                (transceiver.receiver?.track() as? VideoTrack)?.let(listener::onVideoTrack)
            }

            override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {
                (receiver.track() as? VideoTrack)?.let(listener::onVideoTrack)
            }

            override fun onSignalingChange(state: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
            override fun onAddStream(stream: MediaStream) {}
            override fun onRemoveStream(stream: MediaStream) {}
            override fun onDataChannel(channel: RtcDataChannel) {}
            override fun onRenegotiationNeeded() {}
        }) ?: error("could not create a peer connection")

        // Receive only: the phone never sends a camera or a microphone anywhere.
        connection.addTransceiver(
            org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
        )

        for (label in listOf(DataChannel.LOSSY, DataChannel.RELIABLE, DataChannel.CONTROL)) {
            val init = RtcDataChannel.Init().apply {
                ordered = label != DataChannel.LOSSY
                if (label == DataChannel.LOSSY) maxRetransmits = 0
            }
            val channel = connection.createDataChannel(label, init) ?: continue
            channel.registerObserver(object : RtcDataChannel.Observer {
                override fun onBufferedAmountChange(previous: Long) {}
                override fun onStateChange() {
                    if (channel.state() == RtcDataChannel.State.OPEN) listener.onChannelOpen(label)
                }
                override fun onMessage(buffer: RtcDataChannel.Buffer) {
                    // Binary frames are not part of the protocol, and an oversized one is refused
                    // here rather than parsed (spec section 21).
                    if (buffer.binary) return
                    val remaining = buffer.data.remaining()
                    if (remaining > DataChannel.MAX_BYTES) return
                    val bytes = ByteArray(remaining)
                    buffer.data.get(bytes)
                    listener.onControlFrame(label, String(bytes, StandardCharsets.UTF_8))
                }
            })
            channels[label] = channel
        }
    }

    /** Creates the offer and sets it locally, returning the SDP to put in an envelope. */
    fun offer(iceRestart: Boolean, done: (String?, String?) -> Unit) {
        val constraints = MediaConstraints().apply {
            if (iceRestart) mandatory.add(MediaConstraints.KeyValuePair("IceRestart", "true"))
        }
        connection.createOffer(object : SimpleSdpObserver() {
            override fun onCreateSuccess(description: SessionDescription) {
                // Ask for H.264 first. Both sides do it in hardware; Android's default order would
                // otherwise settle on VP8, which the Mac then encodes in software.
                val preferred = SessionDescription(
                    description.type,
                    SdpPreference.preferH264(description.description),
                )
                connection.setLocalDescription(object : SimpleSdpObserver() {
                    override fun onSetSuccess() = done(preferred.description, null)
                    override fun onSetFailure(error: String?) = done(null, error)
                }, preferred)
            }

            override fun onCreateFailure(error: String?) = done(null, error)
        }, constraints)
    }

    fun applyAnswer(sdp: String, done: (String?) -> Unit) {
        connection.setRemoteDescription(object : SimpleSdpObserver() {
            override fun onSetSuccess() = done(null)
            override fun onSetFailure(error: String?) = done(error)
        }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
    }

    fun addCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
        connection.addIceCandidate(IceCandidate(sdpMid, sdpMLineIndex, candidate))
    }

    /**
     * What the stream is actually doing, read from the peer connection rather than guessed. The
     * same numbers the Mac app reports for itself, so a bad link can be told from a bad decoder.
     */
    data class Stats(
        val width: Int = 0,
        val height: Int = 0,
        val fps: Double = 0.0,
        val kbps: Long = 0,
        val packetsLost: Int = 0,
        val jitterMs: Double = 0.0,
        val roundTripMs: Double = 0.0,
        val codec: String? = null,
    )

    private var lastBytes = 0L
    private var lastBytesAt = 0L

    fun stats(callback: (Stats) -> Unit) {
        connection.getStats { report ->
            var width = 0
            var height = 0
            var fps = 0.0
            var bytes = 0L
            var lost = 0
            var jitter = 0.0
            var rtt = 0.0
            var codecId: String? = null
            val codecNames = HashMap<String, String>()

            for (entry in report.statsMap.values) {
                val members = entry.members
                when (entry.type) {
                    "inbound-rtp" -> if (members["kind"] == "video" || members["mediaType"] == "video") {
                        width = number(members["frameWidth"])?.toInt() ?: width
                        height = number(members["frameHeight"])?.toInt() ?: height
                        fps = number(members["framesPerSecond"]) ?: fps
                        bytes = number(members["bytesReceived"])?.toLong() ?: bytes
                        lost = number(members["packetsLost"])?.toInt() ?: lost
                        jitter = (number(members["jitter"]) ?: 0.0) * 1000
                        codecId = members["codecId"] as? String ?: codecId
                    }
                    "candidate-pair" -> if (members["state"] == "succeeded" || number(members["currentRoundTripTime"]) != null) {
                        val value = number(members["currentRoundTripTime"])
                        if (value != null && value > 0) rtt = value * 1000
                    }
                    "codec" -> {
                        val name = members["mimeType"] as? String
                        if (name != null) codecNames[entry.id] = name.substringAfter('/')
                    }
                }
            }

            // Bitrate is a rate, so it only exists between two readings.
            val now = System.currentTimeMillis()
            val kbps = if (lastBytesAt > 0 && now > lastBytesAt && bytes >= lastBytes) {
                (bytes - lastBytes) * 8 / (now - lastBytesAt)
            } else {
                0L
            }
            lastBytes = bytes
            lastBytesAt = now

            callback(
                Stats(
                    width = width, height = height, fps = fps, kbps = kbps,
                    packetsLost = lost, jitterMs = jitter, roundTripMs = rtt,
                    codec = codecId?.let { codecNames[it] },
                )
            )
        }
    }

    /** Statistics arrive as whatever numeric type the platform chose, so take them all. */
    private fun number(value: Any?): Double? = when (value) {
        is Double -> value
        is Float -> value.toDouble()
        is Long -> value.toDouble()
        is Int -> value.toDouble()
        is java.math.BigInteger -> value.toDouble()
        is Number -> value.toDouble()
        else -> null
    }

    /** Sends one frame on the channel its type belongs to, dropping it if that channel is closed. */
    fun send(message: JSONObject): Boolean {
        val label = DataChannel.channelFor(message.optString("type"))
        val channel = channels[label] ?: return false
        if (channel.state() != RtcDataChannel.State.OPEN) return false
        val bytes = message.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > DataChannel.MAX_BYTES) return false
        return channel.send(RtcDataChannel.Buffer(ByteBuffer.wrap(bytes), false))
    }

    fun isOpen(label: String): Boolean = channels[label]?.state() == RtcDataChannel.State.OPEN

    fun close() {
        for (channel in channels.values) runCatching { channel.close() }
        channels.clear()
        runCatching { connection.close() }
        runCatching { connection.dispose() }
        runCatching { factory.dispose() }
    }

    private open class SimpleSdpObserver : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) {}
        override fun onSetFailure(error: String?) {}
    }
}
