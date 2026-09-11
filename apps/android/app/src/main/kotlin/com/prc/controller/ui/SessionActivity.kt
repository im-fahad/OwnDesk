package com.prc.controller.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
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
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.TooltipCompat
import androidx.lifecycle.lifecycleScope
import com.prc.controller.BuildConfig
import com.prc.controller.R
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
    private var scale = 1f
    private var panX = 0f
    private var panY = 0f
    private lateinit var root: FrameLayout
    private lateinit var holdMark: View
    private lateinit var modeButton: ImageView
    private lateinit var infoButton: ImageView
    private lateinit var infoPanel: LinearLayout
    private lateinit var captureBanner: TextView
    private var infoTicker: Runnable? = null
    private var peerName = "this Mac"
    private val gestures: Gestures by lazy {
        Gestures(GestureOutput(), object : Gestures.Scheduler {
            override fun after(delayMs: Long, action: () -> Unit): Any {
                val runnable = Runnable { action() }
                handler.postDelayed(runnable, delayMs)
                return runnable
            }

            override fun cancel(token: Any) {
                handler.removeCallbacks(token as Runnable)
            }
        })
    }
    private lateinit var scaleDetector: ScaleGestureDetector
    private var lastMoveSent = 0L

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

        peerName = peer.name
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
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

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

        // A banner rather than a curtain: while the Mac's capture is paused the last frame stays on
        // screen and input still reaches it, so the picture is left visible and touchable underneath
        // and only the explanation is added.
        captureBanner = TextView(this).apply {
            visibility = View.GONE
            setTextColor(Theme.TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.UI_SECONDARY)
            setBackgroundColor(0xE61B1B1B.toInt())
            setPadding(dp(14), dp(8), dp(14), dp(8))
        }
        root.addView(captureBanner, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL,
        ).apply { topMargin = dp(12) })   // This screen hides the system bars, so no inset to clear.

        // A sidebar rather than labelled buttons: it sits on the black bar beside a 16:9 picture,
        // so it costs no part of the Mac's screen. The names live in tooltips, on a long press,
        // which is where Android puts them for icon-only controls.
        infoPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            setBackgroundColor(0xE61B1B1B.toInt())
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }

        val icons = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xE61B1B1B.toInt())
            setPadding(dp(4), dp(6), dp(4), dp(6))
        }
        modeButton = iconButton(R.drawable.ic_touch, "Touch") {
            setMode(if (gestures.mode == Gestures.Mode.TOUCH) Gestures.Mode.TRACKPAD else Gestures.Mode.TOUCH)
        }
        icons.addView(modeButton)
        icons.addView(iconButton(R.drawable.ic_keys, "Keyboard") { toggleKeyboard() })
        infoButton = iconButton(R.drawable.ic_info, "Session info") { toggleInfo() }
        icons.addView(infoButton)
        icons.addView(iconButton(R.drawable.ic_end, "End session") { confirmEnd() })

        // Anchored separately, so opening the panel does not move the icons. Sharing one row meant
        // the row grew taller and its vertical centring slid the icons up the screen, which moved
        // the button under the thumb that had just pressed it.
        root.addView(icons, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.END or Gravity.CENTER_VERTICAL,
        ))
        root.addView(infoPanel, FrameLayout.LayoutParams(
            dp(210), ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.END or Gravity.CENTER_VERTICAL,
        ).apply { rightMargin = dp(54) })

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

        scaleDetector = ScaleGestureDetector(this, ZoomListener())
        val saved = getSharedPreferences("prc", Context.MODE_PRIVATE).getString("input_mode", null)
        setMode(if (saved == Gestures.Mode.TRACKPAD.name) Gestures.Mode.TRACKPAD else Gestures.Mode.TOUCH)
        // The listener sits on the parent, not the video, because pinching moves and scales the
        // video and a listener on it would be reading coordinates from a shifting frame.
        root.setOnTouchListener { _, event -> onTouch(event); true }
        return root
    }

    private fun iconButton(icon: Int, name: String, action: () -> Unit): ImageView = ImageView(this).apply {
        setImageResource(icon)
        imageTintList = android.content.res.ColorStateList.valueOf(Theme.TEXT_DIM)
        setPadding(dp(11), dp(11), dp(11), dp(11))
        isClickable = true
        contentDescription = name
        // Held down, an icon says what it is. That is where Android shows the name of a control
        // that has no label, so it is where people already look.
        TooltipCompat.setTooltipText(this, name)
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(dp(46), dp(46))
    }

    private fun tint(view: ImageView, on: Boolean) {
        view.imageTintList = android.content.res.ColorStateList.valueOf(
            if (on) Theme.ACCENT else Theme.TEXT_DIM
        )
    }

    // Input ------------------------------------------------------------------------------------

    @SuppressLint("ClickableViewAccessibility")
    private fun onTouch(event: MotionEvent) {
        scaleDetector.onTouchEvent(event)
        gestures.pinching = scaleDetector.isInProgress
        gestures.magnified = scale > 1.01f

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> gestures.down(event.x, event.y, event.eventTime)
            MotionEvent.ACTION_POINTER_DOWN ->
                gestures.pointerDown(event.pointerCount, focusX(event), focusY(event), event.eventTime)
            MotionEvent.ACTION_MOVE ->
                gestures.move(event.pointerCount, event.x, event.y, focusX(event), focusY(event))
            MotionEvent.ACTION_UP -> gestures.up(event.x, event.y, event.eventTime)
            MotionEvent.ACTION_CANCEL -> gestures.cancel()
        }
    }

    private fun focusX(event: MotionEvent): Float =
        if (event.pointerCount >= 2) (event.getX(0) + event.getX(1)) / 2f else event.x

    private fun focusY(event: MotionEvent): Float =
        if (event.pointerCount >= 2) (event.getY(0) + event.getY(1)) / 2f else event.y

    /** What each gesture does to the Mac, or to the picture of it. */
    private inner class GestureOutput : Gestures.Output {
        /** Debug builds narrate their gestures, since multi-touch cannot be replayed from a computer. */
        private fun trace(what: String) {
            if (BuildConfig.DEBUG) Log.i("PRC", "gesture $what")
        }

        override fun moveTo(x: Float, y: Float) = sendMove(x, y, force = false)

        override fun moveBy(dx: Float, dy: Float) {
            // View pixels are not the Mac's pixels: the picture is scaled onto the phone and may be
            // magnified on top of that. A little acceleration makes it feel like a trackpad rather
            // than a slow crawl.
            val perPixel = remotePixelsPerViewPixel()
            session?.send(
                DataChannel.mouseMoveRel(
                    (dx * perPixel * TRACKPAD_SPEED).toDouble(),
                    (dy * perPixel * TRACKPAD_SPEED).toDouble(),
                    now(),
                )
            )
        }

        override fun click(button: String) {
            trace("click $button")
            session?.send(DataChannel.mouseDown(button, now()))
            session?.send(DataChannel.mouseUp(button, now()))
        }

        override fun buttonDown(button: String) {
            trace("down $button")
            session?.send(DataChannel.mouseDown(button, now()))
        }

        override fun buttonUp(button: String) {
            trace("up $button")
            session?.send(DataChannel.mouseUp(button, now()))
        }

        override fun scroll(dx: Float, dy: Float) {
            session?.send(DataChannel.scroll(dx.toDouble(), dy.toDouble(), now()))
        }

        override fun pan(dx: Float, dy: Float) {
            panX += dx
            panY += dy
            clampPan()
            applyTransform()
        }

        override fun holding(x: Float, y: Float, held: Boolean) {
            trace("holding $held")
            holdMark.visibility = if (held) View.VISIBLE else View.GONE
            if (held) {
                holdMark.translationX = x - dp(28)
                holdMark.translationY = y - dp(28)
            }
        }
    }

    private fun remotePixelsPerViewPixel(): Float {
        val width = renderer.width.toFloat()
        if (width <= 0f) return 1f
        val remoteWidth = if (frameWidth > 0) frameWidth.toFloat() else display?.width_px?.toFloat() ?: width
        return remoteWidth / (width * scale)
    }

    /**
     * Everything worth knowing about the session, in the sidebar: which Mac, over which address and
     * route, and what the stream is actually doing. Guesswork about a stuttering picture is what
     * this replaces, so the numbers come from the peer connection rather than from hope.
     */
    /** Ending drops the session, so a tap next to the info button should not do it silently. */
    private fun confirmEnd() {
        AlertDialog.Builder(this)
            .setTitle("End the session?")
            .setMessage("The screen closes and $peerName goes back to being on its own.")
            .setPositiveButton("End") { _, _ -> finish() }
            .setNegativeButton("Stay", null)
            .show()
    }

    private fun toggleInfo() {
        val showing = infoPanel.visibility == View.VISIBLE
        infoPanel.visibility = if (showing) View.GONE else View.VISIBLE
        tint(infoButton, !showing)
        infoTicker?.let(handler::removeCallbacks)
        if (showing) {
            infoTicker = null
            return
        }
        val tick = object : Runnable {
            override fun run() {
                refreshInfo()
                handler.postDelayed(this, 1000)
            }
        }
        infoTicker = tick
        handler.post(tick)
    }

    private fun refreshInfo() {
        val remote = session ?: return
        remote.stats { stats ->
            if (BuildConfig.DEBUG) {
                Log.i("PRC", "stats ${stats.width}x${stats.height} ${stats.fps}fps ${stats.kbps}kbps codec=${stats.codec}")
            }
            runOnUiThread {
                if (infoPanel.visibility != View.VISIBLE) return@runOnUiThread
                infoPanel.removeAllViews()
                infoPanel.addView(infoHeading("SESSION"))
                infoRow("Mac", peerName)
                infoRow("Address", remote.address ?: "unknown")
                infoRow("Route", remote.path ?: "unknown")
                remote.display?.let { infoRow("Its screen", "${it.width_px} x ${it.height_px}") }

                infoPanel.addView(infoHeading("STREAM"))
                infoRow("Now", if (stats.width > 0) "${stats.width} x ${stats.height}" else "waiting")
                infoRow("Frames", String.format("%.0f a second", stats.fps))
                infoRow("Bitrate", "${stats.kbps} kbps")
                infoRow("Codec", stats.codec ?: "H264")
                infoRow("Lost", "${stats.packetsLost} packets")
                infoRow("Jitter", String.format("%.0f ms", stats.jitterMs))
                if (stats.roundTripMs > 0) infoRow("Round trip", String.format("%.0f ms", stats.roundTripMs))

                infoPanel.addView(infoHeading("THIS PHONE"))
                infoRow("Input", if (gestures.mode == Gestures.Mode.TOUCH) "Touch" else "Trackpad")
                infoRow("Zoom", if (scale <= 1f) "fit" else String.format("%.1fx", scale))
            }
        }
    }

    private fun infoHeading(title: String) = TextView(this).apply {
        text = title
        setTextColor(Theme.TEXT_FAINT)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 9f)
        letterSpacing = 0.1f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, dp(10), 0, dp(4))
    }

    private fun infoRow(name: String, value: String) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(TextView(this).apply {
            text = name
            setTextColor(Theme.TEXT_FAINT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        // The value takes the rest and sits against the right edge, so the two columns read as a
        // table rather than as a label with a hole beside it.
        row.addView(TextView(this).apply {
            text = value
            setTextColor(Theme.TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            typeface = android.graphics.Typeface.MONOSPACE
            gravity = Gravity.END
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            leftMargin = dp(8)
        })
        infoPanel.addView(row, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(2) })
    }

    private fun setMode(next: Gestures.Mode) {
        gestures.mode = next
        modeButton.setImageResource(if (next == Gestures.Mode.TOUCH) R.drawable.ic_touch else R.drawable.ic_touchpad)
        TooltipCompat.setTooltipText(modeButton, if (next == Gestures.Mode.TOUCH) "Touch" else "Trackpad")
        tint(modeButton, next == Gestures.Mode.TRACKPAD)
        getSharedPreferences("prc", Context.MODE_PRIVATE).edit().putString("input_mode", next.name).apply()
        status.visibility = View.VISIBLE
        status.text = if (next == Gestures.Mode.TOUCH) {
            "Touch: the pointer goes where you tap"
        } else {
            "Trackpad: drag to move the pointer, tap to click"
        }
        handler.removeCallbacks(hideStatus)
        handler.postDelayed(hideStatus, 2200)
    }

    /**
     * Pinching magnifies the picture on the phone rather than asking the Mac to change anything.
     * A desktop shrunk onto a phone has text a few pixels tall, and this is the difference between
     * seeing a menu and guessing at it. The point under the fingers stays under the fingers.
     */
    private inner class ZoomListener : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val previous = scale
            scale = (scale * detector.scaleFactor).coerceIn(1f, MAX_ZOOM)
            if (scale == previous) return true

            val centreX = renderer.left + renderer.width / 2f
            val centreY = renderer.top + renderer.height / 2f
            panX = PointerMapping.panAfterZoom(detector.focusX, centreX, panX, previous, scale)
            panY = PointerMapping.panAfterZoom(detector.focusY, centreY, panY, previous, scale)
            if (scale < 1.02f) {
                scale = 1f
                panX = 0f
                panY = 0f
            }
            clampPan()
            applyTransform()
            showZoom()
            return true
        }
    }

    private fun applyTransform() {
        renderer.scaleX = scale
        renderer.scaleY = scale
        renderer.translationX = panX
        renderer.translationY = panY
    }

    /** Keeps the magnified picture covering the frame, so no black creeps in at an edge. */
    private fun clampPan() {
        panX = PointerMapping.clampPan(panX, renderer.width.toFloat(), scale)
        panY = PointerMapping.clampPan(panY, renderer.height.toFloat(), scale)
    }

    private fun showZoom() {
        status.visibility = View.VISIBLE
        status.text = if (scale <= 1f) "1x" else String.format("%.1fx", scale)
        handler.removeCallbacks(hideStatus)
        handler.postDelayed(hideStatus, 900)
    }

    private val hideStatus = Runnable { status.visibility = View.GONE }

    /**
     * Where the finger is, as a fraction of the Mac's screen. The video is letterboxed to keep its
     * aspect ratio, so the black bars have to come out of the sum before it means anything.
     */
    private fun sendMove(x: Float, y: Float, force: Boolean) {
        val info = display ?: return
        val moment = now()
        if (!force && moment - lastMoveSent < DataChannel.MOVE_COALESCE_MS) return
        lastMoveSent = moment
        if (renderer.width <= 0 || renderer.height <= 0) return

        val aspect = if (frameWidth > 0 && frameHeight > 0) {
            frameWidth.toFloat() / frameHeight.toFloat()
        } else {
            info.width_px.toFloat() / info.height_px.toFloat()
        }
        val (nx, ny) = PointerMapping.normalized(
            x = x, y = y,
            viewLeft = renderer.left.toFloat(), viewTop = renderer.top.toFloat(),
            viewWidth = renderer.width.toFloat(), viewHeight = renderer.height.toFloat(),
            scale = scale, panX = panX, panY = panY, frameAspect = aspect,
        )
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

    override fun onReady(display: DisplayInfo, path: String, address: String) {
        this.display = display
        // Worth remembering: next time this address is tried first.
        intent.getStringExtra(EXTRA_DEVICE_ID)?.let { PeerStore(this).setLastGood(it, address) }
        runOnUiThread { status.text = "${display.width_px}x${display.height_px}  ·  $path" }
    }

    /** A restarted capture can be a different size, and every touch is mapped through this. */
    override fun onDisplayChanged(display: DisplayInfo) {
        this.display = display
        runOnUiThread { status.text = "${display.width_px}x${display.height_px}" }
    }

    override fun onCapture(state: String, detail: String?) = runOnUiThread {
        val text = describeCapture(state, detail)
        // The Mac sends its state when the channel opens too, and nothing had paused then.
        val wasPaused = captureBanner.visibility == View.VISIBLE
        if (text == null) {
            captureBanner.visibility = View.GONE
        } else {
            captureBanner.text = text
            captureBanner.visibility = View.VISIBLE
        }
        onLog(text ?: if (wasPaused) "screen capture resumed" else "screen capture active")
    }

    /** Null when the Mac is capturing normally, which is when the banner should not be there. */
    private fun describeCapture(state: String, detail: String?): String? = when (state) {
        "active" -> null
        "paused_locked" -> "The Mac is locked. Its screen is frozen until it is unlocked."
        "paused_display_asleep" -> "The Mac's display is asleep. Its screen is frozen."
        else -> "The Mac stopped capturing its screen${detail?.let { " ($it)" } ?: ""}. Retrying."
    }

    override fun onEnded(reason: String) {
        runOnUiThread {
            if (isFinishing) return@runOnUiThread
            Toast.makeText(this, reason, Toast.LENGTH_LONG).show()
            finish()
        }
    }

    override fun onDestroy() {
        infoTicker?.let(handler::removeCallbacks)
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun now(): Long = System.currentTimeMillis()

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"
        private const val TRACKPAD_SPEED = 1.5f
        private const val MAX_ZOOM = 4f

        fun intent(context: Context, deviceId: String): Intent =
            Intent(context, SessionActivity::class.java).putExtra(EXTRA_DEVICE_ID, deviceId)
    }
}
