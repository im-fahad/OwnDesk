package io.github.im_fahad.owndesk.terminal

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.util.TypedValue
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The terminal on screen: draws the emulator's grid and turns touches and keys into bytes for the
 * shell.
 *
 * It asks the keyboard for raw keys rather than text, the way a terminal must: autocorrect and
 * word suggestions have no place in a shell, and a key like Return has to arrive as one. A finger
 * scrolls back through what went by, two fingers change the text size, and a tap brings the
 * keyboard up.
 */
class TerminalView(context: Context) : View(context), TerminalEmulator.Listener {
    interface Host {
        /** Bytes for the shell: what was typed, or an answer the emulator owes it. */
        fun send(bytes: ByteArray)

        /** The grid is now this size; the shell's pseudo-terminal should follow. */
        fun sizeChanged(columns: Int, rows: Int)

        fun titleChanged(title: String)

        /** A modifier from the key bar was used up, so the bar can show it released. */
        fun modifiersChanged()
    }

    var host: Host? = null
    var emulator: TerminalEmulator? = null
        private set

    /** Control applies to the next key. */
    var ctrlPending = false
        set(value) { field = value; host?.modifiersChanged() }

    /** Alt (Escape before the key) applies to the next key. */
    var altPending = false
        set(value) { field = value; host?.modifiersChanged() }

    private val text = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply { typeface = Typeface.MONOSPACE }
    private val boldText = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply { typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD) }
    private val fill = Paint()
    private var fontSizeSp = context.getSharedPreferences("terminal", Context.MODE_PRIVATE).getFloat("fontSp", 12f)
    private var cellWidth = 1f
    private var cellHeight = 1f
    private var baseline = 0f
    private var columns = 0
    private var rows = 0
    /** Lines scrolled back from the bottom; 0 shows the live screen. */
    private var scrollOffset = 0
    private var scrollRemainder = 0f
    private val palette = IntArray(256)
    private val glyph = CharArray(2)

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            showKeyboard()
            return true
        }

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            val em = emulator ?: return false
            if (em.altActive) return false
            scrollRemainder += distanceY
            val lines = (scrollRemainder / cellHeight).toInt()
            if (lines != 0) {
                scrollRemainder -= lines * cellHeight
                scrollOffset = (scrollOffset - lines).coerceIn(0, em.scrollback.size)
                invalidate()
            }
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            onLongPress?.invoke()
        }
    })

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        private var startSize = 0f
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            startSize = fontSizeSp
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            setFontSize(startSize * detector.scaleFactor)
            return false
        }
    })

    /** Long press, for a paste menu the screen decides on. */
    var onLongPress: (() -> Unit)? = null

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setBackgroundColor(BACKGROUND)
        buildPalette()
        applyFont()
    }

    // Size

    private fun applyFont() {
        val px = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, fontSizeSp, resources.displayMetrics)
        text.textSize = px
        boldText.textSize = px
        cellWidth = text.measureText("M")
        val metrics = text.fontMetrics
        cellHeight = (metrics.descent - metrics.ascent + metrics.leading).coerceAtLeast(1f)
        baseline = -metrics.ascent
        fit()
    }

    private fun setFontSize(sp: Float) {
        val clamped = sp.coerceIn(7f, 28f)
        if (abs(clamped - fontSizeSp) < 0.25f) return
        fontSizeSp = clamped
        context.getSharedPreferences("terminal", Context.MODE_PRIVATE).edit().putFloat("fontSp", clamped).apply()
        applyFont()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        fit()
    }

    /** Makes the grid as large as the view allows, and tells the emulator and the shell. */
    private fun fit() {
        val usableWidth = width - paddingLeft - paddingRight
        val usableHeight = height - paddingTop - paddingBottom
        if (usableWidth <= 0 || usableHeight <= 0) return
        val c = (usableWidth / cellWidth).toInt().coerceAtLeast(2)
        val r = (usableHeight / cellHeight).toInt().coerceAtLeast(2)
        if (c == columns && r == rows) return
        columns = c
        rows = r
        val em = emulator
        if (em == null) {
            emulator = TerminalEmulator(c, r, listener = this)
        } else {
            synchronized(em) { em.resize(c, r) }
        }
        scrollOffset = 0
        host?.sizeChanged(c, r)
        invalidate()
    }

    val gridColumns: Int get() = columns
    val gridRows: Int get() = rows

    // Output

    /** What the shell printed. Safe from any thread. */
    fun receive(bytes: ByteArray, length: Int) {
        val em = emulator ?: return
        synchronized(em) { em.write(bytes, length) }
        postInvalidateOnAnimation()
    }

    override fun respond(bytes: ByteArray) {
        host?.send(bytes)
    }

    override fun titleChanged(title: String) {
        post { host?.titleChanged(title) }
    }

    override fun bell() {}

    override fun clipboardSet(text: String) {
        post {
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("terminal", text))
        }
    }

    // Drawing

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val em = emulator ?: return
        synchronized(em) {
            if (scrollOffset > em.scrollback.size) scrollOffset = em.scrollback.size
            val left = paddingLeft.toFloat()
            val top = paddingTop.toFloat()
            val focused = isFocused
            for (row in 0 until rows) {
                val line = em.line(row, scrollOffset)
                val y = top + row * cellHeight
                drawBackgrounds(canvas, line, left, y)
                drawGlyphs(canvas, line, left, y)
            }
            if (scrollOffset == 0 && em.cursorVisible && em.cursorRow < rows) {
                val line = em.line(em.cursorRow, 0)
                val col = em.cursorCol.coerceIn(0, columns - 1)
                val x = left + col * cellWidth
                val y = top + em.cursorRow * cellHeight
                val wide = line.attrs[col] and Attr.WIDE != 0
                val w = if (wide) cellWidth * 2 else cellWidth
                fill.color = CURSOR
                if (focused) {
                    canvas.drawRect(x, y, x + w, y + cellHeight, fill)
                    val code = line.codes[col]
                    if (code != 0 && code != 32) drawGlyph(canvas, code, line.extra?.get(col), x, y, BACKGROUND, line.attrs[col])
                } else {
                    fill.style = Paint.Style.STROKE
                    fill.strokeWidth = 2f
                    canvas.drawRect(x + 1, y + 1, x + w - 1, y + cellHeight - 1, fill)
                    fill.style = Paint.Style.FILL
                }
            }
        }
    }

    private fun drawBackgrounds(canvas: Canvas, line: TerminalLine, left: Float, y: Float) {
        var col = 0
        while (col < columns) {
            val colour = backgroundOf(line, col)
            var end = col + 1
            while (end < columns && backgroundOf(line, end) == colour) end++
            if (colour != BACKGROUND) {
                fill.color = colour
                canvas.drawRect(left + col * cellWidth, y, left + end * cellWidth, y + cellHeight, fill)
            }
            col = end
        }
    }

    private fun drawGlyphs(canvas: Canvas, line: TerminalLine, left: Float, y: Float) {
        var col = 0
        while (col < columns) {
            val a = line.attrs[col]
            if (a and Attr.WIDE_TRAIL != 0 || a and Attr.HIDDEN != 0) { col++; continue }
            val code = line.codes[col]
            if (code == 0 || code == 32) {
                if (a and (Attr.UNDERLINE or Attr.STRIKE) != 0) drawLines(canvas, left + col * cellWidth, y, cellWidth, foregroundOf(line, col), a)
                col++
                continue
            }
            drawGlyph(canvas, code, line.extra?.get(col), left + col * cellWidth, y, foregroundOf(line, col), a)
            col += if (a and Attr.WIDE != 0) 2 else 1
        }
    }

    private fun drawGlyph(canvas: Canvas, code: Int, extra: String?, x: Float, y: Float, colour: Int, a: Int) {
        val paint = if (a and Attr.BOLD != 0) boldText else text
        paint.color = colour
        paint.alpha = if (a and Attr.DIM != 0) 140 else 255
        paint.textSkewX = if (a and Attr.ITALIC != 0) -0.2f else 0f
        val width = if (a and Attr.WIDE != 0) cellWidth * 2 else cellWidth
        if (extra == null && code < 0x10000) {
            glyph[0] = code.toChar()
            canvas.drawText(glyph, 0, 1, x, y + baseline, paint)
        } else {
            val s = StringBuilder().appendCodePoint(code).append(extra ?: "").toString()
            canvas.drawText(s, x, y + baseline, paint)
        }
        if (a and (Attr.UNDERLINE or Attr.STRIKE) != 0) drawLines(canvas, x, y, width, colour, a)
    }

    private fun drawLines(canvas: Canvas, x: Float, y: Float, width: Float, colour: Int, a: Int) {
        fill.color = colour
        val thickness = (cellHeight / 14f).coerceAtLeast(1f)
        if (a and Attr.UNDERLINE != 0) canvas.drawRect(x, y + cellHeight - thickness - 1, x + width, y + cellHeight - 1, fill)
        if (a and Attr.STRIKE != 0) canvas.drawRect(x, y + cellHeight / 2 - thickness / 2, x + width, y + cellHeight / 2 + thickness / 2, fill)
    }

    private fun backgroundOf(line: TerminalLine, col: Int): Int {
        val a = line.attrs[col]
        return if (a and Attr.INVERSE != 0) resolve(line.fg[col], FOREGROUND, a) else resolve(line.bg[col], BACKGROUND, 0)
    }

    private fun foregroundOf(line: TerminalLine, col: Int): Int {
        val a = line.attrs[col]
        return if (a and Attr.INVERSE != 0) resolve(line.bg[col], BACKGROUND, 0) else resolve(line.fg[col], FOREGROUND, a)
    }

    private fun resolve(colour: Int, default: Int, a: Int): Int = when {
        colour == Colour.DEFAULT -> default
        Colour.isTrue(colour) -> (colour and 0xFFFFFF) or (0xFF shl 24)
        else -> {
            var index = Colour.paletteIndex(colour)
            // Bold makes the eight base colours bright, as most terminals still do.
            if (a and Attr.BOLD != 0 && index < 8) index += 8
            palette[index.coerceIn(0, 255)]
        }
    }

    private fun buildPalette() {
        val base = intArrayOf(
            0x1F1F1F, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xCCCCCC,
            0x666666, 0xF88070, 0x5AF78E, 0xF9F871, 0x6CB6FF, 0xE39BE3, 0x66D9EF, 0xFFFFFF,
        )
        for (i in 0 until 16) palette[i] = base[i] or (0xFF shl 24)
        val steps = intArrayOf(0, 95, 135, 175, 215, 255)
        for (i in 0 until 216) {
            val r = steps[i / 36]
            val g = steps[(i / 6) % 6]
            val b = steps[i % 6]
            palette[16 + i] = Color.rgb(r, g, b)
        }
        for (i in 0 until 24) {
            val v = 8 + i * 10
            palette[232 + i] = Color.rgb(v, v, v)
        }
    }

    // Touch

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaler.onTouchEvent(event)
        if (!scaler.isInProgress) gestures.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) scrollRemainder = 0f
        return true
    }

    fun showKeyboard() {
        requestFocus()
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }

    fun hideKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(windowToken, 0)
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: android.graphics.Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        invalidate()
    }

    // Keys

    override fun onCheckIsTextEditor(): Boolean = true

    /**
     * Raw keys, not text. With no input type the keyboard sends each key as a key event and skips
     * suggestions and autocorrect; text it still commits, such as a word from a swipe or a character
     * a language needs composing, arrives through [commitText] and goes to the shell as it is.
     */
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = EditorInfo.TYPE_NULL
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, true) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                super.commitText(text, newCursorPosition)
                val content = editable
                if (content != null && content.isNotEmpty()) {
                    sendText(content.toString())
                    content.clear()
                }
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                // A keyboard deleting "surrounding text" means Backspace, once per character.
                val content = editable
                if (content != null && content.isNotEmpty()) {
                    val take = beforeLength.coerceAtMost(content.length)
                    content.delete(content.length - take, content.length)
                    val left = beforeLength - take
                    repeat(left) { sendKey(KeyEvent.KEYCODE_DEL, 0) }
                    return true
                }
                repeat(beforeLength) { sendKey(KeyEvent.KEYCODE_DEL, 0) }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) return onKeyDown(event.keyCode, event)
                return true
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
            keyCode == KeyEvent.KEYCODE_MENU || keyCode == KeyEvent.KEYCODE_HOME) return super.onKeyDown(keyCode, event)
        if (keyCode == KeyEvent.KEYCODE_UNKNOWN && event.action == KeyEvent.ACTION_MULTIPLE) {
            event.characters?.let { sendText(it) }
            return true
        }
        return sendKey(keyCode, event.metaState, event)
    }

    /** Turns a key into what the shell expects, taking the pending Control and Alt into account. */
    fun sendKey(keyCode: Int, metaState: Int, event: KeyEvent? = null): Boolean {
        val em = emulator
        val ctrl = ctrlPending || metaState and KeyEvent.META_CTRL_ON != 0
        val alt = altPending || metaState and KeyEvent.META_ALT_ON != 0
        val shift = metaState and KeyEvent.META_SHIFT_ON != 0
        val app = em?.applicationCursorKeys == true
        val modifier = 1 + (if (shift) 1 else 0) + (if (alt) 2 else 0) + (if (ctrl) 4 else 0)
        fun cursor(letter: Char): String = if (modifier > 1) "\u001b[1;$modifier$letter" else if (app) "\u001bO$letter" else "\u001b[$letter"
        fun tilde(number: Int): String = if (modifier > 1) "\u001b[$number;$modifier~" else "\u001b[$number~"
        val special: String? = when (keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> if (alt) "\u001b\r" else "\r"
            KeyEvent.KEYCODE_DEL -> if (alt) "\u001b\u007f" else "\u007f"
            KeyEvent.KEYCODE_FORWARD_DEL -> tilde(3)
            KeyEvent.KEYCODE_TAB -> if (shift) "\u001b[Z" else "\t"
            KeyEvent.KEYCODE_ESCAPE -> "\u001b"
            KeyEvent.KEYCODE_DPAD_UP -> cursor('A')
            KeyEvent.KEYCODE_DPAD_DOWN -> cursor('B')
            KeyEvent.KEYCODE_DPAD_RIGHT -> cursor('C')
            KeyEvent.KEYCODE_DPAD_LEFT -> cursor('D')
            KeyEvent.KEYCODE_MOVE_HOME -> cursor('H')
            KeyEvent.KEYCODE_MOVE_END -> cursor('F')
            KeyEvent.KEYCODE_INSERT -> tilde(2)
            KeyEvent.KEYCODE_PAGE_UP -> tilde(5)
            KeyEvent.KEYCODE_PAGE_DOWN -> tilde(6)
            KeyEvent.KEYCODE_F1 -> "\u001bOP"
            KeyEvent.KEYCODE_F2 -> "\u001bOQ"
            KeyEvent.KEYCODE_F3 -> "\u001bOR"
            KeyEvent.KEYCODE_F4 -> "\u001bOS"
            KeyEvent.KEYCODE_F5 -> tilde(15)
            KeyEvent.KEYCODE_F6 -> tilde(17)
            KeyEvent.KEYCODE_F7 -> tilde(18)
            KeyEvent.KEYCODE_F8 -> tilde(19)
            KeyEvent.KEYCODE_F9 -> tilde(20)
            KeyEvent.KEYCODE_F10 -> tilde(21)
            KeyEvent.KEYCODE_F11 -> tilde(23)
            KeyEvent.KEYCODE_F12 -> tilde(24)
            else -> null
        }
        if (special != null) {
            send(special.toByteArray(Charsets.UTF_8))
            return true
        }
        // A printable key: the character it makes without Control or Alt, which would blank it.
        val plainMeta = metaState and (KeyEvent.META_SHIFT_MASK or KeyEvent.META_CAPS_LOCK_ON or KeyEvent.META_NUM_LOCK_ON)
        var ch = event?.getUnicodeChar(plainMeta) ?: KeyEvent(KeyEvent.ACTION_DOWN, keyCode).getUnicodeChar(plainMeta)
        if (ch == 0 || ch and KeyCharacterMap_COMBINING != 0) return false
        if (ctrl) {
            val upper = Character.toUpperCase(ch)
            ch = when {
                upper in 'A'.code..'Z'.code -> upper - '@'.code
                ch == ' '.code || ch == '@'.code || ch == '2'.code -> 0
                ch in '['.code..'_'.code -> ch - '@'.code
                ch == '?'.code -> 0x7f
                ch in '3'.code..'7'.code -> ch - '3'.code + 0x1b
                ch == '8'.code -> 0x7f
                else -> ch
            }
        }
        val out = StringBuilder()
        if (alt) out.append('\u001b')
        out.appendCodePoint(ch)
        send(out.toString().toByteArray(Charsets.UTF_8))
        return true
    }

    /** Typed or pasted text, sent as it is; a paste is wrapped when the program asked for that. */
    fun sendText(text: String, paste: Boolean = false) {
        val em = emulator
        var out = text
        if (paste) {
            out = out.replace("\r\n", "\r").replace('\n', '\r')
            if (em?.bracketedPaste == true) out = "\u001b[200~$out\u001b[201~"
        } else if (altPending || ctrlPending) {
            // A modifier from the key bar applies to a single typed character too.
            val cp = text.codePointAt(0)
            if (Character.charCount(cp) == text.length) {
                val meta = 0
                val event = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_UNKNOWN)
                if (ctrlPending && cp < 128) {
                    val upper = Character.toUpperCase(cp)
                    val code = if (upper in 'A'.code..'Z'.code) upper - '@'.code else cp
                    out = (if (altPending) "\u001b" else "") + code.toChar()
                    send(out.toByteArray(Charsets.UTF_8))
                    return
                }
                if (altPending) out = "\u001b$text"
                if (event.action == meta) { /* keeps the compiler quiet about unused locals */ }
            }
        }
        send(out.toByteArray(Charsets.UTF_8))
    }

    private fun send(bytes: ByteArray) {
        if (ctrlPending) ctrlPending = false
        if (altPending) altPending = false
        if (scrollOffset != 0) {
            scrollOffset = 0
            invalidate()
        }
        host?.send(bytes)
    }

    /** What is on the screen now, for copying. */
    fun screenText(): String {
        val em = emulator ?: return ""
        return synchronized(em) { em.screenText() }
    }

    companion object {
        const val BACKGROUND = 0xFF1F1F1F.toInt()
        const val FOREGROUND = 0xFFD4D4D4.toInt()
        const val CURSOR = 0xFF4D8EF7.toInt()
        private const val KeyCharacterMap_COMBINING = android.view.KeyCharacterMap.COMBINING_ACCENT
    }
}
