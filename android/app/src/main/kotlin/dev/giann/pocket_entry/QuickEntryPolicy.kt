package dev.giann.pocket_entry

import java.net.URI

/** Links can open a draft, never select a wallet, enter an amount, or write data. */
object QuickEntryPolicy {
    const val ACTION = "dev.giann.pocket_entry.QUICK_ADD"
    data class Route(val categoryId: String?, val widgetId: Int?)
    fun parse(action: String?, rawUri: String?): Route? {
        if (action != ACTION) return null
        if (rawUri == null) return Route(null, null)
        return try {
            val uri = URI(rawUri)
            if (uri.scheme != "pocketentry" || uri.host != "quick" || uri.port != -1 || uri.userInfo != null || uri.fragment != null) return null
            val id = uri.path?.removePrefix("/")?.takeIf { it.matches(Regex("[a-zA-Z0-9_-]{1,80}")) } ?: return null
            val widget = uri.rawQuery?.let {
                if (!it.matches(Regex("widget=[0-9]{1,10}"))) return null
                it.removePrefix("widget=").toIntOrNull()?.takeIf { n -> n > 0 } ?: return null
            }
            Route(id, widget)
        } catch (_: Exception) { null }
    }
}
