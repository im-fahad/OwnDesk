package io.github.im_fahad.owndesk.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalEmulatorTest {
    private class Recorder : TerminalEmulator.Listener {
        val responses = mutableListOf<String>()
        var title: String? = null
        var clipboard: String? = null
        var bells = 0
        override fun respond(bytes: ByteArray) { responses += String(bytes, Charsets.UTF_8) }
        override fun titleChanged(title: String) { this.title = title }
        override fun bell() { bells++ }
        override fun clipboardSet(text: String) { clipboard = text }
    }

    private fun terminal(cols: Int = 10, rows: Int = 4, scrollback: Int = 100): Pair<TerminalEmulator, Recorder> {
        val recorder = Recorder()
        return TerminalEmulator(cols, rows, scrollback, recorder) to recorder
    }

    private fun TerminalEmulator.feed(text: String) = write(text.toByteArray(Charsets.UTF_8))
    private fun TerminalEmulator.row(i: Int, offset: Int = 0) = line(i, offset).text()
    private fun TerminalEmulator.rows(): List<String> = (0 until rows).map { row(it) }

    @Test
    fun `prints text and wraps at the right edge only when the next character comes`() {
        val (t, _) = terminal(cols = 5)
        t.feed("abcde")
        assertEquals("abcde", t.row(0))
        assertEquals(0, t.cursorRow)
        assertEquals(4, t.cursorCol)
        t.feed("fg")
        assertEquals(listOf("abcde", "fg", "", ""), t.rows())
        assertTrue(t.line(0).wrapped)
        assertEquals(1, t.cursorRow)
        assertEquals(2, t.cursorCol)
    }

    @Test
    fun `carriage return, line feed, backspace and tab move the cursor`() {
        val (t, _) = terminal(cols = 20)
        t.feed("ab\r\ncd")
        assertEquals(listOf("ab", "cd", "", ""), t.rows())
        t.feed("\b\bX")
        assertEquals("Xd", t.row(1))
        t.feed("\r\n\tT")
        assertEquals(9, t.cursorCol)
        assertEquals("T", t.row(2).trim())
        assertEquals(8, t.row(2).indexOf('T'))
    }

    @Test
    fun `absolute and relative cursor movement`() {
        val (t, _) = terminal()
        t.feed("\u001b[3;4H")
        assertEquals(2, t.cursorRow)
        assertEquals(3, t.cursorCol)
        t.feed("\u001b[A\u001b[2C\u001b[D")
        assertEquals(1, t.cursorRow)
        assertEquals(4, t.cursorCol)
        t.feed("\u001b[99B\u001b[99C")
        assertEquals(3, t.cursorRow)
        assertEquals(9, t.cursorCol)
        t.feed("\u001b[5G\u001b[2d")
        assertEquals(1, t.cursorRow)
        assertEquals(4, t.cursorCol)
    }

    @Test
    fun `erase in line and in display`() {
        val (t, _) = terminal(cols = 6)
        t.feed("aaaaaa\r\nbbbbbb\r\ncccccc\r\ndddddd")
        t.feed("\u001b[2;3H\u001b[K")
        assertEquals("bb", t.row(1))
        t.feed("\u001b[3;3H\u001b[1K")
        assertEquals("   ccc", t.row(2))
        t.feed("\u001b[2;2H\u001b[J")
        assertEquals(listOf("aaaaaa", "b", "", ""), t.rows())
        t.feed("\u001b[2J")
        assertEquals(listOf("", "", "", ""), t.rows())
        assertEquals(1, t.cursorRow)
    }

    @Test
    fun `colours and attributes land on the cells`() {
        val (t, _) = terminal()
        t.feed("\u001b[1;31mA\u001b[0m\u001b[38;5;200mB\u001b[48;2;10;20;30mC\u001b[38:2::1:2:3mD\u001b[0m")
        val line = t.line(0)
        assertEquals(Colour.palette(1), line.fg[0])
        assertEquals(Attr.BOLD, line.attrs[0])
        assertEquals(Colour.palette(200), line.fg[1])
        assertEquals(0, line.attrs[1])
        assertEquals(Colour.rgb(10, 20, 30), line.bg[2])
        assertEquals(Colour.rgb(1, 2, 3), line.fg[3])
        assertEquals(Colour.rgb(10, 20, 30), line.bg[3])
        t.feed("\u001b[4;7;9mE\u001b[24;27;29mF")
        assertEquals(Attr.UNDERLINE or Attr.INVERSE or Attr.STRIKE, t.line(0).attrs[4])
        assertEquals(0, t.line(0).attrs[5])
    }

    @Test
    fun `erasing keeps the current background colour`() {
        val (t, _) = terminal(cols = 4)
        t.feed("\u001b[44m\u001b[2J")
        assertEquals(Colour.palette(4), t.line(3).bg[3])
        assertEquals(0, t.line(3).codes[3])
    }

    @Test
    fun `scrolling at the bottom pushes lines into the scrollback`() {
        val (t, _) = terminal(cols = 3, rows = 2)
        t.feed("1\r\n2\r\n3\r\n4")
        assertEquals(listOf("3", "4"), t.rows())
        assertEquals(2, t.scrollback.size)
        assertEquals("1", t.row(0, offset = 2))
        assertEquals("2", t.row(1, offset = 2))
        assertEquals("2", t.row(0, offset = 1))
        assertEquals("3", t.row(1, offset = 1))
    }

    @Test
    fun `scrollback is capped`() {
        val (t, _) = terminal(cols = 3, rows = 2, scrollback = 3)
        for (i in 1..10) t.feed("$i\r\n")
        assertEquals(3, t.scrollback.size)
        assertEquals("7", t.scrollback.first().text())
        assertEquals(listOf("10", ""), t.rows())
    }

    @Test
    fun `a scrolling region scrolls only itself and keeps nothing`() {
        val (t, _) = terminal(cols = 3, rows = 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.feed("\u001b[2;3r")
        assertEquals(0, t.cursorRow)
        t.feed("\u001b[3;1H\nX")
        assertEquals(listOf("a", "c", "X", "d"), t.rows())
        assertEquals(0, t.scrollback.size)
        t.feed("\u001b[2;1H\u001bM")
        assertEquals(listOf("a", "", "c", "d"), t.rows())
        t.feed("\u001b[r")
        t.feed("\u001b[4;1H\n")
        assertEquals(listOf("", "c", "d", ""), t.rows())
    }

    @Test
    fun `insert and delete lines work inside the region`() {
        val (t, _) = terminal(cols = 3, rows = 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.feed("\u001b[2;1H\u001b[L")
        assertEquals(listOf("a", "", "b", "c"), t.rows())
        t.feed("\u001b[2M")
        assertEquals(listOf("a", "c", "", ""), t.rows())
    }

    @Test
    fun `insert, delete and erase characters`() {
        val (t, _) = terminal(cols = 6)
        t.feed("abcdef")
        t.feed("\u001b[1;2H\u001b[2@")
        assertEquals("a  bcd", t.row(0))
        t.feed("\u001b[2P")
        assertEquals("abcd", t.row(0))
        t.feed("\u001b[2X")
        assertEquals("a  d", t.row(0))
        t.feed("\u001b[4h\u001b[1;1HZ")
        assertEquals("Za  d", t.row(0))
    }

    @Test
    fun `the alternate screen comes back to what was there`() {
        val (t, _) = terminal(cols = 5)
        t.feed("main\u001b[2;2H")
        t.feed("\u001b[?1049h")
        assertTrue(t.altActive)
        assertEquals(listOf("", "", "", ""), t.rows())
        assertEquals(0, t.cursorRow)
        t.feed("full")
        assertEquals("full", t.row(0))
        t.feed("\u001b[?1049l")
        assertFalse(t.altActive)
        assertEquals("main", t.row(0))
        assertEquals(1, t.cursorRow)
        assertEquals(1, t.cursorCol)
    }

    @Test
    fun `save and restore cursor with attributes`() {
        val (t, _) = terminal()
        t.feed("\u001b[2;3H\u001b[1m\u001b7\u001b[0m\u001b[H\u001b8X")
        assertEquals(1, t.cursorRow)
        assertEquals(Attr.BOLD, t.line(1).attrs[2])
    }

    @Test
    fun `queries are answered`() {
        val (t, r) = terminal()
        t.feed("\u001b[2;5H\u001b[6n")
        assertEquals("\u001b[2;5R", r.responses.last())
        t.feed("\u001b[c")
        assertTrue(r.responses.last().startsWith("\u001b[?62;"))
        t.feed("\u001b[>c")
        assertEquals("\u001b[>0;276;0c", r.responses.last())
        t.feed("\u001b[18t")
        assertEquals("\u001b[8;4;10t", r.responses.last())
        t.feed("\u001b[5n")
        assertEquals("\u001b[0n", r.responses.last())
    }

    @Test
    fun `modes the keyboard needs to know about`() {
        val (t, _) = terminal()
        assertFalse(t.applicationCursorKeys)
        assertFalse(t.bracketedPaste)
        t.feed("\u001b[?1h\u001b[?2004h\u001b[?25l")
        assertTrue(t.applicationCursorKeys)
        assertTrue(t.bracketedPaste)
        assertFalse(t.cursorVisible)
        t.feed("\u001b[?1l\u001b[?2004l\u001b[?25h")
        assertFalse(t.applicationCursorKeys)
        assertFalse(t.bracketedPaste)
        assertTrue(t.cursorVisible)
    }

    @Test
    fun `titles and the clipboard come through OSC`() {
        val (t, r) = terminal()
        t.feed("\u001b]2;hello there\u0007")
        assertEquals("hello there", r.title)
        t.feed("\u001b]0;other\u001b\\")
        assertEquals("other", r.title)
        t.feed("\u001b]52;c;aGkgdGhlcmU=\u0007")
        assertEquals("hi there", r.clipboard)
        t.feed("\u001b]1;icon\u0007x")
        assertEquals("x", t.row(0))
    }

    @Test
    fun `utf-8 split across writes and wide characters`() {
        val (t, _) = terminal(cols = 6)
        val bytes = "a漢b".toByteArray(Charsets.UTF_8)
        t.write(bytes.copyOfRange(0, 2), 2)
        t.write(bytes.copyOfRange(2, bytes.size), bytes.size - 2)
        val line = t.line(0)
        assertEquals('a'.code, line.codes[0])
        assertEquals('漢'.code, line.codes[1])
        assertEquals(Attr.WIDE, line.attrs[1])
        assertEquals(Attr.WIDE_TRAIL, line.attrs[2])
        assertEquals('b'.code, line.codes[3])
        assertEquals("a漢b", line.text())
        // Overwriting half of a wide character blanks the other half.
        t.feed("\u001b[1;3HZ")
        assertEquals(0, t.line(0).codes[1])
        assertEquals(0, t.line(0).attrs[1])
        assertEquals("a Zb", t.row(0))
    }

    @Test
    fun `a wide character at the last column wraps whole`() {
        val (t, _) = terminal(cols = 4)
        t.feed("abc漢")
        assertEquals("abc", t.row(0))
        assertEquals("漢", t.row(1))
        assertEquals(2, t.cursorCol)
    }

    @Test
    fun `combining marks attach to the character before them`() {
        val (t, _) = terminal()
        t.feed("éx")
        assertEquals("éx", t.line(0).text())
        assertEquals(2, t.cursorCol)
        assertEquals(0, TerminalEmulator.charWidth(0x0301))
        assertEquals(2, TerminalEmulator.charWidth(0x1F600))
        assertEquals(1, TerminalEmulator.charWidth('a'.code))
    }

    @Test
    fun `line drawing charset maps box characters`() {
        val (t, _) = terminal()
        t.feed("\u001b(0lqk\u001b(Bx")
        assertEquals("┌─┐x", t.row(0))
        t.feed("\r\n\u000eq\u000fq")
        assertEquals("qq", t.row(1))
    }

    @Test
    fun `autowrap off keeps writing in the last column`() {
        val (t, _) = terminal(cols = 3)
        t.feed("\u001b[?7labcdef")
        assertEquals("abf", t.row(0))
        assertEquals(0, t.line(0).wrapped.compareTo(false))
    }

    @Test
    fun `tabs can be set and cleared`() {
        val (t, _) = terminal(cols = 20)
        t.feed("\u001b[3g\u001b[1;5H\u001bH\u001b[1;1H\tX")
        assertEquals(4, t.row(0).indexOf('X'))
        t.feed("\r\u001b[Z")
        assertEquals(0, t.cursorCol)
    }

    @Test
    fun `repeat and reverse index`() {
        val (t, _) = terminal(cols = 8)
        t.feed("ab\u001b[3b")
        assertEquals("abbbb", t.row(0))
        t.feed("\u001bM\u001bMz")
        assertEquals("     z", t.row(0))
        assertEquals("", t.row(1))
        assertEquals("abbbb", t.row(2))
    }

    @Test
    fun `shrinking rows moves the top into the scrollback and growing takes it back`() {
        val (t, _) = terminal(cols = 5, rows = 4)
        t.feed("1\r\n2\r\n3\r\n4")
        assertEquals(3, t.cursorRow)
        t.resize(5, 2)
        assertEquals(listOf("3", "4"), t.rows())
        assertEquals(2, t.scrollback.size)
        assertEquals(1, t.cursorRow)
        t.resize(5, 4)
        assertEquals(listOf("1", "2", "3", "4"), t.rows())
        assertEquals(0, t.scrollback.size)
        assertEquals(3, t.cursorRow)
    }

    @Test
    fun `shrinking rows drops blank lines below the cursor first`() {
        val (t, _) = terminal(cols = 5, rows = 4)
        t.feed("1\r\n2")
        t.resize(5, 2)
        assertEquals(listOf("1", "2"), t.rows())
        assertEquals(0, t.scrollback.size)
        assertEquals(1, t.cursorRow)
    }

    @Test
    fun `changing columns keeps the text and clamps the cursor`() {
        val (t, _) = terminal(cols = 6, rows = 2)
        t.feed("abcdef")
        t.resize(3, 2)
        assertEquals("abc", t.row(0))
        assertEquals(2, t.cursorCol)
        t.resize(8, 2)
        assertEquals("abc", t.row(0))
        t.feed("\u001b[1;9H")
        assertEquals(7, t.cursorCol)
    }

    @Test
    fun `reset starts over`() {
        val (t, r) = terminal(cols = 3, rows = 2)
        t.feed("1\r\n2\r\n3\u001b[?1h\u001b[1m")
        t.feed("\u001bc")
        assertEquals(listOf("", ""), t.rows())
        assertEquals(0, t.scrollback.size)
        assertFalse(t.applicationCursorKeys)
        t.feed("x")
        assertEquals(0, t.line(0).attrs[0])
        assertEquals(0, r.bells)
        t.feed("\u0007")
        assertEquals(1, r.bells)
    }

    @Test
    fun `unknown and malformed sequences are skipped without harm`() {
        val (t, _) = terminal()
        t.feed("\u001b[?9999h\u001b[99;99;99z\u001bP1;2q...\u001b\\\u001b_apc\u0007\u001b[=zX\u001b[38;2mY")
        assertEquals("XY", t.row(0))
        t.feed("\u001b[")
        t.feed("1;1H!")
        assertEquals("!Y", t.row(0))
        assertNull(null)
    }

    @Test
    fun `screen text joins rows`() {
        val (t, _) = terminal(cols = 4, rows = 3)
        t.feed("ab\r\n\r\ncd")
        assertEquals("ab\n\ncd", t.screenText())
    }
}
