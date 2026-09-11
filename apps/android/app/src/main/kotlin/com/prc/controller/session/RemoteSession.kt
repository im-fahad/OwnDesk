package com.prc.controller.session

import android.content.Context
import com.prc.controller.media.WebRTCClient
import com.prc.controller.net.Endpoints
import com.prc.controller.net.SignalingClient
import com.prc.controller.protocol.Capabilities
import com.prc.controller.protocol.DataChannel
import com.prc.controller.protocol.DisplayInfo
import com.prc.controller.protocol.Encoding
import com.prc.controller.protocol.Envelope
import com.prc.controller.protocol.EnvelopeReceiver
import com.prc.controller.protocol.EnvelopeSender
import com.prc.controller.protocol.Peer
import com.prc.controller.protocol.ProtocolException
import com.prc.controller.protocol.ReceiveResult
import com.prc.controller.protocol.SessionAcceptPayload
import com.prc.controller.protocol.SessionAuthPayload
import com.prc.controller.protocol.SessionChallengePayload
import com.prc.controller.protocol.SessionRejectPayload
import com.prc.controller.protocol.SessionRequestPayload
import com.prc.controller.protocol.SigningIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.PeerConnection
import org.webrtc.VideoTrack
import java.security.PublicKey

/**
 * A live session with a Mac: the authenticated handshake (spec section 8), then the media
 * negotiation that follows on the same socket (section 11), then the screen and the input.
 *
 * The signaling socket stays open for the whole session rather than closing after the handshake,
 * because ICE candidates keep arriving after the picture starts and a reconnect needs somewhere to
 * put a new offer.
 */
class RemoteSession(
    private val context: Context,
    private val identity: SigningIdentity,
    private val peer: Peer,
    private val resolveKey: (String) -> PublicKey?,
    private val eglBase: EglBase,
    private val appVersion: String,
    private val listener: Listener,
) {
    interface Listener {
        fun onLog(line: String)
        fun onVideo(track: VideoTrack)
        fun onReady(display: DisplayInfo, path: String, address: String)
        /** The Mac changed the streamed display mid-session. Pointer mapping depends on this. */
        fun onDisplayChanged(display: DisplayInfo)
        /** Whether the Mac is really capturing. A paused capture leaves the last frame on screen. */
        fun onCapture(state: String, detail: String?)
        fun onEnded(reason: String)
    }

    private var client: SignalingClient? = null
    private var webrtc: WebRTCClient? = null
    private var sender: EnvelopeSender? = null
    private var receiver: EnvelopeReceiver? = null
    private var sessionId: String = ""
    private var clientNonce: String = ""
    private var ended = false

    var display: DisplayInfo? = null
        private set

    /** The address that answered, and what kind of route it turned out to be. */
    var address: String? = null
        private set
    var path: String? = null
        private set

    /** Connects, authenticates, and asks for the screen. Returns once the picture is negotiated. */
    suspend fun start() {
        val candidates = peer.candidates()
        if (candidates.isEmpty()) throw ProtocolException("no address to try; set one for this Mac")

        // Every address is probed at once. A Mac usually advertises a home address and a tailnet
        // one, and trying them in turn means waiting out a timeout on the wrong network before the
        // right address is attempted at all.
        listener.onLog("looking for ${peer.name}")
        val reachable = withContext(Dispatchers.IO) { Endpoints.firstReachable(candidates) }
        val order = if (reachable != null) {
            listener.onLog("$reachable answered")
            listOf(reachable) + candidates.filter { it != reachable }
        } else {
            listener.onLog("no address answered a probe; trying each in turn")
            candidates
        }

        var last: Exception = ProtocolException("no address answered")
        for (address in order) {
            val url = Endpoints.url(address) ?: continue
            listener.onLog("trying $address")
            try {
                attempt(url, address)
                return
            } catch (e: ProtocolException) {
                last = e
                if (e.reason != "connection") throw e
            }
        }
        throw last
    }

    private suspend fun attempt(url: String, address: String) {
        val opened = CompletableDeferred<Unit>()
        val challenge = CompletableDeferred<SessionChallengePayload>()
        val accepted = CompletableDeferred<SessionAcceptPayload>()
        clientNonce = Encoding.b64url(Encoding.randomBytes(16))
        val path = Endpoints.path(address)
        val sender = EnvelopeSender(identity).also { this.sender = it }
        val receiver = EnvelopeReceiver(selfDeviceId = identity.deviceId, resolveKey = resolveKey)
            .also { this.receiver = it }
        val socket = SignalingClient(url).also { this.client = it }

        socket.connect { event ->
            when (event) {
                is SignalingClient.Event.Opened -> opened.complete(Unit)
                is SignalingClient.Event.Closed -> {
                    val error = ProtocolException("connection")
                    opened.completeExceptionally(error)
                    challenge.completeExceptionally(error)
                    accepted.completeExceptionally(error)
                    if (!ended) listener.onEnded("the connection closed: ${event.reason}")
                }
                is SignalingClient.Event.Message -> {
                    when (val received = receiver.receive(event.text)) {
                        is ReceiveResult.Rejected -> listener.onLog("ignored a message: ${received.reason}")
                        is ReceiveResult.Accepted -> handle(received, challenge, accepted)
                    }
                }
            }
        }

        try {
            withTimeout(6_000) { opened.await() }
        } catch (e: TimeoutCancellationException) {
            throw ProtocolException("connection")
        }
        listener.onLog("connected to $address, declaring $path")

        val request = SessionRequestPayload(
            client_nonce = clientNonce,
            versions = Envelope.SUPPORTED_VERSIONS,
            path = path,
            capabilities = Capabilities(codecs = listOf("H264"), max_height = 1080, max_fps = 60),
        )
        send("SESSION_REQUEST", "", Envelope.json.encodeToString(SessionRequestPayload.serializer(), request))

        val challengePayload = try {
            withTimeout(15_000) { challenge.await() }
        } catch (e: TimeoutCancellationException) {
            throw ProtocolException("the Mac did not answer; check it is awake and hosting")
        }
        sessionId = challengePayload.session_id
        listener.onLog("authenticating")
        send(
            "SESSION_AUTH", sessionId,
            Envelope.json.encodeToString(
                SessionAuthPayload.serializer(), SessionAuthPayload(clientNonce, challengePayload.host_nonce),
            ),
        )

        val acceptPayload = try {
            withTimeout(15_000) { accepted.await() }
        } catch (e: TimeoutCancellationException) {
            throw ProtocolException("the Mac never confirmed the session")
        }
        display = acceptPayload.display
        this.address = address
        this.path = if (path == "lan") "Direct (LAN)" else "Direct (Tailscale or Internet)"
        listener.onReady(
            acceptPayload.display,
            if (path == "lan") "Direct (LAN)" else "Direct (Tailscale or Internet)",
            address,
        )

        startMedia()
    }

    private fun startMedia() {
        listener.onLog("asking for the screen")
        val media = WebRTCClient(context, eglBase, object : WebRTCClient.Listener {
            override fun onVideoTrack(track: VideoTrack) {
                listener.onLog("video track arrived")
                listener.onVideo(track)
            }

            override fun onIceCandidate(candidate: IceCandidate) {
                val payload = JSONObject()
                    .put("candidate", candidate.sdp)
                    .put("sdp_mid", candidate.sdpMid)
                    .put("sdp_mline_index", candidate.sdpMLineIndex)
                send("ICE_CANDIDATE", sessionId, payload.toString())
            }

            override fun onConnectionState(state: PeerConnection.PeerConnectionState) {
                listener.onLog("media ${state.name.lowercase()}")
                if (state == PeerConnection.PeerConnectionState.FAILED && !ended) {
                    listener.onEnded("the media connection failed")
                }
            }

            override fun onChannelOpen(label: String) {
                if (label == DataChannel.CONTROL) {
                    send(DataChannel.hello(appVersion, now()))
                    listener.onLog("input ready")
                }
            }

            override fun onControlFrame(label: String, text: String) {
                when (val message = DataChannel.parse(text, label)) {
                    is DataChannel.Incoming.Display -> {
                        display = message.info
                        listener.onLog("its screen is now ${message.info.width_px}x${message.info.height_px}")
                        listener.onDisplayChanged(message.info)
                    }
                    is DataChannel.Incoming.Capture -> listener.onCapture(message.state, message.detail)
                    is DataChannel.Incoming.Bye -> if (!ended) listener.onEnded("the Mac ended the session: ${message.reason}")
                    null -> Unit
                }
            }

            override fun onLog(line: String) = listener.onLog(line)
        }).also { webrtc = it }

        media.offer(iceRestart = false) { sdp, error ->
            if (sdp == null) {
                listener.onEnded("could not make an offer: $error")
                return@offer
            }
            send("SDP_OFFER", sessionId, JSONObject().put("sdp", sdp).put("ice_restart", false).toString())
        }
    }

    private fun handle(
        received: ReceiveResult.Accepted,
        challenge: CompletableDeferred<SessionChallengePayload>,
        accepted: CompletableDeferred<SessionAcceptPayload>,
    ) {
        val envelope = received.envelope
        if (envelope.from != peer.deviceId) return
        when (envelope.type) {
            "SESSION_CHALLENGE" -> {
                val payload = Envelope.json.decodeFromString(SessionChallengePayload.serializer(), received.payloadJson)
                if (payload.client_nonce != clientNonce || envelope.session != payload.session_id) {
                    challenge.completeExceptionally(ProtocolException("challenge does not match this request"))
                } else {
                    challenge.complete(payload)
                }
            }
            "SESSION_ACCEPT" -> {
                val payload = Envelope.json.decodeFromString(SessionAcceptPayload.serializer(), received.payloadJson)
                if (payload.client_nonce != clientNonce) {
                    accepted.completeExceptionally(ProtocolException("accept does not match this request"))
                } else {
                    accepted.complete(payload)
                }
            }
            "SESSION_REJECT" -> {
                val payload = Envelope.json.decodeFromString(SessionRejectPayload.serializer(), received.payloadJson)
                val error = ProtocolException(explain(payload.reason))
                challenge.completeExceptionally(error)
                accepted.completeExceptionally(error)
                if (challenge.isCompleted && accepted.isCompleted) listener.onEnded(explain(payload.reason))
            }
            "SDP_ANSWER" -> {
                val sdp = JSONObject(received.payloadJson).optString("sdp")
                webrtc?.applyAnswer(sdp) { error ->
                    if (error != null) listener.onEnded("the Mac's answer was refused: $error")
                    else listener.onLog("answer accepted, connecting media")
                }
            }
            "ICE_CANDIDATE" -> {
                val payload = JSONObject(received.payloadJson)
                webrtc?.addCandidate(
                    payload.optString("candidate"),
                    payload.optString("sdp_mid").takeIf { it.isNotEmpty() },
                    payload.optInt("sdp_mline_index", 0),
                )
            }
            "SESSION_END" -> {
                val reason = runCatching { JSONObject(received.payloadJson).optString("reason") }.getOrNull()
                listener.onEnded(if (reason.isNullOrEmpty()) "the Mac ended the session" else "the Mac ended the session: $reason")
            }
        }
    }

    /** What the stream is doing, straight from the peer connection. */
    fun stats(callback: (WebRTCClient.Stats) -> Unit) {
        webrtc?.stats(callback)
    }

    /** Input and control frames. Silently dropped before the channels open, which is correct. */
    fun send(message: JSONObject) {
        webrtc?.send(message)
    }

    fun end() {
        if (ended) return
        ended = true
        runCatching { webrtc?.send(DataChannel.bye("user", now())) }
        if (sessionId.isNotEmpty()) {
            runCatching { send("SESSION_END", sessionId, JSONObject().put("reason", "user").toString()) }
        }
        runCatching { webrtc?.close() }
        runCatching { client?.close() }
        webrtc = null
        client = null
    }

    private fun send(type: String, session: String, payloadJson: String) {
        val envelope = sender?.build(type, peer.deviceId, session, payloadJson) ?: return
        client?.send(envelope.serialize())
    }

    private fun now(): Long = System.currentTimeMillis()

    private fun explain(reason: String): String = when (reason) {
        "untrusted" -> "that Mac does not have this phone paired"
        "revoked" -> "this phone's access was revoked on that Mac"
        "remote_access_disabled" -> "that Mac is not letting others control it; turn Remote Access on"
        "busy" -> "that Mac is already in a session"
        "auth_failed" -> "the Mac refused this phone's signature"
        "version_unsupported" -> "the two sides speak different protocol versions"
        "expired" -> "the request expired"
        "host_error" -> "the Mac hit an internal error, often a missing screen permission"
        else -> "refused: $reason"
    }
}
