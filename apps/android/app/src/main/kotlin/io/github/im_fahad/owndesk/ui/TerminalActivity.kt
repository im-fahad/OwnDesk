package io.github.im_fahad.owndesk.ui

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import com.jcraft.jsch.UIKeyboardInteractive
import com.jcraft.jsch.UserInfo
import io.github.im_fahad.owndesk.device.PeerStore
import io.github.im_fahad.owndesk.net.Discovery
import io.github.im_fahad.owndesk.net.Endpoints
import io.github.im_fahad.owndesk.protocol.Peer
import io.github.im_fahad.owndesk.terminal.DeviceSshKey
import io.github.im_fahad.owndesk.terminal.HostKeyVerdict
import io.github.im_fahad.owndesk.terminal.SshShell
import io.github.im_fahad.owndesk.terminal.SshShellException
import io.github.im_fahad.owndesk.terminal.TerminalSettings
import io.github.im_fahad.owndesk.terminal.TerminalStore
import io.github.im_fahad.owndesk.terminal.TerminalView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * A shell on a Mac, drawn by [TerminalView] and carried by SSH.
 *
 * Everything is the Mac's: its SSH server checks who this is, its shell runs what is typed. This
 * screen only draws what comes back, sends the keys, and says what went wrong in words that say what
 * to do about it. A key bar under the terminal gives the keys a phone keyboard lacks: Escape,
 * Control, Tab, the arrows.
 */
class TerminalActivity : AppCompatActivity(), TerminalView.Host, SshShell.Listener, UserInfo, UIKeyboardInteractive {

    private lateinit var terminal: TerminalView
    private lateinit var titleView: TextView
    private lateinit var subtitleView: TextView
    private lateinit var card: LinearLayout
    private lateinit var cardMessage: TextView
    private lateinit var cardSpinner: ProgressBar
    private lateinit var cardButtons: LinearLayout
    private lateinit var ctrlKey: TextView
    private lateinit var header: View
    private lateinit var headerRule: View
    private lateinit var altKey: TextView

    private lateinit var peer: Peer
    private lateinit var settings: TerminalSettings
    private val store by lazy { TerminalStore(this) }
    private var shell: SshShell? = null
    private var connected = false
    private var exitStatus: Int? = null
    private var attempt = 0
    private val password = AtomicReference<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
        val found = deviceId?.let { PeerStore(this).peer(it) }
        val saved = deviceId?.let { store.settings(it) }
        if (found == null || saved == null || saved.username.isBlank()) {
            Toast.makeText(this, "That Mac is not paired any more, or its terminal is not set up.", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        peer = found
        settings = saved
        setContentView(buildLayout())
        fitOrientation(resources.configuration)
        // Connect once the terminal has its real size, so the shell starts with the right one.
        terminal.post { connect() }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        fitOrientation(newConfig)
    }

    /**
     * Sideways, the keyboard takes most of the screen, and the header and the status bar would
     * leave the terminal two rows. They make way for it; the key bar stays, since it is the keys.
     */
    private fun fitOrientation(config: android.content.res.Configuration) {
        val landscape = config.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        header.visibility = if (landscape) View.GONE else View.VISIBLE
        headerRule.visibility = header.visibility
        val bars = WindowCompat.getInsetsController(window, window.decorView)
        if (landscape) {
            bars.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            bars.hide(WindowInsetsCompat.Type.statusBars())
        } else {
            bars.show(WindowInsetsCompat.Type.statusBars())
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        shell?.close()
    }

    // Layout ------------------------------------------------------------------------------------

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Theme.CONTENT)
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }

        // Header: close, the Mac's name, and what the shell calls itself.
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Theme.HEADER)
            setPadding(dp(4), 0, dp(12), 0)
        }
        header.addView(
            label("✕", Theme.TITLE, Theme.TEXT_DIM).apply {
                gravity = Gravity.CENTER
                setPadding(dp(12), dp(8), dp(12), dp(8))
                isClickable = true
                contentDescription = "Close the terminal"
                setOnClickListener { finish() }
            }
        )
        val titles = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        titleView = label(peer.name, Theme.UI, Theme.TEXT).apply { setTypeface(typeface, Typeface.BOLD) }
        subtitleView = label("${settings.username} · terminal", Theme.SECTION, Theme.TEXT_FAINT, mono = true)
        titles.addView(titleView)
        titles.addView(subtitleView)
        header.addView(titles, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        header.addView(
            label("⌨", Theme.TITLE, Theme.TEXT_DIM).apply {
                setPadding(dp(10), dp(6), dp(4), dp(6))
                isClickable = true
                contentDescription = "Show or hide the keyboard"
                setOnClickListener { if (terminal.isFocused) terminal.hideKeyboard() else terminal.showKeyboard() }
            }
        )
        root.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, dp(48)))
        this.header = header
        headerRule = divider()
        root.addView(headerRule)

        // The terminal, with a card over it while connecting and when the shell has ended.
        val stage = FrameLayout(this)
        terminal = TerminalView(this).apply {
            host = this@TerminalActivity
            setPadding(dp(4), dp(4), dp(4), dp(2))
            onPaste = { paste() }
        }
        stage.addView(terminal, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(18), dp(18), dp(18), dp(18))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(0xF51A1A1A.toInt())
                setStroke(1, Theme.BORDER)
            }
        }
        cardSpinner = ProgressBar(this)
        card.addView(cardSpinner, LinearLayout.LayoutParams(dp(28), dp(28)))
        cardMessage = label("", Theme.UI, Theme.TEXT).apply { gravity = Gravity.CENTER }
        card.addView(cardMessage, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(10) })
        cardButtons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        cardButtons.addView(button("Close", Theme.TEXT_DIM) { finish() })
        cardButtons.addView(button("Reconnect", Theme.ACCENT) { connect() }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { leftMargin = dp(10) })
        card.addView(cardButtons, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(14) })
        stage.addView(
            card,
            FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.CENTER).apply {
                leftMargin = dp(32); rightMargin = dp(32)
            }
        )
        root.addView(stage, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        root.addView(divider())
        root.addView(keyBar(), LinearLayout.LayoutParams(MATCH_PARENT, dp(40)))
        return root
    }

    /** The keys a phone keyboard has no room for. Control and Alt hold for the next key. */
    private fun keyBar(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(4), 0)
        }
        fun key(text: String, description: String, action: () -> Unit): TextView = label(text, Theme.UI_SECONDARY, Theme.TEXT).apply {
            gravity = Gravity.CENTER
            typeface = Typeface.MONOSPACE
            minWidth = dp(44)
            setPadding(dp(10), dp(6), dp(10), dp(6))
            isClickable = true
            contentDescription = description
            setOnClickListener { action() }
        }
        fun keyOf(code: Int) = { terminal.sendKey(code, 0); Unit }
        ctrlKey = key("CTRL", "Control, for the next key") { terminal.ctrlPending = !terminal.ctrlPending }
        altKey = key("ALT", "Alt, for the next key") { terminal.altPending = !terminal.altPending }
        listOf(
            key("ESC", "Escape", keyOf(KeyEvent.KEYCODE_ESCAPE)),
            key("TAB", "Tab", keyOf(KeyEvent.KEYCODE_TAB)),
            ctrlKey,
            altKey,
            key("←", "Left", keyOf(KeyEvent.KEYCODE_DPAD_LEFT)),
            key("↑", "Up", keyOf(KeyEvent.KEYCODE_DPAD_UP)),
            key("↓", "Down", keyOf(KeyEvent.KEYCODE_DPAD_DOWN)),
            key("→", "Right", keyOf(KeyEvent.KEYCODE_DPAD_RIGHT)),
            key("HOME", "Home", keyOf(KeyEvent.KEYCODE_MOVE_HOME)),
            key("END", "End", keyOf(KeyEvent.KEYCODE_MOVE_END)),
            key("PGUP", "Page up", keyOf(KeyEvent.KEYCODE_PAGE_UP)),
            key("PGDN", "Page down", keyOf(KeyEvent.KEYCODE_PAGE_DOWN)),
            key("-", "Minus") { terminal.sendText("-") },
            key("/", "Slash") { terminal.sendText("/") },
            key("|", "Pipe") { terminal.sendText("|") },
            key("~", "Tilde") { terminal.sendText("~") },
            key("PASTE", "Paste the clipboard") { paste() },
        ).forEach { row.addView(it, LinearLayout.LayoutParams(WRAP_CONTENT, MATCH_PARENT)) }
        modifiersChanged()
        return HorizontalScrollView(this).apply {
            setBackgroundColor(Theme.STATUS)
            isHorizontalScrollBarEnabled = false
            addView(row, LinearLayout.LayoutParams(WRAP_CONTENT, MATCH_PARENT))
        }
    }

    private fun showCard(message: String, busy: Boolean) {
        cardMessage.text = message
        cardSpinner.visibility = if (busy) View.VISIBLE else View.GONE
        cardButtons.visibility = if (busy) View.GONE else View.VISIBLE
        card.visibility = View.VISIBLE
    }

    private fun paste() {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()
        if (text.isNullOrEmpty()) Toast.makeText(this, "Nothing to paste.", Toast.LENGTH_SHORT).show()
        else terminal.sendText(text, paste = true)
    }

    // Connection ----------------------------------------------------------------------------------

    private fun connect() {
        shell?.close()
        shell = null
        connected = false
        exitStatus = null
        password.set(null)
        val number = ++attempt
        showCard("Connecting to ${peer.name}…", busy = true)
        val name = peer.name
        val port = settings.port
        lifecycleScope.launch(Dispatchers.IO) {
            // Where the Mac says it is right now goes first, then every address it was known by. Away
            // from Wi-Fi there is no local network to ask, and its local addresses can only time
            // out, so the tailnet ones go first instead.
            val local = onLocalNetwork()
            val live = if (local) findOnNetwork() else null
            var known = listOfNotNull(live) + peer.candidates()
            if (!local) known = known.sortedBy { if (Endpoints.path(it) == "lan") 1 else 0 }
            val hosts = known.map { Endpoints.host(it) }.filter { it.isNotEmpty() }.distinct()
            val addresses = hosts.map { if (it.contains(':')) "[$it]:$port" else "$it:$port" }
            // All probed at once, then tried one by one in that order. A router that moves its
            // leases can hand an old address of this Mac to another Mac, and both answer on port 22.
            val reachable = Endpoints.reachableInOrder(addresses, timeoutMs = 4000)
            if (reachable.isEmpty()) {
                ended(number, "Nothing answered on port $port of $name. Turn on Remote Login there: System Settings → General → Sharing → Remote Login.")
                return@launch
            }
            val key = try {
                DeviceSshKey.load()
            } catch (e: Exception) {
                ended(number, "This phone's terminal key could not be used: ${e.message ?: e}")
                return@launch
            }
            var changed: String? = null
            for (address in reachable) {
                if (number != attempt) return@launch
                val host = Endpoints.host(address)
                val fresh = SshShell(this@TerminalActivity)
                // Kept, so the host key question can show the key this very connection was given.
                val repository = store.repositoryFor(peer.deviceId)
                shellRepository = repository
                try {
                    fresh.connect(
                        host = host, port = port, username = settings.username, key = key,
                        hostKeys = repository, userInfo = this@TerminalActivity,
                        columns = terminal.gridColumns.coerceAtLeast(80), rows = terminal.gridRows.coerceAtLeast(24),
                    )
                } catch (e: SshShellException.HostKeyChanged) {
                    // Not this Mac's key: another machine at an address this one used to have.
                    if (changed == null) changed = e.fingerprint
                    log("$host presented a different SSH key than $name's; trying its next address")
                    continue
                } catch (e: SshShellException) {
                    ended(number, describe(e))
                    return@launch
                } catch (e: Exception) {
                    ended(number, "The connection to $name failed: ${e.message ?: e}")
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    if (number != attempt || isFinishing) { fresh.close(); return@withContext }
                    shell = fresh
                    connected = true
                    fresh.resize(terminal.gridColumns, terminal.gridRows)
                    card.visibility = View.GONE
                    terminal.showKeyboard()
                    log("terminal open on $name at $host:$port")
                }
                return@launch
            }
            // Every address answered with a key other than the pinned one.
            val fingerprint = changed ?: return@launch
            ask(
                title = "$name's SSH key has changed",
                message = "It now presents $fingerprint, not the key this phone saved, so the connection was refused: this is what someone in the middle would look like. If the Mac's key really changed, for example after reinstalling macOS, forget the old key in Terminal settings.",
                yes = null,
            )
            ended(number, "Not connected: $name's SSH key has changed. If it really did, forget the old key in Terminal settings.")
        }
    }

    /** Whether this phone is on a Wi-Fi or wired network, where a Mac could be found nearby. */
    private fun onLocalNetwork(): Boolean {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        @Suppress("DEPRECATION")
        return manager.allNetworks.any { network ->
            val caps = manager.getNetworkCapabilities(network) ?: return@any false
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)
        }
    }

    /**
     * Listens briefly for this Mac's own advertisement, which is where it is now. Its device id is
     * in the TXT record, so this is the one address known to be this Mac rather than one it used to
     * have. Remembered, so the home screen and the next connection start from it too.
     */
    private fun findOnNetwork(waitMs: Long = 2000): String? {
        val found = AtomicReference<String?>(null)
        val done = CountDownLatch(1)
        val discovery = Discovery(this) { deviceId, address ->
            if (deviceId == peer.deviceId && found.compareAndSet(null, address)) done.countDown()
        }
        discovery.start()
        try {
            done.await(waitMs, TimeUnit.MILLISECONDS)
        } finally {
            discovery.stop()
        }
        val address = found.get() ?: return null
        PeerStore(this).noteDiscovered(peer.deviceId, address)
        log("${peer.name} is on this network at $address")
        return address
    }

    private fun ended(number: Int, message: String) = runOnUiThread {
        if (number != attempt || isFinishing) return@runOnUiThread
        connected = false
        showCard(message, busy = false)
        log(message)
    }

    private fun describe(e: SshShellException): String {
        val name = peer.name
        return when (e) {
            is SshShellException.Unreachable ->
                "Nothing answered on port ${settings.port} of $name. Turn on Remote Login there: System Settings → General → Sharing → Remote Login."
            is SshShellException.HostKeyRejected -> "Not connected: $name's SSH key was not trusted."
            is SshShellException.HostKeyChanged ->
                "Not connected: $name's SSH key has changed. If it really did, forget the old key in Terminal settings."
            is SshShellException.AuthenticationFailed ->
                "$name refused the login as ${settings.username}. Check the user name, and add this phone's key on the Mac: touch and hold $name and choose Terminal settings."
            is SshShellException.Cancelled -> "Not connected: no password was given."
            is SshShellException.ShellRefused -> "$name accepted the login but would not start a shell."
            is SshShellException.Closed -> "The connection to $name closed: ${e.message}"
        }
    }

    // SshShell.Listener, on the reader thread

    override fun onOutput(bytes: ByteArray, length: Int) {
        terminal.receive(bytes, length)
    }

    override fun onExit(status: Int?) {
        exitStatus = status
    }

    override fun onClosed() = runOnUiThread {
        if (!connected || isFinishing) return@runOnUiThread
        connected = false
        val status = exitStatus
        showCard(
            when {
                status == null -> "The connection to ${peer.name} closed."
                status == 0 -> "The shell on ${peer.name} ended."
                else -> "The shell on ${peer.name} ended with status $status."
            },
            busy = false,
        )
    }

    // TerminalView.Host

    override fun send(bytes: ByteArray) {
        shell?.write(bytes)
    }

    override fun sizeChanged(columns: Int, rows: Int) {
        shell?.resize(columns, rows)
    }

    override fun titleChanged(title: String) {
        subtitleView.text = title.ifEmpty { "${settings.username} · terminal" }
    }

    override fun modifiersChanged() {
        ctrlKey.setTextColor(if (terminal.ctrlPending) Theme.ACCENT else Theme.TEXT)
        altKey.setTextColor(if (terminal.altPending) Theme.ACCENT else Theme.TEXT)
    }

    // Questions from the SSH library, asked on its thread and answered on the screen ----------------

    /**
     * The first time, the person decides from the fingerprint; after that the key is pinned, and a
     * different one is refused without a question, since that is what an interception looks like.
     */
    override fun promptYesNo(message: String): Boolean {
        val verdict = shellRepository?.lastVerdict
        val name = peer.name
        return when (verdict) {
            is HostKeyVerdict.New -> {
                val file = verdict.type.removePrefix("ssh-").replace("ecdsa-sha2-nistp256", "ecdsa")
                ask(
                    title = "Trust $name?",
                    message = "This is the first terminal on $name from this phone. Its SSH key is\n\n${verdict.type}\n${verdict.fingerprint}\n\nOn the Mac, ssh-keygen -lf /etc/ssh/ssh_host_${file}_key.pub shows the same if it is that Mac.",
                    yes = "Trust",
                )
            }
            // A changed key is refused by JSch without a question, and reported once every address
            // has been tried: at an old address it is usually just another Mac.
            else -> false
        }
    }

    /** The repository the live attempt is using, so the question can show the key it saw. */
    private var shellRepository: TerminalStore.PinnedHostKeys? = null

    override fun promptPassword(message: String): Boolean {
        val typed = askPassword() ?: return false
        password.set(typed)
        return true
    }

    override fun getPassword(): String? = password.get()

    override fun promptPassphrase(message: String): Boolean = false

    override fun getPassphrase(): String? = null

    override fun showMessage(message: String) {
        log(message)
    }

    /** macOS often asks for the password this way, through PAM, rather than as a plain password. */
    override fun promptKeyboardInteractive(destination: String, name: String, instruction: String, prompt: Array<String>, echo: BooleanArray): Array<String>? {
        if (prompt.isEmpty()) return emptyArray()
        val typed = password.get() ?: askPassword() ?: return null
        password.set(typed)
        return Array(prompt.size) { typed }
    }

    private fun askPassword(): String? {
        val answer = AtomicReference<String?>(null)
        val done = CountDownLatch(1)
        runOnUiThread {
            if (isFinishing) { done.countDown(); return@runOnUiThread }
            val field = EditText(this).apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                hint = "password"
                setTextColor(Theme.TEXT)
                setHintTextColor(Theme.TEXT_FAINT)
            }
            val holder = LinearLayout(this).apply {
                setPadding(dp(20), dp(8), dp(20), 0)
                addView(field, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            }
            AlertDialog.Builder(this)
                .setTitle("Password for ${settings.username}")
                .setMessage("${peer.name} did not take this phone's key. Type the account's password, or add the key there to skip this next time.")
                .setView(holder)
                .setPositiveButton("Log In") { _, _ -> answer.set(field.text.toString()); done.countDown() }
                .setNegativeButton("Cancel") { _, _ -> done.countDown() }
                .setOnCancelListener { done.countDown() }
                .show()
            field.requestFocus()
        }
        done.await()
        return answer.get()?.takeIf { it.isNotEmpty() }
    }

    /** A dialog with a yes and a no, or with only OK when [yes] is null. Blocks the calling thread. */
    private fun ask(title: String, message: String, yes: String?): Boolean {
        val answer = AtomicReference(false)
        val done = CountDownLatch(1)
        runOnUiThread {
            if (isFinishing) { done.countDown(); return@runOnUiThread }
            val builder = AlertDialog.Builder(this).setTitle(title).setMessage(message)
            if (yes != null) {
                builder.setPositiveButton(yes) { _, _ -> answer.set(true); done.countDown() }
                builder.setNegativeButton("Cancel") { _, _ -> done.countDown() }
            } else {
                builder.setPositiveButton("OK") { _, _ -> done.countDown() }
            }
            builder.setOnCancelListener { done.countDown() }.show()
        }
        done.await()
        return answer.get()
    }

    private fun log(line: String) {
        Log.i("OwnDesk", line)
    }

    // View helpers --------------------------------------------------------------------------------

    private fun label(text: String, size: Float, color: Int, mono: Boolean = false): TextView = TextView(this).apply {
        this.text = text
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        if (mono) typeface = Typeface.MONOSPACE
    }

    private fun button(text: String, tint: Int, action: () -> Unit): TextView = TextView(this).apply {
        this.text = text
        setTextColor(tint)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.UI_SECONDARY)
        gravity = Gravity.CENTER
        setPadding(dp(14), dp(8), dp(14), dp(8))
        background = GradientDrawable().apply {
            cornerRadius = dp(6).toFloat()
            setColor((tint and 0x00FFFFFF) or 0x14000000)
            setStroke(1, (tint and 0x00FFFFFF) or 0x59000000)
        }
        isClickable = true
        setOnClickListener { action() }
    }

    private fun divider(): View = View(this).apply {
        setBackgroundColor(Theme.BORDER)
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, 1)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"

        fun intent(context: Context, deviceId: String): Intent =
            Intent(context, TerminalActivity::class.java).putExtra(EXTRA_DEVICE_ID, deviceId)
    }
}
