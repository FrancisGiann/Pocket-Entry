package dev.giann.pocket_entry

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var initialRoute: QuickEntryPolicy.Route? = null
    private var fileResult: MethodChannel.Result? = null
    private var exportText: String? = null
    private val maxBytes = 5 * 1024 * 1024

    override fun onCreate(savedInstanceState: Bundle?) {
        val privatePreview = getSharedPreferences(QuickEntryWidget.PREFS, Context.MODE_PRIVATE).getBoolean("privatePreview", true)
        if (privatePreview) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        initialRoute = route(intent)
        consumeIntent()
    }
    private fun route(source: Intent?): QuickEntryPolicy.Route? {
        val parsed = QuickEntryPolicy.parse(source?.action, source?.dataString) ?: return null
        val widget = parsed.widgetId
        if (widget != null) {
            val ids = AppWidgetManager.getInstance(this).getAppWidgetIds(ComponentName(this, QuickEntryWidget::class.java))
            if (!ids.contains(widget)) return QuickEntryPolicy.Route(null, null)
        }
        return parsed
    }
    private fun consumeIntent() { intent?.action = Intent.ACTION_MAIN; intent?.data = null }
    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
        val entry = route(intent); consumeIntent()
        if (entry != null) channel?.invokeMethod("quickEntry", mapOf("categoryId" to entry.categoryId))
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.giann.pocket_entry/native")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "privatePath" -> { val folder = File(filesDir, "pocket_entry"); if (folder.isDirectory || folder.mkdirs()) result.success(folder.absolutePath) else result.error("storage", "Private storage is unavailable", null) }
                "initialEntry" -> { val entry = initialRoute; initialRoute = null; result.success(entry?.let { mapOf("categoryId" to it.categoryId) }) }
                "syncAppearance" -> {
                    val theme = call.argument<String>("theme") ?: "system"
                    val private = call.argument<Boolean>("privatePreview") ?: true
                    val raw = call.argument<List<Map<String, String>>>("categories") ?: emptyList()
                    if (theme !in listOf("system", "light", "dark") || raw.size > 4 || raw.any { !(it["id"] ?: "").matches(Regex("[a-zA-Z0-9_-]{1,80}")) || (it["name"] ?: "").isEmpty() || (it["name"] ?: "").length > 30 }) result.error("invalid", "Invalid widget configuration", null)
                    else {
                        val json = JSONArray(); raw.forEach { json.put(JSONObject(it)) }
                        val saved = getSharedPreferences(QuickEntryWidget.PREFS, Context.MODE_PRIVATE).edit().putString("theme", theme).putBoolean("privatePreview", private).putString("categories", json.toString()).commit()
                        if (private) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        if (saved) { QuickEntryWidget.refresh(this); result.success(null) } else result.error("storage", "Widget configuration could not be saved", null)
                    }
                }
                "pinWidget" -> {
                    val manager = getSystemService(AppWidgetManager::class.java)
                    result.success(manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(ComponentName(this, QuickEntryWidget::class.java), null, null))
                }
                "exportBackup" -> {
                    val text = call.argument<String>("text")
                    if (fileResult != null) result.error("busy", "A file choice is already open", null)
                    else if (text == null || text.toByteArray(Charsets.UTF_8).size > maxBytes) result.error("invalid", "Backup is too large", null)
                    else {
                        fileResult = result; exportText = text
                        val name = (call.argument<String>("name") ?: "Pocket Entry.json").replace(Regex("[^a-zA-Z0-9 ._-]"), "_").take(80)
                        try { startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json").putExtra(Intent.EXTRA_TITLE, name), 4101) }
                        catch (_: Exception) { finishFileError("A document picker is unavailable") }
                    }
                }
                "pickBackup" -> {
                    if (fileResult != null) result.error("busy", "A file choice is already open", null)
                    else {
                        fileResult = result
                        try { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json").putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream")), 4102) }
                        catch (_: Exception) { finishFileError("A document picker is unavailable") }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun finishFileError(message: String) {
        fileResult?.error("document", message, null); fileResult = null; exportText = null
    }
    @Deprecated("Android callback required by the document-picker bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4101 && requestCode != 4102) return
        val result = fileResult ?: return // A process restart cancels this operation safely.
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(if (requestCode == 4101) false else null); fileResult = null; exportText = null; return }
        if (uri.scheme != "content") { finishFileError("Choose a file through the document picker"); return }
        val text = exportText; fileResult = null; exportText = null
        Thread {
            try {
                if (requestCode == 4101) {
                    requireNotNull(text)
                    val stream = contentResolver.openOutputStream(uri, "wt") ?: error("File could not be opened")
                    stream.use { it.write(text.toByteArray(Charsets.UTF_8)); it.flush() }
                    runOnUiThread { result.success(true) }
                } else {
                    val stream = contentResolver.openInputStream(uri) ?: error("File could not be opened")
                    val bytes = stream.use { input ->
                        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                        while (true) { val n = input.read(buffer); if (n < 0) break; if (out.size() + n > maxBytes) error("Choose a backup smaller than 5 MB"); out.write(buffer, 0, n) }
                        out.toByteArray()
                    }
                    val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                    val decoded = decoder.decode(ByteBuffer.wrap(bytes)).toString()
                    runOnUiThread { result.success(decoded) }
                }
            } catch (_: Exception) { runOnUiThread { result.error("document", "Could not read or write this document", null) } }
        }.start()
    }
}
