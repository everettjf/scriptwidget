package com.everettjf.scriptwidget.core.pkg

import java.time.LocalDateTime
import java.time.ZoneId
import java.util.zip.ZipEntry

/**
 * Sets the entry's modification time to a fixed local date and time, so that exports are
 * byte-for-byte repeatable. `ZipEntry.setTimeLocal` does this but needs API 35; `setTime` takes
 * milliseconds and stores them as local DOS time, so going through the default zone gives the
 * same fields on every version the app supports.
 */
internal fun ZipEntry.setFixedLocalTime(time: LocalDateTime) {
    this.time = time.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
}
