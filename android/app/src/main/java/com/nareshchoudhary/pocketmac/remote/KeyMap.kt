package com.nareshchoudhary.pocketmac.remote

import android.view.KeyEvent

object ModifierFlag {
    const val SHIFT = 0x20000
    const val CONTROL = 0x40000
    const val OPTION = 0x80000
    const val COMMAND = 0x100000
}

/** macOS virtual key codes (US ANSI layout). */
object KeyMap {
    const val RETURN = 36
    const val TAB = 48
    const val SPACE = 49
    const val DELETE = 51
    const val ESCAPE = 53
    const val FORWARD_DELETE = 117
    const val LEFT = 123
    const val RIGHT = 124
    const val DOWN = 125
    const val UP = 126
    const val HOME = 115
    const val END = 119
    const val PAGE_UP = 116
    const val PAGE_DOWN = 121
    val FUNCTION_KEYS = intArrayOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111)

    private val codes: Map<Char, Int> = mapOf(
        'a' to 0, 's' to 1, 'd' to 2, 'f' to 3, 'h' to 4, 'g' to 5, 'z' to 6, 'x' to 7, 'c' to 8, 'v' to 9, 'b' to 11, 'q' to 12,
        'w' to 13, 'e' to 14, 'r' to 15, 'y' to 16, 't' to 17, '1' to 18, '2' to 19, '3' to 20, '4' to 21, '6' to 22, '5' to 23,
        '=' to 24, '9' to 25, '7' to 26, '-' to 27, '8' to 28, '0' to 29, ']' to 30, 'o' to 31, 'u' to 32, '[' to 33, 'i' to 34,
        'p' to 35, 'l' to 37, 'j' to 38, '\'' to 39, 'k' to 40, ';' to 41, '\\' to 42, ',' to 43, '/' to 44, 'n' to 45, 'm' to 46,
        '.' to 47, '`' to 50, ' ' to 49,
    )
    private val shifted: Map<Char, Char> = mapOf(
        '!' to '1', '@' to '2', '#' to '3', '$' to '4', '%' to '5', '^' to '6', '&' to '7', '*' to '8', '(' to '9', ')' to '0',
        '_' to '-', '+' to '=', '{' to '[', '}' to ']', '|' to '\\', ':' to ';', '"' to '\'', '<' to ',', '>' to '.', '?' to '/', '~' to '`',
    )

    /** Key code and whether Shift is implied (e.g. 'A', '?'). */
    fun code(ch: Char): Pair<Int, Boolean>? {
        codes[ch]?.let { return it to false }
        shifted[ch]?.let { base -> codes[base]?.let { return it to true } }
        val lower = ch.lowercaseChar()
        if (lower != ch) codes[lower]?.let { return it to true }
        return null
    }

    /** Android key code → Mac key code, for hardware keyboards and the keys soft keyboards send as events. */
    fun fromAndroid(keyCode: Int): Int? = when (keyCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> codes['a' + (keyCode - KeyEvent.KEYCODE_A)]
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> codes['0' + (keyCode - KeyEvent.KEYCODE_0)]
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> FUNCTION_KEYS[keyCode - KeyEvent.KEYCODE_F1]
        KeyEvent.KEYCODE_EQUALS -> 24
        KeyEvent.KEYCODE_MINUS -> 27
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 30
        KeyEvent.KEYCODE_LEFT_BRACKET -> 33
        KeyEvent.KEYCODE_APOSTROPHE -> 39
        KeyEvent.KEYCODE_SEMICOLON -> 41
        KeyEvent.KEYCODE_BACKSLASH -> 42
        KeyEvent.KEYCODE_COMMA -> 43
        KeyEvent.KEYCODE_SLASH -> 44
        KeyEvent.KEYCODE_PERIOD -> 47
        KeyEvent.KEYCODE_GRAVE -> 50
        KeyEvent.KEYCODE_SPACE -> SPACE
        KeyEvent.KEYCODE_ENTER -> RETURN
        KeyEvent.KEYCODE_NUMPAD_ENTER -> 76
        KeyEvent.KEYCODE_TAB -> TAB
        KeyEvent.KEYCODE_DEL -> DELETE
        KeyEvent.KEYCODE_FORWARD_DEL -> FORWARD_DELETE
        KeyEvent.KEYCODE_ESCAPE -> ESCAPE
        KeyEvent.KEYCODE_DPAD_LEFT -> LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> RIGHT
        KeyEvent.KEYCODE_DPAD_DOWN -> DOWN
        KeyEvent.KEYCODE_DPAD_UP -> UP
        KeyEvent.KEYCODE_MOVE_HOME -> HOME
        KeyEvent.KEYCODE_MOVE_END -> END
        KeyEvent.KEYCODE_PAGE_UP -> PAGE_UP
        KeyEvent.KEYCODE_PAGE_DOWN -> PAGE_DOWN
        KeyEvent.KEYCODE_SHIFT_LEFT -> 56
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 60
        KeyEvent.KEYCODE_CTRL_LEFT -> 59
        KeyEvent.KEYCODE_CTRL_RIGHT -> 62
        KeyEvent.KEYCODE_ALT_LEFT -> 58
        KeyEvent.KEYCODE_ALT_RIGHT -> 61
        KeyEvent.KEYCODE_META_LEFT -> 55
        KeyEvent.KEYCODE_META_RIGHT -> 54
        KeyEvent.KEYCODE_CAPS_LOCK -> 57
        else -> null
    }

    fun flags(e: KeyEvent): Int {
        var f = 0
        if (e.isShiftPressed) f = f or ModifierFlag.SHIFT
        if (e.isCtrlPressed) f = f or ModifierFlag.CONTROL
        if (e.isAltPressed) f = f or ModifierFlag.OPTION
        if (e.isMetaPressed) f = f or ModifierFlag.COMMAND
        return f
    }
}
