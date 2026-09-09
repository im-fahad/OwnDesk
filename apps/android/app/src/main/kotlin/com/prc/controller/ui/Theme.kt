package com.prc.controller.ui

/**
 * The Mac app's palette and type scale, so the phone looks like the same product rather than a
 * different one that happens to talk to it. The values are copied from Theme.swift deliberately:
 * one place decides what PRC looks like, and this file follows it.
 */
object Theme {
    const val HEADER = 0xFF1B1B1B.toInt()
    const val SIDEBAR = 0xFF181818.toInt()
    const val CONTENT = 0xFF1F1F1F.toInt()
    const val PANEL = 0xFF1A1A1A.toInt()
    const val STATUS = 0xFF161616.toInt()
    const val BORDER = 0xFF2E2E2E.toInt()
    const val SELECTION = 0xFF04395E.toInt()

    const val TEXT = 0xFFCCCCCC.toInt()
    const val TEXT_DIM = 0xFF8B8B8B.toInt()
    const val TEXT_FAINT = 0xFF6A6A6A.toInt()

    const val ACCENT = 0xFF4D8EF7.toInt()
    const val ONLINE = 0xFF3FB950.toInt()
    const val WARN = 0xFFD29922.toInt()
    const val DANGER = 0xFFF85149.toInt()

    // Sizes follow the Mac's chrome: 13 for primary text, 12 secondary, 11 for status and fingerprints,
    // 10 for section headings.
    const val UI = 13f
    const val UI_SECONDARY = 12f
    const val UI_SMALL = 11f
    const val SECTION = 10f
    const val TITLE = 15f
    const val FINGERPRINT = 17f
}
