package com.prc.controller.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.prc.controller.BuildConfig
import com.prc.controller.device.KeystoreIdentity
import com.prc.controller.device.PeerStore
import com.prc.controller.protocol.AndroidKeyCodes
import com.prc.controller.protocol.DataChannel
import com.prc.controller.protocol.DisplayInfo
import com.prc.controller.session.RemoteSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack
import kotlin.math.abs

/**
 * The Mac's screen, and the finger on it.
 *
 * Touches are absolute, not trackpad-relative: on a phone the whole desktop is visible at once, so
 * putting the pointer where the finger lands is both quicker and easier to aim than dragging a
 * pointer around from wherever it was left.
 */
class SessionActivity : AppCompatActivity(), RemoteSession.Listener {

    private lateinit var renderer: SurfaceViewRenderer
    private lateinit var status: TextView
    private lateinit var keyboardCatcher: EditText
    private val eglBase: EglBase by lazy { EglBase.create() }
    private val handler = Handler(Looper.getMainLooper())

    private var session: RemoteSession? = null
    private var display: DisplayInfo? = null
    private var frameWidth = 0
    private var frameHeight = 0
    private var clearing = false
    private var lastMoveSent = 0L
    private var downAt = 0L
    private var downX = 0f
    private var downY = 0f
    private var moved = false
    private var rightClickFired = false
    private var scrolling = false
    private var lastScrollY = 0f
    private var lastScrollX = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(buildLayout())
        hideSystemBars()

        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
        val peer = deviceId?.let { PeerStore(this).peer(it) }
        if (peer == null) {
            Toast.makeText(this, "That Mac is not paired any more", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        val identity = KeystoreIdentity.load()
        val peers = PeerStore(this)
        val remote = RemoteSession(
            context = this,
            identity = identity,
            peer = peer,
            resolveKey = { id -> peers.publicKey(id) },
            eglBase = eglBase,
            appVersion = BuildConfig.VERSION_NAME,
            listener = this,
        )
        session = remote

        status.text = "connecting to ${peer.name}"
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { remote.start() }
            } catch (e: Exception) {
                onEnded(e.message ?: "could not connect")
            }
        }
    }

    private fun buildLayout(): View {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        renderer = SurfaceViewRenderer(this).apply {
            init(eglBase.eglBaseContext, object : RendererCommon.RendererEvents {
                override fun onFirstFrameRendered() = onLog("first frame")
                override fun onFrameResolutionChanged(width: Int, height: Int, rotation: Int) {
                    frameWidth = width
                    frameHeight = height
                    onLog("frame $width x $height")
                }
            })
            // The hardware scaler sizes the surface to the frame and lets the compositor stretch it
            // to the view, which fills the screen but distorts a desktop and puts the pointer where
            // the finger is not. Drawing at view size keeps the aspect ratio and the black bars the
            // touch mapping assumes.
            setEnableHardwareScaler(false)
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        }
        // Sized to the frame's own shape rather than the whole screen. Told to match the parent it
        // stretches a 16:9 desktop across a 20:9 phone, and then the pointer lands where the finger
        // is not. Measuring itself leaves black on either side, which is what the mapping expects.
        root.addView(renderer, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER,
        ))

        status = TextView(this).apply {
            setTextColor(0xFFCCCCCC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setBackgroundColor(0xAA000000.toInt())
            setPadding(24, 16, 24, 16)
        }
        root.addView(status, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START,
        ))

        // Two controls, kept out of the way at the bottom right.
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(overlayButton("Keys") { toggleKeyboard() })
            addView(overlayButton("End") { finish() })
        }
        root.addView(buttons, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END,
        ).apply { setMargins(0, 0, 24, 24) })

        // Off-screen, so the soft keyboard has somewhere to type into. What it types is forwarded
        // as text, which is the only way a phone keyboard can produce characters faithfully.
        keyboardCatcher = EditText(this).apply {
            alpha = 0f
            // In landscape a keyboard normally takes the whole screen and edits in its own field,
            // which would hide the very thing being typed into. These flags keep it a keyboard.
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            // No autocorrect and no auto-capitals: this is a remote keyboard, so what the finger
            // presses is what the Mac should receive.
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}

                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    // Clearing the field on every keystroke desynchronises the keyboard, which then
                    // sends only the first character. Instead the field accumulates and the delta
                    // is forwarded: characters as text, removals as backspaces.
                    if (clearing || s == null) return
                    when {
                        count > before -> {
                            val typed = s.subSequence(start + before, start + count).toString()
                            if (typed.isNotEmpty()) session?.send(DataChannel.text(typed, now()))
                        }
                        before > count -> repeat(before - count) { sendBackspace() }
                    }
                }

                override fun afterTextChanged(s: Editable?) {
                    // Emptied once it grows, so the field never becomes a visible transcript.
                    if (!clearing && (s?.length ?: 0) > 96) {
                        clearing = true
                        keyboardCatcher.setText("")
                        clearing = false
                    }
                }
            })
            setOnKeyListener { _, keyCode, event ->
                val code = AndroidKeyCodes.code(keyCode) ?: return@setOnKeyListener false
                // Backspace on an empty field produces a key event rather than a text change, which
                // is the only way the Mac hears about it.
                if (keyCode == KeyEvent.KEYCODE_DEL && text.isNotEmpty()) return@setOnKeyListener false
                val modifiers = AndroidKeyCodes.modifiers(event)
                when (event.action) {
                    KeyEvent.ACTION_DOWN -> session?.send(DataChannel.keyDown(code, modifiers, now()))
                    KeyEvent.ACTION_UP -> session?.send(DataChannel.keyUp(code, modifiers, now()))
                }
                true
            }
        }
        root.addView(keyboardCatcher, FrameLayout.LayoutParams(1, 1))

        renderer.setOnTouchListener { _, event -> onVideoTouch(event); true }
        return root
    }

    private fun overlayButton(text: String, action: () -> Unit): TextView = TextView(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        setBackgroundColor(0xCC4D8EF7.toInt())
        setPadding(36, 20, 36, 20)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setOnClickListener { action() }
        (layoutParams as? LinearLayout.LayoutParams)?.rightMargin = 16
    }

    // Input ------------------------------------------------------------------------------------

    @SuppressLint("ClickableViewAccessibility")
    private fun onVideoTouch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downAt = now()
                downX = event.x
                downY = event.y
                moved = false
                rightClickFired = false
                scrolling = false
                sendMove(event.x, event.y, force = true)
                handler.postDelayed(longPress, LONG_PRESS_MS)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                // A second finger turns the gesture into scrolling, so cancel the pending click.
                handler.removeCallbacks(longPress)
                scrolling = true
                lastScrollX = event.getX(0)
                lastScrollY = event.getY(0)
            }

            MotionEvent.ACTION_MOVE -> {
                if (scrolling && event.pointerCount >= 2) {
                    val dx = event.getX(0) - lastScrollX
                    val dy = event.getY(0) - lastScrollY
                    if (abs(dx) > 0.5f || abs(dy) > 0.5f) {
                        lastScrollX = event.getX(0)
                        lastScrollY = event.getY(0)
                        session?.send(DataChannel.scroll(dx.toDouble(), dy.toDouble(), now()))
                    }
                } else {
                    if (abs(event.x - downX) > TOUCH_SLOP || abs(event.y - downY) > TOUCH_SLOP) {
                        moved = true
                        handler.removeCallbacks(longPress)
                    }
                    sendMove(event.x, event.y, force = false)
                }
            }

            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(longPress)
                val quick = now() - downAt < LONG_PRESS_MS
                if (!scrolling && !moved && !rightClickFired && quick) {
                    session?.send(DataChannel.mouseDown("left", now()))
                    session?.send(DataChannel.mouseUp("left", now()))
                }
                scrolling = false
            }

            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPress)
                scrolling = false
            }
        }
    }

    /** Holding still is a right click, the same shape as a long press everywhere else on a phone. */
    private val longPress = Runnable {
        if (!moved && !scrolling) {
            rightClickFired = true
            session?.send(DataChannel.mouseDown("right", now()))
            session?.send(DataChannel.mouseUp("right", now()))
        }
    }

    /**
     * Where the finger is, as a fraction of the Mac's screen. The video is letterboxed to keep its
     * aspect ratio, so the black bars have to come out of the sum before it means anything.
     */
    private fun sendMove(x: Float, y: Float, force: Boolean) {
        val info = display ?: return
        val moment = now()
        if (!force && moment - lastMoveSent < DataChannel.MOVE_COALESCE_MS) return
        lastMoveSent = moment

        val viewWidth = renderer.width.toFloat()
        val viewHeight = renderer.height.toFloat()
        if (viewWidth <= 0f || viewHeight <= 0f) return
        val videoAspect = if (frameWidth > 0 && frameHeight > 0) {
            frameWidth.toFloat() / frameHeight.toFloat()
        } else {
            info.width_px.toFloat() / info.height_px.toFloat()
        }
        val viewAspect = viewWidth / viewHeight
        val (contentWidth, contentHeight) = if (viewAspect > videoAspect) {
            viewHeight * videoAspect to viewHeight
        } else {
            viewWidth to viewWidth / videoAspect
        }
        val left = (viewWidth - contentWidth) / 2f
        val top = (viewHeight - contentHeight) / 2f
        val nx = ((x - left) / contentWidth).coerceIn(0f, 1f)
        val ny = ((y - top) / contentHeight).coerceIn(0f, 1f)
        session?.send(DataChannel.mouseMove(info.display_id, nx.toDouble(), ny.toDouble(), moment))
    }

    private fun sendBackspace() {
        session?.send(DataChannel.keyDown("Backspace", emptyList(), now()))
        session?.send(DataChannel.keyUp("Backspace", emptyList(), now()))
    }

    private fun toggleKeyboard() {
        val manager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        keyboardCatcher.requestFocus()
        manager.toggleSoftInput(InputMethodManager.SHOW_FORCED, 0)
    }

    // Session callbacks ------------------------------------------------------------------------

    override fun onLog(line: String) {
        Log.i("PRC", line)
        runOnUiThread { status.text = line }
    }

    override fun onVideo(track: VideoTrack) {
        runOnUiThread {
            track.addSink(renderer)
            status.visibility = View.GONE
        }
    }

    override fun onReady(display: DisplayInfo, path: String) {
        this.display = display
        runOnUiThread { status.text = "${display.width_px}x${display.height_px}  ·  $path" }
    }

    override fun onEnded(reason: String) {
        runOnUiThread {
            if (isFinishing) return@runOnUiThread
            Toast.makeText(this, reason, Toast.LENGTH_LONG).show()
            finish()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        session?.end()
        session = null
        runCatching { renderer.release() }
        runCatching { eglBase.release() }
        super.onDestroy()
    }

    private fun hideSystemBars() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
    }

    private fun now(): Long = System.currentTimeMillis()

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"
        private const val LONG_PRESS_MS = 550L
        private const val TOUCH_SLOP = 12f

        fun intent(context: Context, deviceId: String): Intent =
            Intent(context, SessionActivity::class.java).putExtra(EXTRA_DEVICE_ID, deviceId)
    }
}
