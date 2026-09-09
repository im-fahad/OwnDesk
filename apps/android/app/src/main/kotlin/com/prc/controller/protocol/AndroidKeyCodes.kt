package com.prc.controller.protocol

import android.view.KeyEvent

/**
 * Android key codes to the W3C names the wire format uses. The protocol package carries the full
 * table; this is the part a phone can actually produce, which is a hardware keyboard and the few
 * keys a soft keyboard sends as events rather than as text. Printable characters travel as `text`.
 */
object AndroidKeyCodes {
    private val map: Map<Int, String> = mapOf(
        KeyEvent.KEYCODE_ENTER to "Enter",
        KeyEvent.KEYCODE_NUMPAD_ENTER to "NumpadEnter",
        KeyEvent.KEYCODE_DEL to "Backspace",
        KeyEvent.KEYCODE_FORWARD_DEL to "Delete",
        KeyEvent.KEYCODE_TAB to "Tab",
        KeyEvent.KEYCODE_ESCAPE to "Escape",
        KeyEvent.KEYCODE_SPACE to "Space",
        KeyEvent.KEYCODE_DPAD_UP to "ArrowUp",
        KeyEvent.KEYCODE_DPAD_DOWN to "ArrowDown",
        KeyEvent.KEYCODE_DPAD_LEFT to "ArrowLeft",
        KeyEvent.KEYCODE_DPAD_RIGHT to "ArrowRight",
        KeyEvent.KEYCODE_MOVE_HOME to "Home",
        KeyEvent.KEYCODE_MOVE_END to "End",
        KeyEvent.KEYCODE_PAGE_UP to "PageUp",
        KeyEvent.KEYCODE_PAGE_DOWN to "PageDown",
    )

    fun code(keyCode: Int): String? = map[keyCode]

    fun modifiers(event: KeyEvent): List<String> = buildList {
        if (event.isShiftPressed) add("shift")
        if (event.isCtrlPressed) add("control")
        if (event.isAltPressed) add("alt")
        if (event.isMetaPressed) add("meta")
    }
}
