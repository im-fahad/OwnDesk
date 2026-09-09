package com.prc.controller.ui

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.method.ScrollingMovementMethod
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.prc.controller.BuildConfig
import com.prc.controller.device.KeystoreIdentity
import com.prc.controller.device.PeerStore
import com.prc.controller.net.Endpoints
import com.prc.controller.protocol.Encoding
import com.prc.controller.protocol.Identity
import com.prc.controller.protocol.Peer
import com.prc.controller.session.PairingClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The home screen: the Macs this phone can control, and what this phone is.
 *
 * It follows the Mac app's chrome rather than Android's defaults, because the two halves are one
 * product: the same dark palette, the same small type, the same section headings, and pairing
 * behind a button instead of a text field left open on screen.
 */
class MainActivity : AppCompatActivity() {

    private val identity by lazy { KeystoreIdentity.load() }
    private val peers by lazy { PeerStore(this) }

    private lateinit var peerList: LinearLayout
    private lateinit var logView: TextView
    private lateinit var logPanel: View
    private lateinit var statusLine: TextView
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

    override fun onResume() {
        super.onResume()
        refreshPeers()
    }

    /**
     * Lets a debug build be driven from a computer, the way the Mac app can be driven by its
     * control CLI, so pairing and connecting can be tested without typing on the phone. Debug builds
     * only: a release build ignores these, so no other app can start a pairing here.
     */
    private fun handleTestIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        intent.getStringExtra("pairing_code_b64")?.let { encoded ->
            pair(Encoding.utf8Decode(Encoding.b64urlDecode(encoded)))
        }
        intent.getStringExtra("connect")?.let { prefix ->
            val match = peers.all().firstOrNull {
                it.fingerprint.startsWith(prefix, ignoreCase = true) || it.deviceId.startsWith(prefix)
            }
            if (match == null) log("no paired Mac matches $prefix") else connect(match)
        }
    }

    // Layout ------------------------------------------------------------------------------------

    private fun buildLayout(): View {
        val screen = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Theme.CONTENT)
        }

        screen.addView(header(), LinearLayout.LayoutParams(MATCH_PARENT, dp(52) + systemInset("status_bar_height")))
        screen.addView(divider())

        // The list grows into the space; what this phone is stays pinned at the bottom, the way the
        // Mac app keeps THIS MAC at the foot of its sidebar.
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(16))
        }
        list.addView(sectionHeading("MACS YOU CAN CONTROL"))
        peerList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        list.addView(peerList, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        val scroller = ScrollView(this).apply {
            setBackgroundColor(Theme.CONTENT)
            isFillViewport = true
            addView(list, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        screen.addView(scroller, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        screen.addView(divider())
        screen.addView(thisPhone(), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        // The log hides behind the status bar, the way the Mac app keeps its log on a toggle.
        logView = TextView(this).apply {
            setTextColor(Theme.TEXT_DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.SECTION)
            typeface = Typeface.MONOSPACE
            movementMethod = ScrollingMovementMethod()
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }
        logPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Theme.PANEL)
            visibility = View.GONE
            addView(divider())
            addView(logView, LinearLayout.LayoutParams(MATCH_PARENT, dp(160)))
        }
        screen.addView(logPanel, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        screen.addView(divider())
        screen.addView(
            statusBar(),
            LinearLayout.LayoutParams(MATCH_PARENT, dp(28) + systemInset("navigation_bar_height")),
        )
        return screen
    }

    private fun thisPhone(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Theme.SIDEBAR)
        setPadding(dp(16), dp(4), dp(16), dp(16))
        addView(sectionHeading("THIS PHONE"))
        addView(label(identity.fingerprint, Theme.FINGERPRINT, Theme.TEXT, mono = true))
        addView(label(KeystoreIdentity.deviceName(this@MainActivity), Theme.UI_SMALL, Theme.TEXT_DIM))
        addView(accentButton("Pair a Mac...") { askForCode() }, rowParams(top = 12))
        addView(
            label(
                "On the Mac, open PRC and choose Show a code. Approve there only when it shows this phone's fingerprint.",
                Theme.UI_SMALL,
                Theme.TEXT_FAINT,
            ),
            rowParams(top = 8),
        )
    }

    /** The strip the system reserves for its own bars, so the header is not hidden under the clock. */
    private fun systemInset(name: String): Int {
        val id = resources.getIdentifier(name, "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    private fun header(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        setBackgroundColor(Theme.HEADER)
        setPadding(0, systemInset("status_bar_height"), 0, 0)
        addView(
            label("PRC", Theme.TITLE, Theme.TEXT).apply {
                setTypeface(typeface, Typeface.BOLD)
            }
        )
    }

    private fun statusBar(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setBackgroundColor(Theme.STATUS)
        setPadding(dp(16), 0, dp(16), systemInset("navigation_bar_height"))
        isClickable = true
        setOnClickListener {
            logPanel.visibility = if (logPanel.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        }
        statusLine = label("", Theme.SECTION, Theme.TEXT_DIM)
        addView(statusLine, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        addView(label(identity.fingerprint, Theme.SECTION, Theme.TEXT_FAINT, mono = true))
    }

    private fun refreshPeers() {
        peerList.removeAllViews()
        val all = peers.all()
        if (all.isEmpty()) {
            peerList.addView(label("None yet.", Theme.UI_SECONDARY, Theme.TEXT_FAINT))
            return
        }
        for (peer in all) peerList.addView(peerRow(peer), rowParams(top = 6))
    }

    private fun peerRow(peer: Peer): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Theme.PANEL)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            isClickable = true
            setOnClickListener { connect(peer) }
            setOnLongClickListener { showPeerOptions(peer); true }
        }

        val statusDot = dot(Theme.TEXT_FAINT)
        row.addView(statusDot, LinearLayout.LayoutParams(dp(7), dp(7)).apply { rightMargin = dp(10) })
        // Green once an address answers. Probing costs a moment, so it happens off the screen's
        // thread and the dot simply changes when the answer arrives.
        lifecycleScope.launch {
            val reachable = withContext(Dispatchers.IO) {
                Endpoints.firstReachable(peer.candidates(), timeoutMs = 1200)
            }
            if (reachable != null) statusDot.background = ovalOf(Theme.ONLINE)
        }

        val text = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        text.addView(label(peer.name, Theme.UI, Theme.TEXT))
        text.addView(label(peer.fingerprint, Theme.UI_SMALL, Theme.TEXT_DIM, mono = true))
        val chosen = peer.preferred
        if (chosen != null) {
            text.addView(label("always $chosen", Theme.SECTION, Theme.ACCENT, mono = true))
        } else {
            text.addView(
                label(peer.candidates().firstOrNull() ?: "no address", Theme.SECTION, Theme.TEXT_FAINT, mono = true)
            )
        }
        row.addView(text, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        return row
    }

    // Actions -----------------------------------------------------------------------------------

    /**
     * Address and removal, on a long press. The address matters when the same Mac is reachable by
     * more than one route: at home it answers on the local network, and away from home only a
     * Tailscale address will reach it.
     */
    private fun showPeerOptions(peer: Peer) {
        AlertDialog.Builder(this)
            .setTitle(peer.name)
            .setItems(arrayOf("Choose an address", "Use any address", "Forget this Mac")) { _, which ->
                when (which) {
                    0 -> askForAddress(peer)
                    1 -> {
                        peers.setPreferred(peer.deviceId, null)
                        log("${peer.name} will use whichever address answers")
                        refreshPeers()
                    }
                    2 -> {
                        peers.forget(peer.deviceId)
                        log("forgot ${peer.name}")
                        refreshPeers()
                    }
                }
            }
            .show()
    }

    private fun askForAddress(peer: Peer) {
        val field = monoField(
            text = peer.preferred ?: peer.candidates().firstOrNull().orEmpty(),
            hint = "100.64.0.10:47500",
        )
        AlertDialog.Builder(this)
            .setTitle("Address for ${peer.name}")
            .setMessage(
                "This Mac advertised:\n${peer.addresses.joinToString("\n")}\n\n" +
                    "A Tailscale address reaches it from any network, as long as this phone is on the same tailnet."
            )
            .setView(pad(field))
            .setPositiveButton("Use it") { _, _ ->
                val typed = field.text.toString().trim()
                peers.setPreferred(peer.deviceId, typed)
                log(if (typed.isEmpty()) "cleared the address for ${peer.name}" else "${peer.name} will use $typed")
                refreshPeers()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private val scan = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val code = result.data?.getStringExtra(ScanActivity.EXTRA_CODE)
        if (result.resultCode == RESULT_OK && !code.isNullOrBlank()) {
            log("read a code from the camera")
            pair(code)
        }
    }

    private fun askForCode() {
        val field = monoField(text = "", hint = "Paste the code from the Mac").apply {
            maxLines = 5
            setSingleLine(false)
        }
        AlertDialog.Builder(this)
            .setTitle("Pair a Mac")
            .setMessage("Scan the code the Mac is showing, or paste it. Approve on the Mac only when it shows ${identity.fingerprint}.")
            .setView(pad(field))
            .setPositiveButton("Pair") { _, _ -> pair(field.text.toString()) }
            .setNeutralButton("Scan a code") { _, _ -> scan.launch(ScanActivity.intent(this)) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun pair(code: String) {
        if (busy) return
        if (code.isBlank()) {
            log("nothing pasted")
            return
        }
        busy = true
        log("pairing")
        lifecycleScope.launch {
            try {
                val qr = withContext(Dispatchers.IO) { PairingClient.parse(code) }
                log("code is from ${qr.host_name}, ${Identity.fingerprint(qr.host_device_id)}")
                log("approve on the Mac if it shows ${identity.fingerprint}")
                val outcome = withContext(Dispatchers.IO) {
                    PairingClient(identity, KeystoreIdentity.deviceName(this@MainActivity)).pair(qr)
                }
                peers.save(outcome.peer)
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
        log("opening ${peer.name}")
        startActivity(SessionActivity.intent(this, peer.deviceId))
    }

    private fun log(line: String) {
        val stamp = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        logView.append("$stamp  $line\n")
        statusLine.text = line
        // Mirrored so a build under test can be watched from a computer.
        Log.i("PRC", line)
    }

    // View helpers --------------------------------------------------------------------------------

    private fun label(text: String, size: Float, color: Int, mono: Boolean = false): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            if (mono) typeface = Typeface.MONOSPACE
            setPadding(0, dp(1), 0, dp(1))
        }

    private fun sectionHeading(title: String): TextView =
        label(title, Theme.SECTION, Theme.TEXT_FAINT).apply {
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.1f
            setPadding(0, dp(20), 0, dp(8))
        }

    private fun accentButton(text: String, action: () -> Unit): TextView = TextView(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.UI_SECONDARY)
        gravity = Gravity.CENTER
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = GradientDrawable().apply {
            cornerRadius = dp(6).toFloat()
            setColor(Theme.ACCENT)
        }
        isClickable = true
        setOnClickListener { action() }
    }

    private fun monoField(text: String, hint: String): EditText = EditText(this).apply {
        setText(text)
        this.hint = hint
        setTextColor(Theme.TEXT)
        setHintTextColor(Theme.TEXT_FAINT)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.UI_SECONDARY)
        typeface = Typeface.MONOSPACE
        setBackgroundColor(Theme.PANEL)
        setPadding(dp(10), dp(10), dp(10), dp(10))
    }

    private fun pad(view: View): View = LinearLayout(this).apply {
        setPadding(dp(20), dp(8), dp(20), 0)
        addView(view, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
    }

    private fun dot(color: Int): View = View(this).apply { background = ovalOf(color) }

    private fun ovalOf(color: Int): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    private fun divider(): View = View(this).apply {
        setBackgroundColor(Theme.BORDER)
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, 1)
    }

    private fun rowParams(top: Int = 6) = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply {
        topMargin = dp(top)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
