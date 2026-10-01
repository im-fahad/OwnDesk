package io.github.im_fahad.owndesk.terminal

/** Attribute bits on a cell. */
object Attr {
    const val BOLD = 1
    const val DIM = 2
    const val ITALIC = 4
    const val UNDERLINE = 8
    const val BLINK = 16
    const val INVERSE = 32
    const val HIDDEN = 64
    const val STRIKE = 128
    /** The left half of a character two cells wide. */
    const val WIDE = 256
    /** The right half of one: nothing is drawn here. */
    const val WIDE_TRAIL = 512

    /** The bits set by SGR, as opposed to the two that describe a character's width. */
    const val SGR_MASK = BOLD or DIM or ITALIC or UNDERLINE or BLINK or INVERSE or HIDDEN or STRIKE
}

/**
 * How a cell's colour is kept: 0 for the default, 1 + index for one of the 256 palette colours,
 * and [TRUE] with the RGB in the low 24 bits for a colour named by value.
 */
object Colour {
    const val DEFAULT = 0
    const val TRUE = 1 shl 24

    fun palette(index: Int): Int = 1 + index.coerceIn(0, 255)
    fun rgb(r: Int, g: Int, b: Int): Int = TRUE or ((r and 255) shl 16) or ((g and 255) shl 8) or (b and 255)
    fun isTrue(colour: Int): Boolean = colour and TRUE != 0
    fun paletteIndex(colour: Int): Int = colour - 1
}

/** One row of the terminal: a code point, colours and attributes per cell. */
class TerminalLine(cols: Int) {
    var codes = IntArray(cols)
    var fg = IntArray(cols)
    var bg = IntArray(cols)
    var attrs = IntArray(cols)
    /** Text continues on the next line: the shell wrapped it, nobody pressed Return. */
    var wrapped = false
    /** Combining marks that follow a cell's base character, by column. Rare, so kept aside. */
    var extra: HashMap<Int, String>? = null

    val cols: Int get() = codes.size

    fun resize(newCols: Int) {
        if (newCols == cols) return
        codes = codes.copyOf(newCols)
        fg = fg.copyOf(newCols)
        bg = bg.copyOf(newCols)
        attrs = attrs.copyOf(newCols)
        extra?.keys?.retainAll { it < newCols }
        // A wide character cut in half at the new edge leaves an orphaned lead cell.
        if (newCols > 0 && attrs[newCols - 1] and Attr.WIDE != 0) {
            codes[newCols - 1] = 0
            attrs[newCols - 1] = 0
        }
    }

    /** Blank cells in [from, to), keeping only the background colour, as xterm's erase does. */
    fun erase(from: Int, to: Int, background: Int) {
        val start = from.coerceIn(0, cols)
        val end = to.coerceIn(start, cols)
        for (i in start until end) {
            codes[i] = 0
            fg[i] = Colour.DEFAULT
            bg[i] = background
            attrs[i] = 0
        }
        extra?.keys?.removeAll { it in start until end }
    }

    /** The row as text, trailing blanks dropped. */
    fun text(): String {
        val out = StringBuilder()
        var last = -1
        for (i in 0 until cols) if (codes[i] != 0 && codes[i] != 32) last = i
        for (i in 0..last) {
            if (attrs[i] and Attr.WIDE_TRAIL != 0) continue
            out.appendCodePoint(if (codes[i] == 0) 32 else codes[i])
            extra?.get(i)?.let { out.append(it) }
        }
        return out.toString()
    }
}

/**
 * A terminal without a screen: the part that understands what a shell prints.
 *
 * Bytes go in with [write] and the grid of cells comes out through [line]; the view draws that. It
 * speaks the xterm dialect the Mac's shells and editors expect for `TERM=xterm-256color`: cursor
 * movement, scrolling regions, the alternate screen, 256 and true colours, bracketed paste, wide
 * characters. What it answers to a query goes back through [Listener.respond].
 *
 * Not thread-safe by itself: the SSH reader writes and the view reads, so each holds the emulator's
 * monitor while it does.
 */
class TerminalEmulator(cols: Int, rows: Int, private val scrollbackLimit: Int = 2000, private val listener: Listener) {
    interface Listener {
        /** An answer to a query, for the shell. Called from inside [write]. */
        fun respond(bytes: ByteArray)
        fun titleChanged(title: String)
        fun bell()
        /** A program asked to put text on the clipboard (OSC 52). */
        fun clipboardSet(text: String)
    }

    var cols: Int = cols.coerceAtLeast(1); private set
    var rows: Int = rows.coerceAtLeast(1); private set

    private var main: Array<TerminalLine> = Array(this.rows) { TerminalLine(this.cols) }
    private var alt: Array<TerminalLine> = Array(this.rows) { TerminalLine(this.cols) }
    private var screen: Array<TerminalLine> = main
    /** Lines that scrolled off the top of the main screen, oldest first. */
    val scrollback = ArrayDeque<TerminalLine>()
    var altActive = false; private set

    var cursorRow = 0; private set
    var cursorCol = 0; private set
    /** The last column was written; the next character wraps first. */
    private var pendingWrap = false

    private var fg = Colour.DEFAULT
    private var bg = Colour.DEFAULT
    private var attrs = 0

    var cursorVisible = true; private set
    var applicationCursorKeys = false; private set
    var bracketedPaste = false; private set
    var title = ""; private set
    private var autoWrap = true
    private var originMode = false
    private var insertMode = false
    private var lineFeedMode = false
    private var scrollTop = 0
    private var scrollBottom = this.rows - 1
    private var tabStops = defaultTabs(this.cols)
    private val charsets = charArrayOf('B', 'B')
    private var shifted = 0
    private var lastPrinted = 0

    private class SavedCursor(
        val row: Int, val col: Int, val fg: Int, val bg: Int, val attrs: Int,
        val originMode: Boolean, val autoWrap: Boolean, val g0: Char, val g1: Char, val shifted: Int,
    )

    private var savedMain: SavedCursor? = null
    private var savedAlt: SavedCursor? = null

    // Parsing

    private enum class State { GROUND, ESC, ESC_INTERMEDIATE, CSI, OSC, OSC_ESC, STRING, STRING_ESC }

    private var state = State.GROUND
    private val params = StringBuilder()
    private val intermediates = StringBuilder()
    private var csiPrivate = 0.toChar()
    private val osc = StringBuilder()
    private var utfCode = 0
    private var utfNeeded = 0

    // Reading

    /** The line shown at [viewRow] when the view is scrolled back [scrollOffset] lines. */
    fun line(viewRow: Int, scrollOffset: Int = 0): TerminalLine {
        val index = scrollback.size - scrollOffset + viewRow
        return if (index < scrollback.size) scrollback[index.coerceAtLeast(0)] else screen[(index - scrollback.size).coerceIn(0, rows - 1)]
    }

    /** What is on the screen now, as text. */
    fun screenText(): String = screen.joinToString("\n") { it.text() }.trimEnd()

    // Selection. Rows here count from the oldest line of the scrollback, so a row keeps meaning the
    // same line while new output pushes the screen into the history.

    /** The scrollback and the screen together. */
    val totalRows: Int get() = scrollback.size + rows

    /** The row the view shows at [viewRow] when scrolled back [scrollOffset] lines. */
    fun absoluteRow(viewRow: Int, scrollOffset: Int = 0): Int = scrollback.size - scrollOffset + viewRow

    fun lineAt(row: Int): TerminalLine? = when {
        row < 0 -> null
        row < scrollback.size -> scrollback[row]
        row - scrollback.size < rows -> screen[row - scrollback.size]
        else -> null
    }

    /** The cell holding the character at [col]: the right half of a wide one belongs to its left. */
    fun leadColumn(row: Int, col: Int): Int {
        val line = lineAt(row) ?: return col
        val c = col.coerceIn(0, line.cols - 1)
        return if (c > 0 && line.attrs[c] and Attr.WIDE_TRAIL != 0) c - 1 else c
    }

    /**
     * The word at a cell, as the first and last columns, for a long press. A word runs between
     * blanks and brackets and quotes, so a path, an address or a flag is taken whole. Null on a blank.
     */
    fun wordAt(row: Int, col: Int): IntRange? {
        val line = lineAt(row) ?: return null
        val start = leadColumn(row, col)
        if (!isWordCell(line, start)) return null
        var first = start
        while (first > 0 && (line.attrs[first - 1] and Attr.WIDE_TRAIL != 0 || isWordCell(line, first - 1))) first--
        var last = start
        while (last < line.cols - 1 && (line.attrs[last + 1] and Attr.WIDE_TRAIL != 0 || isWordCell(line, last + 1))) last++
        return first..last
    }

    private fun isWordCell(line: TerminalLine, col: Int): Boolean {
        val code = line.codes[col]
        if (code == 0 || Character.isWhitespace(code)) return false
        return code > 127 || code.toChar() !in WORD_BREAKS
    }

    /**
     * The text from one cell to another, both included, in either order. A line the shell wrapped
     * runs on into the next without a line break; any other line ends with one, its trailing blanks
     * dropped, as a copy from a terminal should.
     */
    fun textBetween(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int): String {
        val forward = fromRow < toRow || (fromRow == toRow && fromCol <= toCol)
        val (r0, c0, r1, c1) = if (forward) listOf(fromRow, fromCol, toRow, toCol) else listOf(toRow, toCol, fromRow, fromCol)
        val out = StringBuilder()
        for (row in r0.coerceAtLeast(0)..r1.coerceAtMost(totalRows - 1)) {
            val line = lineAt(row) ?: continue
            val first = if (row == r0) leadColumn(row, c0) else 0
            val last = if (row == r1) c1.coerceIn(0, line.cols - 1) else line.cols - 1
            val piece = StringBuilder()
            for (i in first..last) {
                if (line.attrs[i] and Attr.WIDE_TRAIL != 0) continue
                piece.appendCodePoint(if (line.codes[i] == 0) 32 else line.codes[i])
                line.extra?.get(i)?.let { piece.append(it) }
            }
            val runsOn = line.wrapped && row != r1
            out.append(if (runsOn) piece else piece.trimEnd(' '))
            if (row != r1 && !runsOn) out.append('\n')
        }
        return out.toString()
    }

    // Writing

    /** Feeds what the shell printed. UTF-8 sequences may be split across calls. */
    fun write(bytes: ByteArray, length: Int = bytes.size) {
        for (i in 0 until length) {
            val b = bytes[i].toInt() and 0xFF
            if (utfNeeded > 0) {
                if (b and 0xC0 == 0x80) {
                    utfCode = (utfCode shl 6) or (b and 0x3F)
                    if (--utfNeeded == 0) process(utfCode)
                    continue
                }
                // Not a continuation byte: the sequence was cut short. Show that and carry on.
                utfNeeded = 0
                process(0xFFFD)
            }
            when {
                b < 0x80 -> process(b)
                b and 0xE0 == 0xC0 -> { utfCode = b and 0x1F; utfNeeded = 1 }
                b and 0xF0 == 0xE0 -> { utfCode = b and 0x0F; utfNeeded = 2 }
                b and 0xF8 == 0xF0 -> { utfCode = b and 0x07; utfNeeded = 3 }
                else -> process(0xFFFD)
            }
        }
    }

    private fun process(cp: Int) {
        // Controls act at once, whatever is being parsed, except inside a string.
        if (cp == 0x1B && state != State.OSC && state != State.STRING) {
            beginEscape()
            return
        }
        when (state) {
            State.GROUND -> if (cp < 0x20 || cp == 0x7F) control(cp) else if (cp in 0x80..0x9F) c1(cp) else print(cp)
            State.ESC -> escape(cp)
            State.ESC_INTERMEDIATE -> escapeIntermediate(cp)
            State.CSI -> if (cp < 0x20) control(cp) else csi(cp)
            State.OSC -> when (cp) {
                0x07 -> { dispatchOsc(); state = State.GROUND }
                0x1B -> state = State.OSC_ESC
                else -> if (cp >= 0x20) osc.appendCodePoint(cp)
            }
            State.OSC_ESC -> {
                // ESC \ ends the string; anything else was a new escape after an unterminated one.
                if (cp == '\\'.code) dispatchOsc()
                state = State.GROUND
                if (cp != '\\'.code) { beginEscape(); escape(cp) }
            }
            State.STRING -> if (cp == 0x1B) state = State.STRING_ESC else if (cp == 0x07) state = State.GROUND
            State.STRING_ESC -> {
                state = State.GROUND
                if (cp != '\\'.code) { beginEscape(); escape(cp) }
            }
        }
    }

    private fun beginEscape() {
        state = State.ESC
        params.setLength(0)
        intermediates.setLength(0)
        csiPrivate = 0.toChar()
    }

    private fun control(cp: Int) {
        when (cp) {
            0x07 -> listener.bell()
            0x08 -> if (cursorCol > 0) { cursorCol--; pendingWrap = false }
            0x09 -> tab(1)
            0x0A, 0x0B, 0x0C -> { lineFeed(); if (lineFeedMode) cursorCol = 0 }
            0x0D -> { cursorCol = 0; pendingWrap = false }
            0x0E -> shifted = 1
            0x0F -> shifted = 0
            0x18, 0x1A -> state = State.GROUND
        }
    }

    /** 8-bit controls: the few that matter map onto their 7-bit forms. */
    private fun c1(cp: Int) {
        when (cp) {
            0x84 -> lineFeed()
            0x85 -> { lineFeed(); cursorCol = 0 }
            0x88 -> tabStops[cursorCol] = true
            0x8D -> reverseIndex()
            0x9B -> { beginEscape(); state = State.CSI }
            0x9D -> { beginEscape(); state = State.OSC; osc.setLength(0) }
            0x90, 0x98, 0x9E, 0x9F -> { beginEscape(); state = State.STRING }
        }
    }

    private fun escape(cp: Int) {
        state = State.GROUND
        when (cp.toChar()) {
            '[' -> state = State.CSI
            ']' -> { state = State.OSC; osc.setLength(0) }
            'P', 'X', '^', '_' -> state = State.STRING
            '(', ')', '*', '+', '#', ' ', '%' -> { intermediates.append(cp.toChar()); state = State.ESC_INTERMEDIATE }
            '7' -> saveCursor()
            '8' -> restoreCursor()
            'D' -> lineFeed()
            'E' -> { lineFeed(); cursorCol = 0 }
            'H' -> tabStops[cursorCol] = true
            'M' -> reverseIndex()
            'c' -> reset()
            else -> {}
        }
    }

    private fun escapeIntermediate(cp: Int) {
        state = State.GROUND
        val kind = intermediates.firstOrNull() ?: return
        val c = cp.toChar()
        when (kind) {
            '(' -> charsets[0] = c
            ')' -> charsets[1] = c
            '#' -> if (c == '8') fillScreen('E'.code)
            else -> {}
        }
    }

    private fun csi(cp: Int) {
        val c = cp.toChar()
        when {
            c in '0'..'9' || c == ';' || c == ':' -> params.append(c)
            cp in 0x3C..0x3F && params.isEmpty() && intermediates.isEmpty() -> csiPrivate = c
            cp in 0x20..0x2F -> intermediates.append(c)
            cp in 0x40..0x7E -> { state = State.GROUND; dispatchCsi(c) }
            else -> state = State.GROUND
        }
    }

    private fun intParams(): IntArray {
        if (params.isEmpty()) return IntArray(0)
        return params.split(';').map { token ->
            token.substringBefore(':').toIntOrNull() ?: 0
        }.toIntArray()
    }

    private fun IntArray.at(index: Int, default: Int): Int {
        val value = getOrNull(index) ?: 0
        return if (value == 0) default else value
    }

    private fun dispatchCsi(final: Char) {
        val p = intParams()
        val n = p.at(0, 1)
        when (final) {
            '@' -> insertChars(n)
            'A' -> moveCursor(-n, 0)
            'B', 'e' -> moveCursor(n, 0)
            'C', 'a' -> moveCursor(0, n)
            'D' -> moveCursor(0, -n)
            'E' -> { moveCursor(n, 0); cursorCol = 0 }
            'F' -> { moveCursor(-n, 0); cursorCol = 0 }
            'G', '`' -> setCursor(cursorRow, n - 1, absoluteRow = true)
            'H', 'f' -> setCursor(p.at(0, 1) - 1, p.at(1, 1) - 1)
            'I' -> tab(n)
            'J' -> eraseDisplay(p.getOrNull(0) ?: 0)
            'K' -> eraseLine(p.getOrNull(0) ?: 0)
            'L' -> insertLines(n)
            'M' -> deleteLines(n)
            'P' -> deleteChars(n)
            'S' -> scrollUp(n, scrollTop, scrollBottom)
            'T' -> scrollDown(n, scrollTop, scrollBottom)
            'X' -> eraseChars(n)
            'Z' -> tab(-n)
            'b' -> if (lastPrinted != 0) repeat(n) { print(lastPrinted) }
            'c' -> deviceAttributes()
            'd' -> setCursor(n - 1, cursorCol)
            'g' -> when (p.getOrNull(0) ?: 0) {
                0 -> tabStops[cursorCol] = false
                3 -> tabStops.fill(false)
            }
            'h' -> setModes(p, true)
            'l' -> setModes(p, false)
            'm' -> selectGraphics()
            'n' -> when (p.getOrNull(0)) {
                5 -> respond("\u001b[0n")
                6 -> respond("\u001b[${(if (originMode) cursorRow - scrollTop else cursorRow) + 1};${cursorCol + 1}R")
            }
            'p' -> if (intermediates.toString() == "!") softReset()
            'r' -> if (csiPrivate == 0.toChar()) {
                val top = p.at(0, 1) - 1
                val bottom = p.at(1, rows) - 1
                if (top in 0 until bottom && bottom < rows) {
                    scrollTop = top
                    scrollBottom = bottom
                    setCursor(0, 0)
                }
            }
            's' -> if (csiPrivate == 0.toChar()) saveCursor()
            'u' -> if (csiPrivate == 0.toChar()) restoreCursor()
            't' -> if (p.getOrNull(0) == 18) respond("\u001b[8;$rows;${cols}t")
            else -> {}
        }
    }

    private fun deviceAttributes() {
        when (csiPrivate) {
            0.toChar() -> respond("\u001b[?62;1;2;6;9;15;22c")
            '>' -> respond("\u001b[>0;276;0c")
            else -> {}
        }
    }

    private fun setModes(p: IntArray, on: Boolean) {
        for (mode in p) {
            if (csiPrivate == '?') {
                when (mode) {
                    1 -> applicationCursorKeys = on
                    6 -> { originMode = on; setCursor(0, 0) }
                    7 -> autoWrap = on
                    25 -> cursorVisible = on
                    47, 1047 -> {
                        if (!on && mode == 1047 && altActive) clearScreen(alt)
                        switchScreen(on)
                    }
                    1048 -> if (on) saveCursor() else restoreCursor()
                    1049 -> if (on) {
                        saveCursor()
                        switchScreen(true)
                        clearScreen(alt)
                        setCursor(0, 0)
                    } else {
                        switchScreen(false)
                        restoreCursor()
                    }
                    2004 -> bracketedPaste = on
                    else -> {}
                }
            } else {
                when (mode) {
                    4 -> insertMode = on
                    20 -> lineFeedMode = on
                }
            }
        }
    }

    private fun selectGraphics() {
        if (params.isEmpty()) { fg = Colour.DEFAULT; bg = Colour.DEFAULT; attrs = 0; return }
        val tokens = params.split(';')
        var i = 0
        while (i < tokens.size) {
            val sub = tokens[i].split(':')
            val code = sub[0].toIntOrNull() ?: 0
            i++
            when (code) {
                0 -> { fg = Colour.DEFAULT; bg = Colour.DEFAULT; attrs = 0 }
                1 -> attrs = attrs or Attr.BOLD
                2 -> attrs = attrs or Attr.DIM
                3 -> attrs = attrs or Attr.ITALIC
                4 -> attrs = if (sub.getOrNull(1) == "0") attrs and Attr.UNDERLINE.inv() else attrs or Attr.UNDERLINE
                5, 6 -> attrs = attrs or Attr.BLINK
                7 -> attrs = attrs or Attr.INVERSE
                8 -> attrs = attrs or Attr.HIDDEN
                9 -> attrs = attrs or Attr.STRIKE
                21 -> attrs = attrs or Attr.UNDERLINE
                22 -> attrs = attrs and (Attr.BOLD or Attr.DIM).inv()
                23 -> attrs = attrs and Attr.ITALIC.inv()
                24 -> attrs = attrs and Attr.UNDERLINE.inv()
                25 -> attrs = attrs and Attr.BLINK.inv()
                27 -> attrs = attrs and Attr.INVERSE.inv()
                28 -> attrs = attrs and Attr.HIDDEN.inv()
                29 -> attrs = attrs and Attr.STRIKE.inv()
                in 30..37 -> fg = Colour.palette(code - 30)
                39 -> fg = Colour.DEFAULT
                in 40..47 -> bg = Colour.palette(code - 40)
                49 -> bg = Colour.DEFAULT
                in 90..97 -> fg = Colour.palette(code - 90 + 8)
                in 100..107 -> bg = Colour.palette(code - 100 + 8)
                38, 48 -> {
                    // Either 38;5;n / 38;2;r;g;b as separate tokens, or 38:5:n / 38:2::r:g:b in one.
                    val colour: Int
                    if (sub.size > 1) {
                        val values = sub.drop(1).map { it.toIntOrNull() ?: 0 }
                        colour = when (values[0]) {
                            5 -> Colour.palette(values.getOrNull(1) ?: 0)
                            2 -> {
                                // 38:2:r:g:b, or 38:2:colourspace:r:g:b as ITU T.416 has it.
                                val rgb = if (values.size >= 5) values.drop(2) else values.drop(1)
                                Colour.rgb(rgb.getOrNull(0) ?: 0, rgb.getOrNull(1) ?: 0, rgb.getOrNull(2) ?: 0)
                            }
                            else -> Colour.DEFAULT
                        }
                    } else {
                        val kind = tokens.getOrNull(i)?.toIntOrNull() ?: 0
                        i++
                        colour = when (kind) {
                            5 -> { val v = tokens.getOrNull(i)?.toIntOrNull() ?: 0; i++; Colour.palette(v) }
                            2 -> {
                                val r = tokens.getOrNull(i)?.toIntOrNull() ?: 0
                                val g = tokens.getOrNull(i + 1)?.toIntOrNull() ?: 0
                                val b = tokens.getOrNull(i + 2)?.toIntOrNull() ?: 0
                                i += 3
                                Colour.rgb(r, g, b)
                            }
                            else -> Colour.DEFAULT
                        }
                    }
                    if (code == 38) fg = colour else bg = colour
                }
                else -> {}
            }
        }
    }

    private fun dispatchOsc() {
        val text = osc.toString()
        val code = text.substringBefore(';').toIntOrNull() ?: return
        val rest = text.substringAfter(';', "")
        when (code) {
            0, 2 -> { title = rest; listener.titleChanged(rest) }
            52 -> {
                // "c;<base64>": a program on the Mac puts text on this phone's clipboard.
                val payload = rest.substringAfter(';', "")
                if (payload.isNotEmpty() && payload != "?") {
                    runCatching { String(java.util.Base64.getDecoder().decode(payload), Charsets.UTF_8) }
                        .onSuccess { listener.clipboardSet(it) }
                }
            }
        }
    }

    private fun respond(text: String) = listener.respond(text.toByteArray(Charsets.UTF_8))

    // Printing

    private fun print(cp: Int) {
        var code = cp
        if (charsets[shifted] == '0' && code in 0x60..0x7E) code = LINE_DRAWING[code - 0x60]
        val width = charWidth(code)
        if (width == 0) {
            // A mark on the character before it, if there is one.
            val col = if (pendingWrap) cursorCol else cursorCol - 1
            if (col >= 0) {
                val line = screen[cursorRow]
                val target = if (line.attrs[col] and Attr.WIDE_TRAIL != 0) col - 1 else col
                if (target >= 0 && line.codes[target] != 0) {
                    val extra = line.extra ?: HashMap<Int, String>().also { line.extra = it }
                    extra[target] = (extra[target] ?: "") + String(Character.toChars(code))
                }
            }
            return
        }
        lastPrinted = cp
        if (pendingWrap) {
            if (autoWrap) {
                screen[cursorRow].wrapped = true
                cursorCol = 0
                lineFeed()
            }
            pendingWrap = false
        }
        if (width == 2 && cursorCol == cols - 1) {
            // A wide character does not fit in the last cell: leave it blank and go on to the next line.
            if (autoWrap) {
                put(cursorRow, cursorCol, 0, 1)
                screen[cursorRow].wrapped = true
                cursorCol = 0
                lineFeed()
            } else {
                cursorCol = cols - 2
            }
        }
        if (insertMode) shiftRight(cursorRow, cursorCol, width)
        put(cursorRow, cursorCol, code, width)
        cursorCol += width
        if (cursorCol >= cols) {
            cursorCol = cols - 1
            pendingWrap = true
        }
    }

    /** Writes one character at a cell, tidying up any wide character it lands on top of. */
    private fun put(row: Int, col: Int, code: Int, width: Int) {
        val line = screen[row]
        clearWide(line, col)
        if (width == 2 && col + 1 < cols) clearWide(line, col + 1)
        line.codes[col] = code
        line.fg[col] = fg
        line.bg[col] = bg
        line.attrs[col] = (attrs and Attr.SGR_MASK) or (if (width == 2) Attr.WIDE else 0)
        line.extra?.remove(col)
        if (width == 2 && col + 1 < cols) {
            line.codes[col + 1] = 0
            line.fg[col + 1] = fg
            line.bg[col + 1] = bg
            line.attrs[col + 1] = (attrs and Attr.SGR_MASK) or Attr.WIDE_TRAIL
            line.extra?.remove(col + 1)
        }
    }

    /** If the cell is half of a wide character, blank the other half so nothing is left orphaned. */
    private fun clearWide(line: TerminalLine, col: Int) {
        val a = line.attrs[col]
        if (a and Attr.WIDE != 0 && col + 1 < cols) {
            line.codes[col + 1] = 0
            line.attrs[col + 1] = line.attrs[col + 1] and Attr.WIDE_TRAIL.inv()
        } else if (a and Attr.WIDE_TRAIL != 0 && col > 0) {
            line.codes[col - 1] = 0
            line.attrs[col - 1] = line.attrs[col - 1] and Attr.WIDE.inv()
        }
    }

    private fun shiftRight(row: Int, from: Int, count: Int) {
        val line = screen[row]
        val n = count.coerceAtMost(cols - from)
        if (n <= 0) return
        for (i in cols - 1 downTo from + n) {
            line.codes[i] = line.codes[i - n]
            line.fg[i] = line.fg[i - n]
            line.bg[i] = line.bg[i - n]
            line.attrs[i] = line.attrs[i - n]
        }
        line.extra?.let { extra ->
            val moved = HashMap<Int, String>()
            for ((col, text) in extra) if (col < from) moved[col] = text else if (col + n < cols) moved[col + n] = text
            line.extra = moved
        }
        line.erase(from, from + n, bg)
        if (line.attrs[cols - 1] and Attr.WIDE != 0) { line.codes[cols - 1] = 0; line.attrs[cols - 1] = 0 }
    }

    // Cursor

    private fun moveCursor(dRow: Int, dCol: Int) {
        pendingWrap = false
        if (dRow != 0) {
            // Movement stops at the scrolling region's edge when the cursor is inside it.
            val top = if (cursorRow >= scrollTop) scrollTop else 0
            val bottom = if (cursorRow <= scrollBottom) scrollBottom else rows - 1
            cursorRow = (cursorRow + dRow).coerceIn(top, bottom)
        }
        if (dCol != 0) cursorCol = (cursorCol + dCol).coerceIn(0, cols - 1)
    }

    private fun setCursor(row: Int, col: Int, absoluteRow: Boolean = false) {
        pendingWrap = false
        cursorCol = col.coerceIn(0, cols - 1)
        cursorRow = if (originMode && !absoluteRow) (row + scrollTop).coerceIn(scrollTop, scrollBottom) else row.coerceIn(0, rows - 1)
    }

    private fun tab(count: Int) {
        pendingWrap = false
        var left = count
        if (count > 0) {
            while (left > 0 && cursorCol < cols - 1) {
                cursorCol++
                if (tabStops[cursorCol]) left--
            }
        } else {
            while (left < 0 && cursorCol > 0) {
                cursorCol--
                if (tabStops[cursorCol]) left++
            }
        }
    }

    private fun lineFeed() {
        pendingWrap = false
        if (cursorRow == scrollBottom) scrollUp(1, scrollTop, scrollBottom)
        else if (cursorRow < rows - 1) cursorRow++
    }

    private fun reverseIndex() {
        pendingWrap = false
        if (cursorRow == scrollTop) scrollDown(1, scrollTop, scrollBottom)
        else if (cursorRow > 0) cursorRow--
    }

    private fun saveCursor() {
        val saved = SavedCursor(cursorRow, cursorCol, fg, bg, attrs, originMode, autoWrap, charsets[0], charsets[1], shifted)
        if (altActive) savedAlt = saved else savedMain = saved
    }

    private fun restoreCursor() {
        val saved = (if (altActive) savedAlt else savedMain) ?: run { setCursor(0, 0); return }
        fg = saved.fg
        bg = saved.bg
        attrs = saved.attrs
        originMode = saved.originMode
        autoWrap = saved.autoWrap
        charsets[0] = saved.g0
        charsets[1] = saved.g1
        shifted = saved.shifted
        pendingWrap = false
        cursorRow = saved.row.coerceIn(0, rows - 1)
        cursorCol = saved.col.coerceIn(0, cols - 1)
    }

    // Screens and scrolling

    private fun switchScreen(toAlt: Boolean) {
        if (toAlt == altActive) return
        altActive = toAlt
        screen = if (toAlt) alt else main
        pendingWrap = false
    }

    private fun blankLine(): TerminalLine = TerminalLine(cols).also { if (bg != Colour.DEFAULT) it.erase(0, cols, bg) }

    private fun clearScreen(target: Array<TerminalLine>) {
        for (i in target.indices) target[i] = blankLine()
    }

    /** Lines leave the top of the region; on the main screen with the region the whole height, they go to the scrollback. */
    private fun scrollUp(count: Int, top: Int, bottom: Int) {
        val n = count.coerceIn(0, bottom - top + 1)
        if (n == 0) return
        val keepHistory = !altActive && top == 0 && bottom == rows - 1
        for (k in 0 until n) {
            val leaving = screen[top]
            if (keepHistory) {
                scrollback.addLast(leaving)
                if (scrollback.size > scrollbackLimit) scrollback.removeFirst()
            }
            for (i in top until bottom) screen[i] = screen[i + 1]
            screen[bottom] = blankLine()
        }
    }

    private fun scrollDown(count: Int, top: Int, bottom: Int) {
        val n = count.coerceIn(0, bottom - top + 1)
        if (n == 0) return
        for (k in 0 until n) {
            for (i in bottom downTo top + 1) screen[i] = screen[i - 1]
            screen[top] = blankLine()
        }
    }

    private fun insertLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        scrollDown(count, cursorRow, scrollBottom)
        cursorCol = 0
        pendingWrap = false
    }

    private fun deleteLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        val n = count.coerceIn(0, scrollBottom - cursorRow + 1)
        for (k in 0 until n) {
            for (i in cursorRow until scrollBottom) screen[i] = screen[i + 1]
            screen[scrollBottom] = blankLine()
        }
        cursorCol = 0
        pendingWrap = false
    }

    private fun insertChars(count: Int) {
        pendingWrap = false
        shiftRight(cursorRow, cursorCol, count)
    }

    private fun deleteChars(count: Int) {
        pendingWrap = false
        val line = screen[cursorRow]
        val n = count.coerceIn(0, cols - cursorCol)
        if (n == 0) return
        clearWide(line, cursorCol)
        for (i in cursorCol until cols - n) {
            line.codes[i] = line.codes[i + n]
            line.fg[i] = line.fg[i + n]
            line.bg[i] = line.bg[i + n]
            line.attrs[i] = line.attrs[i + n]
        }
        line.extra?.let { extra ->
            val moved = HashMap<Int, String>()
            for ((col, text) in extra) if (col < cursorCol) moved[col] = text else if (col - n >= cursorCol) moved[col - n] = text
            line.extra = moved
        }
        line.erase(cols - n, cols, bg)
    }

    private fun eraseChars(count: Int) {
        pendingWrap = false
        val line = screen[cursorRow]
        clearWide(line, cursorCol)
        val end = (cursorCol + count).coerceAtMost(cols)
        if (end < cols) clearWide(line, end - 1)
        line.erase(cursorCol, end, bg)
    }

    private fun eraseLine(mode: Int) {
        pendingWrap = false
        val line = screen[cursorRow]
        when (mode) {
            0 -> { clearWide(line, cursorCol); line.erase(cursorCol, cols, bg) }
            1 -> { clearWide(line, cursorCol); line.erase(0, cursorCol + 1, bg) }
            2 -> line.erase(0, cols, bg)
        }
    }

    private fun eraseDisplay(mode: Int) {
        pendingWrap = false
        when (mode) {
            0 -> {
                eraseLine(0)
                for (r in cursorRow + 1 until rows) screen[r] = blankLine()
            }
            1 -> {
                for (r in 0 until cursorRow) screen[r] = blankLine()
                eraseLine(1)
            }
            2 -> clearScreen(screen)
            3 -> { clearScreen(screen); scrollback.clear() }
        }
    }

    private fun fillScreen(code: Int) {
        for (r in 0 until rows) {
            val line = blankLine()
            for (c in 0 until cols) line.codes[c] = code
            screen[r] = line
        }
        scrollTop = 0
        scrollBottom = rows - 1
        setCursor(0, 0)
    }

    private fun softReset() {
        cursorVisible = true
        applicationCursorKeys = false
        originMode = false
        autoWrap = true
        insertMode = false
        scrollTop = 0
        scrollBottom = rows - 1
        fg = Colour.DEFAULT
        bg = Colour.DEFAULT
        attrs = 0
        charsets[0] = 'B'
        charsets[1] = 'B'
        shifted = 0
        pendingWrap = false
    }

    /** ESC c: everything back to how it started, the scrollback included. */
    fun reset() {
        softReset()
        bracketedPaste = false
        lineFeedMode = false
        switchScreen(false)
        clearScreen(main)
        clearScreen(alt)
        scrollback.clear()
        tabStops = defaultTabs(cols)
        savedMain = null
        savedAlt = null
        setCursor(0, 0)
        state = State.GROUND
    }

    // Size

    /** Follows the view. Lines that no longer fit go to the scrollback; room that opens up takes them back. */
    fun resize(newCols: Int, newRows: Int) {
        val c = newCols.coerceAtLeast(1)
        val r = newRows.coerceAtLeast(1)
        if (c == cols && r == rows) return
        if (c != cols) {
            for (line in main) line.resize(c)
            for (line in alt) line.resize(c)
            for (line in scrollback) line.resize(c)
            cols = c
            tabStops = defaultTabs(c)
            cursorCol = cursorCol.coerceAtMost(cols - 1)
        }
        if (r != rows) {
            val activeIsMain = !altActive
            main = fitRows(main, r, keepHistory = true, followCursor = activeIsMain)
            alt = fitRows(alt, r, keepHistory = false, followCursor = !activeIsMain)
            screen = if (altActive) alt else main
            rows = r
            cursorRow = cursorRow.coerceIn(0, rows - 1)
        }
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
    }

    private fun fitRows(lines: Array<TerminalLine>, newRows: Int, keepHistory: Boolean, followCursor: Boolean): Array<TerminalLine> {
        val old = lines.size
        if (newRows == old) return lines
        val list = lines.toMutableList()
        if (newRows < old) {
            var toRemove = old - newRows
            // Blank rows under the cursor go first; then the top scrolls into the history.
            val cursor = if (followCursor) cursorRow else old - 1
            while (toRemove > 0 && list.size - 1 > cursor && list.last().text().isEmpty()) {
                list.removeAt(list.size - 1)
                toRemove--
            }
            while (toRemove > 0 && list.size - 1 > cursor) {
                list.removeAt(list.size - 1)
                toRemove--
            }
            while (toRemove > 0) {
                val leaving = list.removeAt(0)
                if (keepHistory) {
                    scrollback.addLast(leaving)
                    if (scrollback.size > scrollbackLimit) scrollback.removeFirst()
                }
                if (followCursor) cursorRow--
                toRemove--
            }
        } else {
            var toAdd = newRows - old
            // What scrolled off comes back first, if the cursor is at the foot of the screen.
            if (keepHistory && followCursor && cursorRow == old - 1) {
                while (toAdd > 0 && scrollback.isNotEmpty()) {
                    list.add(0, scrollback.removeLast())
                    cursorRow++
                    toAdd--
                }
            }
            repeat(toAdd) { list.add(TerminalLine(cols)) }
        }
        return list.toTypedArray()
    }

    companion object {
        private fun defaultTabs(cols: Int) = BooleanArray(cols) { it > 0 && it % 8 == 0 }

        /** What ends a word for a long press, besides blanks. */
        private const val WORD_BREAKS = "\"'`()[]{}<>,;|"

        /** DEC special graphics, the box-drawing set programs like tmux and htop still use. */
        private val LINE_DRAWING = intArrayOf(
            0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA,
            0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7, 0x7F,
        )

        /** How many cells a character takes: none for a combining mark, two for East Asian and emoji. */
        fun charWidth(cp: Int): Int {
            if (cp == 0) return 1
            if (cp < 0x300) return 1
            when (Character.getType(cp).toByte()) {
                Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK, Character.FORMAT -> return 0
            }
            if (cp in 0x1160..0x11FF) return 0
            if (cp in 0x1F3FB..0x1F3FF || cp in 0xFE00..0xFE0F || cp in 0xE0100..0xE01EF) return 0
            return if (isWide(cp)) 2 else 1
        }

        private fun isWide(cp: Int): Boolean = when (cp) {
            in 0x1100..0x115F, in 0x231A..0x231B, in 0x2329..0x232A, in 0x23E9..0x23EC, 0x23F0, 0x23F3, in 0x25FD..0x25FE,
            in 0x2614..0x2615, in 0x2648..0x2653, 0x267F, 0x2693, 0x26A1, in 0x26AA..0x26AB, in 0x26BD..0x26BE, in 0x26C4..0x26C5,
            0x26CE, 0x26D4, 0x26EA, in 0x26F2..0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, in 0x270A..0x270B, 0x2728, 0x274C, 0x274E,
            in 0x2753..0x2755, 0x2757, in 0x2795..0x2797, 0x27B0, 0x27BF, in 0x2B1B..0x2B1C, 0x2B50, 0x2B55,
            in 0x2E80..0x303E, in 0x3041..0x33FF, in 0x3400..0x4DBF, in 0x4E00..0x9FFF, in 0xA000..0xA4CF, in 0xA960..0xA97F,
            in 0xAC00..0xD7A3, in 0xF900..0xFAFF, in 0xFE10..0xFE19, in 0xFE30..0xFE6F, in 0xFF00..0xFF60, in 0xFFE0..0xFFE6,
            in 0x1F004..0x1F004, 0x1F0CF, 0x1F18E, in 0x1F191..0x1F19A, in 0x1F200..0x1F251, in 0x1F300..0x1F320, in 0x1F32D..0x1F335,
            in 0x1F337..0x1F37C, in 0x1F37E..0x1F393, in 0x1F3A0..0x1F3CA, in 0x1F3CF..0x1F3D3, in 0x1F3E0..0x1F3F0, 0x1F3F4,
            in 0x1F3F8..0x1F43E, 0x1F440, in 0x1F442..0x1F4FC, in 0x1F4FF..0x1F53D, in 0x1F54B..0x1F54E, in 0x1F550..0x1F567, 0x1F57A,
            in 0x1F595..0x1F596, 0x1F5A4, in 0x1F5FB..0x1F64F, in 0x1F680..0x1F6C5, 0x1F6CC, in 0x1F6D0..0x1F6D2, in 0x1F6D5..0x1F6D7,
            in 0x1F6EB..0x1F6EC, in 0x1F6F4..0x1F6FC, in 0x1F7E0..0x1F7EB, in 0x1F90C..0x1F93A, in 0x1F93C..0x1F945, in 0x1F947..0x1F9FF,
            in 0x1FA70..0x1FAFF, in 0x20000..0x2FFFD, in 0x30000..0x3FFFD -> true
            else -> false
        }
    }
}
