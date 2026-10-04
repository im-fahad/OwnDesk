package io.github.im_fahad.owndesk.ui

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.text.InputType
import android.text.method.ScrollingMovementMethod
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.github.im_fahad.owndesk.BuildConfig
import io.github.im_fahad.owndesk.device.KeystoreIdentity
import io.github.im_fahad.owndesk.device.PeerStore
import io.github.im_fahad.owndesk.net.Discovery
import io.github.im_fahad.owndesk.net.Endpoints
import io.github.im_fahad.owndesk.protocol.Encoding
import io.github.im_fahad.owndesk.protocol.Identity
import io.github.im_fahad.owndesk.protocol.Peer
import io.github.im_fahad.owndesk.session.PairingClient
import io.github.im_fahad.owndesk.session.TerminalKeyClient
import io.github.im_fahad.owndesk.session.UnpairClient
import io.github.im_fahad.owndesk.terminal.DeviceSshKey
import io.github.im_fahad.owndesk.terminal.TerminalSettings
import io.github.im_fahad.owndesk.terminal.TerminalStore
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
    /** Macs heard advertising themselves on this network, by device id. */
    private val onThisNetwork = mutableMapOf<String, String>()
    private val discovery by lazy {
        Discovery(this, onElsewhere = { deviceId, addresses -> learnedElsewhere(deviceId, addresses) }) { deviceId, address ->
            foundOnNetwork(deviceId, address)
        }
    }

    private lateinit var peerList: LinearLayout
    private lateinit var logView: TextView
    private lateinit var logPanel: View
    private lateinit var statusLine: TextView
    /** Shown while a Mac is asked to approve this phone, the way the iPhone app shows it. */
    private lateinit var pairingCard: LinearLayout
    private lateinit var pairingTitle: TextView
    private lateinit var pairButton: TextView
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
        discovery.start()
    }

    override fun onPause() {
        super.onPause()
        discovery.stop()
    }

    /**
     * A Mac said where it is. Remembering it is what stops a moved lease from making a Mac on the
     * same Wi-Fi look offline, which is otherwise only fixable by typing an address by hand.
     */
    private fun foundOnNetwork(deviceId: String, address: String) = runOnUiThread {
        if (peers.peer(deviceId) == null) return@runOnUiThread
        val known = onThisNetwork.put(deviceId, address) == address
        if (peers.noteDiscovered(deviceId, address) || !known) {
            log("${peers.peer(deviceId)?.name ?: "a Mac"} is on this network at $address")
            refreshPeers()
        }
    }

    /**
     * A Mac said where it can be reached away from home, its Tailscale addresses. Kept, so a Mac
     * paired while its Tailscale was off is still found from a cafe without anyone typing.
     */
    private fun learnedElsewhere(deviceId: String, addresses: List<String>) = runOnUiThread {
        if (peers.peer(deviceId) == null) return@runOnUiThread
        if (peers.noteElsewhere(deviceId, addresses)) {
            log("learned where ${peers.peer(deviceId)?.name ?: "a Mac"} is reachable away from home: ${addresses.joinToString(", ")}")
            refreshPeers()
        }
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
            if (match == null) {
                log("no paired Mac matches $prefix")
            } else {
                // A Mac whose address has moved cannot be found headlessly, because every stored
                // candidate is stale and there is nobody to long-press "Choose an address". Pins it
                // the same way that menu would; "Use any address" clears it again.
                intent.getStringExtra("address")?.let {
                    peers.setPreferred(match.deviceId, it)
                    log("pinned $it for ${match.name}")
                }
                connect(match)
            }
        }
        intent.getStringExtra("terminal")?.let { prefix ->
            val match = peers.all().firstOrNull {
                it.fingerprint.startsWith(prefix, ignoreCase = true) || it.deviceId.startsWith(prefix)
            }
            if (match == null) {
                log("no paired Mac matches $prefix")
            } else {
                intent.getStringExtra("address")?.let {
                    peers.setPreferred(match.deviceId, it)
                    log("pinned $it for ${match.name}")
                }
                intent.getStringExtra("ssh_user")?.let { user ->
                    TerminalStore(this).saveSettings(match.deviceId, TerminalSettings(user, intent.getIntExtra("ssh_port", 22)))
                }
                openTerminal(match)
            }
        }
        // Asks a Mac to allow this phone's terminal key, as the dialog's button does.
        intent.getStringExtra("terminal_ask")?.let { prefix ->
            val match = peers.all().firstOrNull {
                it.fingerprint.startsWith(prefix, ignoreCase = true) || it.deviceId.startsWith(prefix)
            }
            if (match == null) log("no paired Mac matches $prefix")
            else lifecycleScope.launch { log(askForTerminalKey(match, port = intent.getIntExtra("ssh_port", 22)).second) }
        }
        // Drops a Mac from this phone alone, the way a test cleans up the host it paired with.
        intent.getStringExtra("forget")?.let { prefix ->
            val match = peers.all().firstOrNull {
                it.fingerprint.startsWith(prefix, ignoreCase = true) || it.deviceId.startsWith(prefix)
            }
            if (match == null) log("no paired Mac matches $prefix")
            else {
                peers.forget(match.deviceId)
                TerminalStore(this).forget(match.deviceId)
                refreshPeers()
                log("forgot ${match.name}")
            }
        }
        // The phone's terminal key, so a test can put it on a Mac without reading the screen.
        if (intent.hasExtra("ssh_key")) {
            lifecycleScope.launch {
                val key = withContext(Dispatchers.IO) { DeviceSshKey.load() }
                log("ssh key ${key.authorizedKeysLine("OwnDesk on ${KeystoreIdentity.deviceName(this@MainActivity)}")} (${key.storage})")
            }
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
        pairingCard = waitingCard()
        list.addView(pairingCard, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(6) })
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
        pairButton = accentButton("Pair a Mac...") { if (!busy) askForCode() }
        addView(pairButton, rowParams(top = 12))
        addView(
            label(
                "On the Mac, open OwnDesk and choose Show a code. Approve there only when it shows this phone's fingerprint.",
                Theme.UI_SMALL,
                Theme.TEXT_FAINT,
            ),
            rowParams(top = 8),
        )
    }

    /**
     * The card that waits for the Mac's Approve. A pairing can take as long as the person needs to
     * walk to the Mac, so the wait is said in the list itself, not only in the status line.
     */
    private fun waitingCard(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.TOP
        visibility = View.GONE
        setPadding(dp(12), dp(12), dp(12), dp(12))
        background = GradientDrawable().apply {
            cornerRadius = dp(6).toFloat()
            setColor(Theme.PANEL)
            setStroke(1, (Theme.ACCENT and 0x00FFFFFF) or (0x99 shl 24))
        }
        addView(
            ProgressBar(this@MainActivity).apply {
                isIndeterminate = true
                indeterminateTintList = ColorStateList.valueOf(Theme.TEXT_DIM)
            },
            LinearLayout.LayoutParams(dp(18), dp(18)).apply { topMargin = dp(2); rightMargin = dp(10) },
        )
        val texts = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
        pairingTitle = label("", Theme.UI, Theme.TEXT)
        texts.addView(pairingTitle)
        texts.addView(
            label("Approve on the Mac only when it shows ${identity.fingerprint}.", Theme.UI_SMALL, Theme.TEXT_DIM),
            rowParams(top = 4),
        )
        addView(texts, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
    }

    private fun showWaiting(macName: String?) {
        if (macName == null) {
            pairingCard.visibility = View.GONE
            pairButton.alpha = 1f
        } else {
            pairingTitle.text = "Waiting for $macName to approve"
            pairingCard.visibility = View.VISIBLE
            pairButton.alpha = 0.5f
        }
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
            label("OwnDesk", Theme.TITLE, Theme.TEXT).apply {
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
        val live = onThisNetwork[peer.deviceId]
        // Where it actually is beats where it last answered: lastGood can be a Tailscale address
        // that is dead right now while the Mac sits on the same Wi-Fi as this phone.
        text.addView(
            when {
                chosen != null -> label("always $chosen", Theme.SECTION, Theme.ACCENT, mono = true)
                live != null -> label(live, Theme.SECTION, Theme.ONLINE, mono = true)
                else -> label(peer.candidates().firstOrNull() ?: "no address", Theme.SECTION, Theme.TEXT_FAINT, mono = true)
            }
        )
        row.addView(text, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))

        // The other way in: a shell through the Mac's own SSH server, on its own button so the
        // row itself still opens the screen as it always has.
        row.addView(
            View(this).apply { setBackgroundColor(Theme.BORDER) },
            LinearLayout.LayoutParams(1, dp(34)).apply { leftMargin = dp(8); rightMargin = dp(2) },
        )
        row.addView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                isClickable = true
                contentDescription = "Open a terminal on ${peer.name}"
                setPadding(dp(6), dp(2), dp(6), dp(2))
                setOnClickListener { openTerminal(peer) }
                addView(label(">_", Theme.UI, Theme.TEXT_DIM, mono = true).apply { setTypeface(typeface, Typeface.BOLD) })
                addView(label("Terminal", Theme.SECTION, Theme.TEXT_DIM))
            },
            LinearLayout.LayoutParams(dp(62), WRAP_CONTENT),
        )
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
            .setItems(arrayOf("Open a terminal", "Terminal settings", "Choose an address", "Use any address", "Unpair this Mac")) { _, which ->
                when (which) {
                    0 -> openTerminal(peer)
                    1 -> terminalSetup(peer)
                    2 -> askForAddress(peer)
                    3 -> {
                        peers.setPreferred(peer.deviceId, null)
                        log("${peer.name} will use whichever address answers")
                        refreshPeers()
                    }
                    4 -> confirmUnpair(peer)
                }
            }
            .show()
    }

    /**
     * Removes the pairing on both sides, so both must pair again. The Mac is told with a signed
     * UNPAIR when it can be reached; when it cannot, it still lists this phone, and the person is
     * asked to unpair the phone there too.
     */
    private fun confirmUnpair(peer: Peer) {
        AlertDialog.Builder(this)
            .setTitle("Unpair ${peer.name}?")
            .setMessage("This phone and the Mac forget each other, and must pair again before this phone can control it.")
            .setPositiveButton("Unpair") { _, _ ->
                val addresses = (listOfNotNull(onThisNetwork[peer.deviceId]) + peer.candidates()).distinct()
                peers.forget(peer.deviceId)
                TerminalStore(this).forget(peer.deviceId)
                refreshPeers()
                lifecycleScope.launch {
                    val told = UnpairClient(identity).unpair(peer.deviceId, addresses)
                    log(
                        if (told) "unpaired ${peer.name} on both sides"
                        else "unpaired ${peer.name} here, but it could not be reached: unpair this phone on the Mac too"
                    )
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * Every address this Mac is known by, tappable, with the typed field kept underneath. Tapping
     * fills the field rather than committing, so an address can still be corrected — a port
     * changed, a digit fixed — before it is used.
     */
    private fun askForAddress(peer: Peer) {
        val field = monoField(
            text = peer.preferred ?: peer.candidates().firstOrNull().orEmpty(),
            hint = "100.64.0.10:47500",
        )
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(label("Tap an address to use it, or type one below.", Theme.UI_SECONDARY, Theme.TEXT_DIM))
        val live = onThisNetwork[peer.deviceId]
        for (address in (listOfNotNull(live) + peer.candidates()).distinct()) {
            column.addView(addressChoice(address, noteFor(address, live)) { field.setText(address) }, rowParams(top = 8))
        }
        column.addView(label("Or type one", Theme.SECTION, Theme.TEXT_FAINT), rowParams(top = 14))
        column.addView(field, rowParams(top = 4))

        AlertDialog.Builder(this)
            .setTitle("Address for ${peer.name}")
            .setView(pad(column))
            .setPositiveButton("Use it") { _, _ ->
                val typed = field.text.toString().trim()
                peers.setPreferred(peer.deviceId, typed)
                log(if (typed.isEmpty()) "cleared the address for ${peer.name}" else "${peer.name} will use $typed")
                refreshPeers()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // Terminal ----------------------------------------------------------------------------------

    /**
     * Asks a Mac to let this phone's key in, and waits for someone there to answer. On a yes the login
     * is saved and the Mac's host keys are pinned from its signed answer, so the first terminal needs
     * neither a pasted line nor a fingerprint to compare. Returns whether it worked, and what to say.
     */
    private suspend fun askForTerminalKey(peer: Peer, port: Int): Pair<Boolean, String> {
        val hostKey = peers.publicKey(peer.deviceId) ?: return false to "${peer.name} is not paired any more."
        val key = withContext(Dispatchers.IO) { DeviceSshKey.load() }
        val addresses = (listOfNotNull(onThisNetwork[peer.deviceId]) + peer.candidates()).distinct()
        log("asking ${peer.name} to allow this phone's terminal key")
        return when (val outcome = TerminalKeyClient(identity).request(key.authorizedKeysLine(""), peer.deviceId, hostKey, addresses)) {
            is TerminalKeyClient.Outcome.Answered -> {
                val result = outcome.result
                if (result.granted) {
                    val store = TerminalStore(this)
                    store.saveSettings(peer.deviceId, TerminalSettings(result.username, port))
                    store.pinAll(peer.deviceId, result.host_keys)
                    true to if (result.status == "installed") "${peer.name} added this phone's key. The terminal opens without a password."
                    else "${peer.name} already had this phone's key."
                } else {
                    false to when (result.status) {
                        "expired" -> "Nobody answered on ${peer.name} in time. Try again when someone is at it."
                        "busy" -> "${peer.name} is answering another request. Try again in a moment."
                        "failed" -> "${peer.name} could not write its authorized_keys file."
                        else -> "Someone on ${peer.name} said no, or it is not letting others in right now."
                    }
                }
            }
            TerminalKeyClient.Outcome.Unreachable -> false to "${peer.name} did not answer. It has to be on, with \"Let others control it\" switched on."
            TerminalKeyClient.Outcome.NoAnswer -> false to "${peer.name} did not answer in time."
        }
    }

    /** Opens a Mac's terminal, asking how to log in first if that is not known yet. */
    private fun openTerminal(peer: Peer) {
        val saved = TerminalStore(this).settings(peer.deviceId)
        if (saved == null || saved.username.isBlank()) {
            terminalSetup(peer)
            return
        }
        log("opening a terminal on ${peer.name} as ${saved.username}")
        startActivity(TerminalActivity.intent(this, peer.deviceId))
    }

    /**
     * How to log in to a Mac's terminal, asked the first time and editable after. The terminal is
     * the Mac's own SSH server, so two things have to be true on the Mac: Remote Login is on, and
     * it knows this phone. The second is either this phone's key in `authorized_keys`, which the
     * dialog makes a single paste, or the account's password, asked for each time.
     */
    private fun terminalSetup(peer: Peer) {
        lifecycleScope.launch {
            val key = withContext(Dispatchers.IO) { DeviceSshKey.load() }
            val store = TerminalStore(this@MainActivity)
            val saved = store.settings(peer.deviceId)
            val userField = monoField(saved?.username ?: "", "user name on ${peer.name}")
            val portField = monoField((saved?.port ?: 22).toString(), "22").apply {
                inputType = InputType.TYPE_CLASS_NUMBER
            }
            val line = key.authorizedKeysLine("OwnDesk on ${KeystoreIdentity.deviceName(this@MainActivity)}")
            val command = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$line' >> ~/.ssh/authorized_keys"

            val column = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            column.addView(
                label(
                    "The terminal is ${peer.name}'s own SSH server. Turn on Remote Login there first: System Settings → General → Sharing → Remote Login. Behind its ⓘ, Allow full disk access for remote users lets the shell read Documents, Desktop and Downloads.",
                    Theme.UI_SECONDARY, Theme.TEXT_DIM,
                )
            )
            column.addView(sectionHeading("LOG IN AS"))
            column.addView(userField, rowParams(top = 0))
            column.addView(
                LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(label("Port", Theme.UI_SECONDARY, Theme.TEXT_DIM).apply { setPadding(0, 0, dp(8), 0) })
                    addView(portField, LinearLayout.LayoutParams(dp(90), WRAP_CONTENT))
                },
                rowParams(top = 8),
            )
            column.addView(label("The short name of the account, as whoami prints it in Terminal on the Mac.", Theme.UI_SMALL, Theme.TEXT_FAINT), rowParams(top = 6))

            column.addView(sectionHeading("LET ${peer.name.uppercase()} KNOW THIS PHONE"))
            val askNote = label(
                "Someone at ${peer.name} clicks Allow, and the terminal opens without a password from then on. It needs \"Let others control it\" on there.",
                Theme.UI_SMALL, Theme.TEXT_FAINT,
            )
            lateinit var ask: TextView
            ask = accentButton("Ask ${peer.name} to allow this phone") {
                ask.text = "Waiting for ${peer.name}…"
                ask.isClickable = false
                lifecycleScope.launch {
                    val port = portField.text.toString().trim().toIntOrNull() ?: 22
                    val (ok, message) = askForTerminalKey(peer, port)
                    log(message)
                    askNote.text = message
                    askNote.setTextColor(if (ok) Theme.ONLINE else Theme.WARN)
                    ask.text = "Ask ${peer.name} to allow this phone"
                    ask.isClickable = true
                    if (ok) store.settings(peer.deviceId)?.let { userField.setText(it.username) }
                }
            }
            column.addView(ask, rowParams(top = 0))
            column.addView(askNote, rowParams(top = 6))

            column.addView(sectionHeading("OR ADD THIS PHONE'S KEY BY HAND"))
            column.addView(
                label(
                    "With this key on ${peer.name}, the terminal opens without a password. Without it, you are asked for the account's password each time.",
                    Theme.UI_SMALL, Theme.TEXT_DIM,
                )
            )
            column.addView(
                label(line, Theme.SECTION, Theme.TEXT, mono = true).apply {
                    setBackgroundColor(Theme.PANEL)
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                    setTextIsSelectable(true)
                },
                rowParams(top = 8),
            )
            val note = label("The command adds the key to ~/.ssh/authorized_keys on ${peer.name}.", Theme.UI_SMALL, Theme.TEXT_FAINT)
            fun copy(text: String, said: String) {
                val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("OwnDesk key", text))
                note.text = "$said Paste it into Terminal on ${peer.name}."
                note.setTextColor(Theme.ONLINE)
            }
            column.addView(
                LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(accentButton("Copy the key") { copy(line, "Key copied.") }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
                    addView(
                        accentButton("Copy a command") { copy(command, "Command copied.") },
                        LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { leftMargin = dp(8) },
                    )
                },
                rowParams(top = 10),
            )
            column.addView(note, rowParams(top = 6))
            column.addView(
                label(
                    "Key ${key.fingerprint}, kept in this phone's ${if (key.storage == "hardware") "secure hardware" else "Keystore"}.",
                    Theme.SECTION, Theme.TEXT_FAINT, mono = true,
                ),
                rowParams(top = 6),
            )

            store.pinned(peer.deviceId)?.let { pinned ->
                column.addView(sectionHeading("${peer.name.uppercase()}'S SSH KEY"))
                column.addView(label("${pinned.type}  ${pinned.fingerprint}", Theme.SECTION, Theme.TEXT_DIM, mono = true).apply { setTextIsSelectable(true) })
                lateinit var forget: TextView
                forget = accentButton("Forget it") {
                    store.forgetHostKey(peer.deviceId)
                    log("forgot the SSH key of ${peer.name}")
                    forget.text = "Forgotten. The next terminal asks again."
                    forget.isClickable = false
                    forget.alpha = 0.6f
                }
                column.addView(forget, rowParams(top = 8))
                column.addView(label("Only if the Mac's key really changed, as after reinstalling macOS. The next terminal asks again.", Theme.UI_SMALL, Theme.TEXT_FAINT), rowParams(top = 6))
            }

            AlertDialog.Builder(this@MainActivity)
                .setTitle("Terminal on ${peer.name}")
                .setView(ScrollView(this@MainActivity).apply { addView(pad(column)) })
                .setPositiveButton("Open") { _, _ ->
                    val username = userField.text.toString().trim()
                    val port = portField.text.toString().trim().toIntOrNull() ?: 22
                    if (username.isEmpty()) {
                        log("a user name is needed for the terminal on ${peer.name}")
                        return@setPositiveButton
                    }
                    store.saveSettings(peer.deviceId, TerminalSettings(username, port))
                    openTerminal(peer)
                }
                .setNegativeButton("Cancel", null)
                .show()
        }
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
                showWaiting(qr.host_name)
                log("approve on the Mac if it shows ${identity.fingerprint}")
                val outcome = withContext(Dispatchers.IO) {
                    PairingClient(identity, KeystoreIdentity.deviceName(this@MainActivity)).pair(qr)
                }
                peers.save(outcome.peer)
                log("paired with ${outcome.peer.name} on ${outcome.address}")
                refreshPeers()
            } catch (e: Exception) {
                log("pairing failed: ${e.message}")
                // The waiting card is gone, so say why where the person is looking.
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("Pairing did not finish")
                    .setMessage((e.message ?: "The Mac did not answer.").replaceFirstChar { it.uppercase() })
                    .setPositiveButton("OK", null)
                    .show()
            } finally {
                busy = false
                showWaiting(null)
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
        Log.i("OwnDesk", line)
    }

    // View helpers --------------------------------------------------------------------------------

    /** One tappable address. */
    private fun addressChoice(address: String, note: String, onPick: () -> Unit): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Theme.PANEL)
            setPadding(dp(10), dp(8), dp(10), dp(8))
            isClickable = true
            setOnClickListener { onPick() }
            addView(label(address, Theme.UI_SECONDARY, Theme.TEXT, mono = true))
            addView(label(note, Theme.SECTION, if (note == ON_THIS_NETWORK) Theme.ONLINE else Theme.TEXT_FAINT))
        }

    /** Says what an address is for, since the choice between them is really a choice of route. */
    private fun noteFor(address: String, live: String?): String = when {
        address == live -> ON_THIS_NETWORK
        address.startsWith("100.") || address.contains("fd7a:115c:a1e0") -> "Tailscale, reaches it from anywhere"
        Endpoints.path(address) == "lan" -> "local network"
        else -> "elsewhere"
    }

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

    private companion object {
        const val ON_THIS_NETWORK = "on this network now"
    }
}
