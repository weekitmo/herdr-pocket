package dev.maddax.herdrpocket

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicInteger

/**
 * The Storage Access Framework half of file download.
 *
 * ## Why this is hand-written instead of a package
 *
 * Downloading a build artifact means writing a file the USER chose the location
 * for, repeatedly, across app restarts, without a permission prompt — which on
 * Android 10+ is exactly `ACTION_OPEN_DOCUMENT_TREE` plus
 * `takePersistableUriPermission` plus `DocumentsContract.createDocument`. That
 * is the ~200 lines below.
 *
 * The packages that offer it (`saf_util` + `saf_stream` are the maintained
 * pair) would replace those lines with two dependencies, one of which
 * (`saf_stream`) pulls in the `jni` package and with it a JNI build layer. This
 * project already justifies each dependency in `pubspec.yaml`; a JNI toolchain
 * is a large thing to accept for a directory picker and an output stream, and
 * it is a new way for `flutter build apk` to fail.
 *
 * The other packages people reach for — `file_picker`, `file_selector` — pick a
 * directory and hand back a path or a URI, but cannot CREATE a file inside it
 * later, which is the operation this feature is entirely made of.
 *
 * ## The two rules that make this correct
 *
 * 1. **The persisted permission is the feature.** Read+write, taken on the
 *    result of the picker, or the app loses access at the next process start
 *    and the user is asked to pick the folder every time.
 * 2. **Never hold a Uri open across calls.** A session maps to an open
 *    `OutputStream`, and the Dart side is responsible for closing it — but a
 *    session that is never closed leaks a file descriptor until the process
 *    dies, so `abortWrite` exists and `onDestroy` drains whatever is left.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.maddax.herdrpocket/download_dir"
        const val PICK_DIRECTORY_REQUEST = 0x4844 // 'HD'
    }

    /** The in-flight `pickDirectory` call, held until the picker returns. */
    private var pendingPick: MethodChannel.Result? = null

    /**
     * Open output streams, keyed by the session id handed to Dart.
     *
     * An open stream IS the session. There is deliberately no buffering layer
     * here: the SSH transfer produces chunks and each one is written straight
     * through, so a 48 MB download never exists in memory at any point.
     */
    private val writers = HashMap<Int, OutputStream>()

    private val nextSession = AtomicInteger(1)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickDirectory" -> pickDirectory(result)
                "checkAccess" -> result.success(hasAccess(call.argument<String>("uri")))
                "openWrite" -> result.success(openWrite(call, result))
                "writeChunk" -> writeChunk(call, result)
                "closeWrite" -> closeWrite(call, result)
                "abortWrite" -> abortWrite(call, result)
                "exists" -> result.success(child(call)?.isFile == true)
                "delete" -> result.success(child(call)?.delete() == true)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("saf", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // ----------------------------------------------------------- picking ---

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingPick != null) {
            // Two picks at once is a UI bug, and answering the second one with
            // an error is better than dropping the first one's callback on the
            // floor, which would leave that page waiting forever.
            result.error("busy", "a directory picker is already open", null)
            return
        }
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    // Without this flag the grant dies with the process, and
                    // the whole point is that it does not.
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_DIRECTORY_REQUEST) return

        val result = pendingPick ?: return
        pendingPick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // A cancellation is a real answer, not an error: the UI shows the
            // row as unchanged and does not put up a failure message.
            result.success(null)
            return
        }

        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            // Some providers hand back a tree without offering a persistable
            // grant. Reporting that now is far better than reporting it as
            // "download failed" on the next launch.
            result.error("not_persistable", e.message, null)
            return
        }

        result.success(mapOf("uri" to uri.toString(), "label" to labelOf(uri)))
    }

    /** Whether a previously granted tree is still writable by this app. */
    private fun hasAccess(uriString: String?): Boolean {
        if (uriString == null) return false
        val uri = Uri.parse(uriString)
        return contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission
        }
    }

    /**
     * A human-readable name for the picked folder.
     *
     * Read out of the tree document id (`primary:Download/Herdr`) rather than
     * from `DocumentFile.getName()`, which reports only the last path segment
     * and comes back null for a folder picked at a storage root.
     */
    private fun labelOf(uri: Uri): String {
        val docId = runCatching {
            android.provider.DocumentsContract.getTreeDocumentId(uri)
        }.getOrNull() ?: return uri.lastPathSegment ?: ""
        // `primary:Download/Herdr` -> `Download/Herdr`. A UUID-prefixed docId
        // for a removable volume keeps its tail, which is the readable part.
        val withoutVolume = docId.substringAfter(':', docId)
        return withoutVolume.ifEmpty { docId }
    }

    // ----------------------------------------------------------- writing ---

    private fun child(call: MethodCall): DocumentFile? {
        val uri = call.argument<String>("uri") ?: return null
        val name = call.argument<String>("name") ?: return null
        return DocumentFile.fromTreeUri(this, Uri.parse(uri))?.findFile(name)
    }

    private fun openWrite(call: MethodCall, result: MethodChannel.Result): Int? {
        val uriString = call.argument<String>("uri")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (uriString == null || name == null) {
            result.error("bad_args", "openWrite needs uri and name", null)
            return null
        }

        val tree = DocumentFile.fromTreeUri(this, Uri.parse(uriString))
            ?: throw IllegalStateException("the granted directory is gone")
        if (!tree.canWrite()) {
            throw IllegalStateException("no write access to the chosen directory")
        }

        // find-then-create rather than createFile alone: `createFile` on an
        // existing name does NOT overwrite, it appends " (1)" — so downloading
        // the same artifact twice would silently produce two files.
        val target = tree.findFile(name)?.takeIf { it.isFile }
            ?: tree.createFile(mime, name)
            ?: throw IllegalStateException("could not create $name in ${tree.name}")

        // "wt" is write+truncate. Without it a re-download of a shorter file
        // leaves the tail of the previous one behind.
        val stream = contentResolver.openOutputStream(target.uri, "wt")
            ?: throw IllegalStateException("could not open $name for writing")

        val id = nextSession.getAndIncrement()
        writers[id] = stream
        return id
    }

    private fun writeChunk(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("session") ?: throw IllegalArgumentException("no session")
        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("no bytes")
        val stream = writers[id] ?: throw IllegalStateException("session $id is not open")
        stream.write(bytes)
        result.success(null)
    }

    private fun closeWrite(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("session") ?: throw IllegalArgumentException("no session")
        val stream = writers.remove(id)
        // flush-then-close matters for the same reason the truncate mode does:
        // a stream closed without flushing loses the tail, and the file LOOKS
        // complete because it exists with the right name.
        stream?.flush()
        stream?.close()
        result.success(null)
    }

    private fun abortWrite(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("session") ?: throw IllegalArgumentException("no session")
        val stream = writers.remove(id)
        runCatching { stream?.close() }
        result.success(null)
    }

    override fun onDestroy() {
        // A session the Dart side forgot (an error path, a hot restart) would
        // otherwise hold a file descriptor until the process dies.
        writers.values.forEach { runCatching { it.close() } }
        writers.clear()
        super.onDestroy()
    }
}
