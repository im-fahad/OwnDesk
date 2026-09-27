package io.github.im_fahad.owndesk.terminal

import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.Identity
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jcraft.jsch.UserInfo
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Why a terminal could not be opened, in terms the screen can turn into advice. */
sealed class SshShellException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** Nothing answered at that address and port. Remote Login may be off. */
    class Unreachable(cause: Throwable?) : SshShellException("unreachable", cause)

    /** The server's host key was not the one trusted for this Mac, or the person declined it. */
    class HostKeyRejected(cause: Throwable?) : SshShellException("host key rejected", cause)

    /** The server took neither this phone's key nor a password. */
    class AuthenticationFailed(cause: Throwable?) : SshShellException("authentication failed", cause)

    /** The person was asked for a password and chose not to give one. */
    class Cancelled(cause: Throwable?) : SshShellException("cancelled", cause)

    /** Logged in, but the server would not start a shell in a terminal. */
    class ShellRefused(cause: Throwable?) : SshShellException("shell refused", cause)

    class Closed(why: String, cause: Throwable?) : SshShellException(why, cause)
}

/**
 * One terminal on a Mac: an SSH connection, a pseudo-terminal, and a login shell in it.
 *
 * What is typed goes in with [write], what the shell prints comes out through the listener, and the
 * size of the terminal follows the screen with [resize]. The shell is the user's own, started by the
 * Mac's SSH server after it has authenticated this phone; nothing here runs anything on the Mac
 * itself, and OwnDesk's own protocol is not involved at all.
 */
class SshShell(private val listener: Listener) {
    interface Listener {
        /** Bytes the shell printed. Called on the reader thread. */
        fun onOutput(bytes: ByteArray, length: Int)

        /** The shell ended; its exit status when the server said. Always followed by [onClosed]. */
        fun onExit(status: Int?)

        /** The connection is gone. Always the last call. */
        fun onClosed()
    }

    private val lock = Any()
    private var session: Session? = null
    private var channel: ChannelShell? = null
    private var output: OutputStream? = null
    @Volatile private var closed = false
    /**
     * Everything sent to the Mac goes through this one thread, in order. A key press arrives on the
     * main thread, and Android refuses to let that thread touch the network.
     */
    private val writer = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "owndesk-terminal-write") }

    /**
     * Connects, authenticates, and starts a login shell in a pseudo-terminal. Returns once the shell
     * is running; throws [SshShellException] saying why when it cannot get that far. Blocks, so
     * call it off the main thread.
     *
     * Authentication offers this phone's key first. Only if the server refuses it is [userInfo]
     * asked for the account's password.
     */
    fun connect(
        host: String, port: Int, username: String, key: Identity,
        hostKeys: HostKeyRepository, userInfo: UserInfo,
        columns: Int, rows: Int, term: String = "xterm-256color", timeoutMs: Int = 10_000,
    ) {
        val jsch = JSch()
        jsch.hostKeyRepository = hostKeys
        jsch.addIdentity(key, null)
        val session = jsch.getSession(username, host, port)
        session.setConfig("StrictHostKeyChecking", "ask")
        session.setConfig("PreferredAuthentications", "publickey,password,keyboard-interactive")
        session.userInfo = userInfo
        session.serverAliveInterval = 15_000
        session.serverAliveCountMax = 3
        try {
            session.connect(timeoutMs)
        } catch (e: JSchException) {
            throw classify(e, hostKeys)
        }
        val shell: ChannelShell
        try {
            shell = session.openChannel("shell") as ChannelShell
            shell.setPtyType(term, columns.coerceAtLeast(1), rows.coerceAtLeast(1), 0, 0)
            shell.setPty(true)
            val input = shell.inputStream
            val out = shell.outputStream
            shell.connect(timeoutMs)
            synchronized(lock) {
                this.session = session
                this.channel = shell
                this.output = out
            }
            Thread({ pump(input, shell) }, "owndesk-terminal-read").start()
        } catch (e: Exception) {
            session.disconnect()
            throw SshShellException.ShellRefused(e)
        }
    }

    /** Sends what was typed. Silently dropped before the shell is running or after it has ended. */
    fun write(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val copy = bytes.copyOf()
        later {
            val out = synchronized(lock) { output } ?: return@later
            try {
                out.write(copy)
                out.flush()
            } catch (e: Exception) {
                android.util.Log.w("OwnDesk", "terminal write failed: $e")
                close()
            }
        }
    }

    /** Tells the shell the terminal is now this many characters wide and rows tall. */
    fun resize(columns: Int, rows: Int) {
        if (columns <= 0 || rows <= 0) return
        later {
            val shell = synchronized(lock) { channel } ?: return@later
            try {
                shell.setPtySize(columns, rows, 0, 0)
            } catch (e: Exception) {
                // The channel is going away; the close that follows says so.
            }
        }
    }

    /** Ends the connection. Safe from any thread, and more than once. */
    fun close() {
        later {
            val (shell, live) = synchronized(lock) { channel to session }
            try { shell?.disconnect() } catch (e: Exception) {}
            try { live?.disconnect() } catch (e: Exception) {}
            finish(null)
            writer.shutdown()
        }
    }

    private fun later(action: () -> Unit) {
        try {
            writer.execute(action)
        } catch (e: RejectedExecutionException) {
            // Already closed: there is nothing left to send to.
        }
    }

    private fun pump(input: InputStream, shell: ChannelShell) {
        val buffer = ByteArray(16 * 1024)
        try {
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) listener.onOutput(buffer, read)
            }
        } catch (e: Exception) {
            // Read failures end the shell like an EOF does; say why in the log, since the screen cannot.
            android.util.Log.w("OwnDesk", "terminal read ended: $e", e)
        }
        val status = shell.exitStatus.takeIf { it >= 0 }
        try { shell.disconnect() } catch (e: Exception) {}
        synchronized(lock) { session }?.let { try { it.disconnect() } catch (e: Exception) {} }
        finish(status)
    }

    private fun finish(status: Int?) {
        val first = synchronized(lock) {
            val was = closed
            closed = true
            !was
        }
        if (!first) return
        listener.onExit(status)
        listener.onClosed()
    }

    /** JSch says why with a message; this turns the usual ones into something the screen can explain. */
    private fun classify(e: JSchException, hostKeys: HostKeyRepository): SshShellException {
        val text = e.message.orEmpty()
        val verdict = (hostKeys as? TerminalStore.PinnedHostKeys)?.lastVerdict
        return when {
            verdict is HostKeyVerdict.Changed || text.contains("HostKey has been changed") ||
                text.contains("reject HostKey") -> SshShellException.HostKeyRejected(e)
            text.contains("Auth cancel") -> SshShellException.Cancelled(e)
            text.contains("Auth fail") -> SshShellException.AuthenticationFailed(e)
            e.cause is java.net.ConnectException || e.cause is java.net.SocketTimeoutException ||
                e.cause is java.net.NoRouteToHostException || e.cause is java.net.UnknownHostException ||
                text.contains("timeout") || text.contains("Connection refused") -> SshShellException.Unreachable(e)
            else -> SshShellException.Closed(text.ifEmpty { e.toString() }, e)
        }
    }
}
