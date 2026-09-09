package com.prc.controller.ui

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.content.Intent
import android.text.method.ScrollingMovementMethod
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.prc.controller.BuildConfig
import com.prc.controller.device.KeystoreIdentity
import com.prc.controller.device.PeerStore
import com.prc.controller.protocol.Encoding
import com.prc.controller.protocol.Peer
import com.prc.controller.session.PairingClient
import com.prc.controller.session.SessionClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * One screen: what this phone is, the Macs it has paired with, and a log of what happened.
 *
 * The fingerprint is shown at the top rather than buried, because pairing is only safe when both
 * people compare the same string, and a fingerprint nobody can find is a fingerprint nobody checks.
 */
class MainActivity : AppCompatActivity() {

    private val identity by lazy { KeystoreIdentity.load() }
    private val peers by lazy { PeerStore(this) }

    private lateinit var peerList: LinearLayout
    private lateinit var logView: TextView
    private lateinit var codeField: EditText
    private var busy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())
        log("this phone is ${identity.fingerprint}")
        refreshPeers()
        handleTestIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleTestIntent(intent)
    }

    /**
     * Lets a debug build be driven from a computer, the way the Macs can be driven by their control
     * CLI, so the pairing and connect paths can be tested without typing on the phone. Debug builds
     * only: a release build ignores these, so no other app can start a pairing here.
     */
    private fun handleTestIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        intent.getStringExtra("pairing_code_b64")?.let { encoded ->
            codeField.setText(Encoding.utf8Decode(Encoding.b64urlDecode(encoded)))
            log("received a pairing code from the test harness")
            pair()
        }
        intent.getStringExtra("connect")?.let { prefix ->
            val match = peers.all().firstOrNull { it.fingerprint.startsWith(prefix, ignoreCase = true) || it.deviceId.startsWith(prefix) }
            if (match == null) log("no paired Mac matches $prefix") else connect(match)
        }
    }

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(CONTENT)
            setPadding(dp(20), dp(28), dp(20), dp(20))
        }

        root.addView(label("PRC", 22f, TEXT, bold = true))
        root.addView(label("${KeystoreIdentity.deviceName(this)}  ·  ${identity.fingerprint}", 13f, DIM, mono = true))

        root.addView(section("PAIR WITH A MAC"))
        root.addView(label("On the Mac, open PRC and choose Show a code. Paste it here, then approve on the Mac when the fingerprints match.", 12f, FAINT))
        codeField = EditText(this).apply {
            hint = "Paste the pairing code"
            setHintTextColor(FAINT)
            setTextColor(TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.MONOSPACE
            maxLines = 4
            setBackgroundColor(PANEL)
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }
        root.addView(codeField, rowParams())
        root.addView(button("Pair") { pair() })

        root.addView(section("PAIRED MACS"))
        peerList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(peerList, rowParams())

        root.addView(section("LOG"))
        logView = TextView(this).apply {
            setTextColor(DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.MONOSPACE
            movementMethod = ScrollingMovementMethod()
        }
        root.addView(logView, rowParams())

        return ScrollView(this).apply {
            setBackgroundColor(CONTENT)
            addView(root, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
    }

    private fun refreshPeers() {
        peerList.removeAllViews()
        val all = peers.all()
        if (all.isEmpty()) {
            peerList.addView(label("None yet.", 12f, FAINT))
            return
        }
        for (peer in all) peerList.addView(peerRow(peer))
    }

    private fun peerRow(peer: Peer): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(PANEL)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            isClickable = true
            setOnClickListener { connect(peer) }
            setOnLongClickListener {
                peers.forget(peer.deviceId)
                log("forgot ${peer.name}")
                refreshPeers()
                true
            }
        }
        row.addView(label(peer.name, 14f, TEXT))
        row.addView(label("${peer.fingerprint}  ·  ${peer.addresses.firstOrNull() ?: "no address"}", 11f, DIM, mono = true))
        row.addView(label("Tap to connect, hold to forget", 10f, FAINT))
        return row
    }

    private fun pair() {
        if (busy) return
        val text = codeField.text.toString()
        if (text.isBlank()) {
            log("paste the code from the Mac first")
            return
        }
        busy = true
        log("pairing")
        lifecycleScope.launch {
            try {
                val qr = withContext(Dispatchers.IO) { PairingClient.parse(text) }
                log("code is from ${qr.host_name}, ${SessionClient.fingerprintOf(qr.host_device_id)}")
                log("approve on the Mac if it shows ${identity.fingerprint}")
                val outcome = withContext(Dispatchers.IO) {
                    PairingClient(identity, KeystoreIdentity.deviceName(this@MainActivity)).pair(qr)
                }
                peers.save(outcome.peer)
                codeField.setText("")
                log("paired with ${outcome.peer.name} on ${outcome.address}")
                refreshPeers()
            } catch (e: Exception) {
                log("pairing failed: ${e.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun connect(peer: Peer) {
        if (busy) return
        busy = true
        log("connecting to ${peer.name}")
        lifecycleScope.launch {
            try {
                val client = SessionClient(identity) { id -> peers.publicKey(id) }
                val accepted = withContext(Dispatchers.IO) {
                    client.connect(peer) { step -> runOnUiThread { log(step) } }
                }
                log("session ready: ${accepted.display}, ${accepted.path}, ${accepted.roundTripMs} ms")
                log("video and touch input are the next milestone")
            } catch (e: Exception) {
                log("connect failed: ${e.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun log(line: String) {
        val stamp = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        logView.append("$stamp  $line\n")
        // Mirrored so a build under test can be watched from a computer.
        Log.i("PRC", line)
    }

    // Small view helpers, so the layout reads as a list of rows rather than a pile of XML.

    private fun label(text: String, size: Float, color: Int, bold: Boolean = false, mono: Boolean = false): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            if (bold) setTypeface(typeface, Typeface.BOLD)
            if (mono) typeface = Typeface.MONOSPACE
            setPadding(0, dp(2), 0, dp(2))
        }

    private fun section(title: String): TextView = label(title, 11f, FAINT, bold = true).apply {
        setPadding(0, dp(22), 0, dp(6))
        letterSpacing = 0.08f
    }

    private fun button(text: String, action: () -> Unit): Button = Button(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        setBackgroundColor(ACCENT)
        gravity = Gravity.CENTER
        setOnClickListener { action() }
    }

    private fun rowParams() = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply {
        topMargin = dp(6)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val CONTENT = 0xFF1F1F1F.toInt()
        const val PANEL = 0xFF1A1A1A.toInt()
        const val TEXT = 0xFFCCCCCC.toInt()
        const val DIM = 0xFF8B8B8B.toInt()
        const val FAINT = 0xFF6A6A6A.toInt()
        const val ACCENT = 0xFF4D8EF7.toInt()
    }
}
