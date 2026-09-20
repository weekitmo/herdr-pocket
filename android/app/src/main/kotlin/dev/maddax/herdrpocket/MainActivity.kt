package dev.maddax.herdrpocket

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger

/**
 * The platform half of file download and of self-update.
 *
 * THREE CHANNELS, one per concern, all hand-written:
 *
 *   `download_dir`  SAF write access to a folder the user picked. See the class
 *                   comment below.
 *   `system_proxy`  the phone's HTTP proxy, which `dart:io` does not read.
 *   `app_update`    inspecting and installing a downloaded APK.
 *
 * The second and third exist because the alternative is a package for each, and
 * the one thing that genuinely has to be Kotlin here — reading an APK's signing
 * certificate to catch an install that would fail and demand an uninstall — has
 * no package at all. Once that is written, FileProvider and
 * `canRequestPackageInstalls` are twenty more lines beside it.
 *
 * WHY THIS ACTIVITY IS A `FlutterFragmentActivity` RATHER THAN A
 * `FlutterActivity`. It is one line of inheritance that nothing here uses, and
 * it is not optional: `androidx.biometric`'s `BiometricPrompt` is hosted by a
 * `FragmentActivity`, and the app lock's fingerprint prompt is the system's own
 * dialog drawn over this activity. `local_auth_android` says so in its README;
 * the failure mode without it is a prompt that simply never appears.
 *
 * WHAT THAT COSTS: `FlutterFragmentActivity` extends `FragmentActivity`, which
 * is what `startActivityForResult` and `configureFlutterEngine` below already
 * work with — the SAF picker, the proxy reader, the APK installer and the
 * keep-alive service are unaffected. It is also the reason this class declares
 * no `android:configChanges` of its own: the manifest already does.
 */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "dev.maddax.herdrpocket/download_dir"
        const val PROXY_CHANNEL = "dev.maddax.herdrpocket/system_proxy"
        const val UPDATE_CHANNEL = "dev.maddax.herdrpocket/app_update"
        const val PICK_DIRECTORY_REQUEST = 0x4844 // 'HD'
        const val PICK_FILE_REQUEST = 0x4846 // 'HF'

        /** Log tag for everything this activity says. */
        const val TAG = "HerdrPocket"

        /** Where a file picked from this phone waits to be uploaded. */
        const val PICKED_DIR = "picked"

        /** Read size for the picked-file copy. */
        const val COPY_CHUNK = 64 * 1024

        /** Where downloaded APKs wait. Mirrors `res/xml/update_paths.xml`. */
        const val UPDATE_DIR = "updates"

        /** What the system installer is told the content is. */
        const val APK_MIME = "application/vnd.android.package-archive"
    }

    /** The in-flight `pickDirectory` call, held until the picker returns. */
    private var pendingPick: MethodChannel.Result? = null

    /** The in-flight `pickFile` call, and the size cap Dart asked for. */
    private var pendingFilePick: MethodChannel.Result? = null
    private var pendingFileMax: Int = 0

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROXY_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "getProxy") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(readProxy())
                } catch (t: Throwable) {
                    // Never an error: "this phone has no proxy" and "we could
                    // not read it" lead to the same behaviour — a direct
                    // connection — and a failed update check is a much worse
                    // way to learn about a missing permission. LOGGED, though:
                    // a silent catch here once turned a working proxy into
                    // "no proxy at all" and there was nothing anywhere saying
                    // why.
                    Log.w(TAG, "reading the system proxy failed", t)
                    result.success(null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result -> handleUpdate(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KeepAliveService.CHANNEL)
            .setMethodCallHandler { call, result -> handleKeepAlive(call, result) }
    }

    // ---------------------------------------------------------- keep alive ---
    //
    // Tiny on purpose: whether the service SHOULD be running is a decision about
    // connection state, and that state lives in Dart (`keep_alive.dart` is the
    // policy). This half only does the two things Dart cannot do — start and
    // stop a foreground service.

    private fun handleKeepAlive(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: return result.error(
                        "bad_args",
                        "start needs a title",
                        null,
                    )
                    val text = call.argument<String>("text") ?: ""
                    KeepAliveService.start(this, title, text)
                    result.success(null)
                }
                "stop" -> {
                    KeepAliveService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Reported rather than swallowed: the two ways this fails are
            // "the user turned the notification permission off" and "the OEM
            // forbids background starts", and both leave the app working — just
            // without the keep-alive — which the settings row should be able to
            // admit instead of showing a switch that lies.
            result.error("keep_alive", t.message ?: t.javaClass.simpleName, null)
        }
    }

    // --------------------------------------------------------- file download ---
    //
    // ## Why the SAF half is hand-written instead of a package
    //
    // Downloading a file to a folder the USER chose, repeatedly, across app
    // restarts, without a permission prompt — on Android 10+ that is exactly
    // `ACTION_OPEN_DOCUMENT_TREE` plus `takePersistableUriPermission` plus
    // `DocumentsContract.createDocument`.
    //
    // The packages that offer it (`saf_util` + `saf_stream` are the maintained
    // pair) would replace those lines with two dependencies, one of which
    // (`saf_stream`) pulls in the `jni` package and with it a JNI build layer.
    // The other packages people reach for — `file_picker`, `file_selector` —
    // pick a directory and hand back a path or a URI, but cannot CREATE a file
    // inside it later, which is the operation this feature is entirely made of.
    //
    // ## The two rules that make it correct
    //
    // 1. **The persisted permission is the feature.** Read+write, taken on the
    //    result of the picker, or the app loses access at the next process
    //    start and the user is asked to pick the folder every time.
    // 2. **Never hold a Uri open across calls.** A session maps to an open
    //    `OutputStream`, and the Dart side is responsible for closing it — but
    //    a session that is never closed leaks a file descriptor until the
    //    process dies, so `abortWrite` exists and `onDestroy` drains whatever
    //    is left.

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickDirectory" -> pickDirectory(result)
                "pickFile" -> pickFile(call.argument<Int>("maxBytes") ?: 0, result)
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
        if (requestCode == PICK_FILE_REQUEST) {
            finishPickFile(resultCode, data)
            return
        }
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

    // ------------------------------------------------------- picking a file ---
    //
    // The composer's `+` needs a file from THIS PHONE, which is a different
    // question from the download directory: nothing is persisted, and the answer
    // is bytes rather than a grant. So this one copies the picked document into
    // the app's cache and hands back a real path, which keeps the whole read
    // protocol out of the MethodChannel — no openRead/readChunk/closeRead to get
    // wrong, and Dart can use `File` like it would for any other local file.
    //
    // The copy is BOUNDED and it happens OFF the main thread: a document picker
    // will happily return a 4 GB video, and a phone that freezes while copying
    // one into its own cache is a worse outcome than a refusal.

    private fun pickFile(maxBytes: Int, result: MethodChannel.Result) {
        if (pendingFilePick != null) {
            result.error("busy", "a file picker is already open", null)
            return
        }
        pendingFilePick = result
        pendingFileMax = maxBytes

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Everything, and the size limit is enforced while reading rather
            // than by narrowing the picker: a picker that greys out the file the
            // user means is a worse explanation than "that one is too big".
            type = "*/*"
        }
        startActivityForResult(intent, PICK_FILE_REQUEST)
    }

    private fun finishPickFile(resultCode: Int, data: Intent?) {
        val result = pendingFilePick ?: return
        pendingFilePick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // A cancellation is an answer, not a failure: the composer stays as
            // it was and puts up no error.
            result.success(null)
            return
        }

        val max = pendingFileMax
        Thread {
            val answer = runCatching { copyPickedFile(uri, max) }
            // `Result` must be answered on the thread the channel was created on.
            runOnUiThread {
                answer.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { failure ->
                        val code = if (failure is PickedFileTooLarge) "too_large" else "pick"
                        result.error(code, failure.message ?: "", null)
                    },
                )
            }
        }.start()
    }

    /** Raised when the picked document is past the cap Dart asked for. */
    private class PickedFileTooLarge : Exception("the file is larger than the limit")

    /**
     * Copies the picked document into the cache and reports where it landed.
     *
     * The cache rather than `filesDir`, because the file is a one-shot: it is
     * uploaded and then worthless, and the system is welcome to reclaim it. The
     * name is derived from the document id, so picking the same file twice
     * REPLACES it instead of growing the cache by a screenshot each time.
     */
    private fun copyPickedFile(uri: Uri, maxBytes: Int): Map<String, Any?> {
        val displayName = displayNameOf(uri)
        val directory = File(cacheDir, PICKED_DIR).apply { mkdirs() }
        val target = File(directory, "${uri.toString().hashCode().toUInt()}-${safeName(displayName)}")

        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("the picker returned an unreadable file")
        var total = 0L
        input.use { source ->
            target.outputStream().use { sink ->
                val buffer = ByteArray(COPY_CHUNK)
                while (true) {
                    val read = source.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (maxBytes > 0 && total > maxBytes) throw PickedFileTooLarge()
                    sink.write(buffer, 0, read)
                }
            }
        }

        return mapOf(
            "path" to target.absolutePath,
            "name" to displayName,
            "size" to total,
        )
    }

    /** The file's own name, or the URI's tail when the provider will not say. */
    private fun displayNameOf(uri: Uri): String {
        val cursor = runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        }.getOrNull()
        cursor?.use {
            if (it.moveToFirst()) {
                val name = it.getString(0)
                if (!name.isNullOrBlank()) return name
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    }

    /**
     * A name the filesystem will accept.
     *
     * A display name is whatever the provider says it is — it can carry a slash,
     * a newline or a NUL — and it is about to become a path component.
     */
    private fun safeName(name: String): String {
        val cleaned = name.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.')
        if (cleaned.isEmpty()) return "file"
        return if (cleaned.length <= 80) cleaned else cleaned.takeLast(80)
    }

    /** Whether a previously granted tree is still writable by this app. */    private fun hasAccess(uriString: String?): Boolean {
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

    // --------------------------------------------------------- system proxy ---

    /**
     * The phone's HTTP proxy, in the shape `SystemProxy.fromChannel` reads.
     *
     * `ConnectivityManager.getDefaultProxy()` is the modern answer (API 23+):
     * the global proxy if one is set, otherwise the proxy of the network this
     * process is bound to, otherwise the default network's. `LinkProperties` is
     * the same information reached a different way, for the versions and OEM
     * builds where the first call comes back empty.
     *
     * Null means "no proxy", which is the common case — including every phone
     * whose proxy is a VPN in tun mode, where the routing happens below the
     * socket layer and there is nothing for an app to configure.
     */
    private fun readProxy(): Map<String, Any?>? {
        val info = proxyInfo() ?: return null
        // EACH FIELD ON ITS OWN, because a getter that throws takes the whole
        // reading with it and the result of that is not a warning — it is a
        // download that quietly bypasses the proxy the user configured. The
        // host and port are the ones that matter; the rest are decoration and
        // degrade to empty.
        return mapOf(
            "host" to (runCatching { info.host }.getOrNull() ?: ""),
            "port" to runCatching { info.port }.getOrDefault(-1),
            "pacUrl" to (runCatching { info.pacFileUrl?.toString() }.getOrNull() ?: ""),
            // TO A LIST, because `getExclusionList()` returns a Java
            // `String[]` and Flutter's StandardMessageCodec cannot encode an
            // array — `result.success(map)` throws IllegalArgumentException
            // ("Unsupported value: [Ljava.lang.String;"), the whole reading is
            // lost, and the app then reports "this phone has no proxy" while
            // the phone demonstrably has one. Found on the emulator, where the
            // symptom was a download that ignored a proxy it had read correctly
            // two lines earlier.
            "exclusions" to runCatching { info.exclusionList?.toList() }
                .getOrNull()
                .orEmpty(),
        )
    }

    private fun proxyInfo(): ProxyInfo? {
        val manager = runCatching {
            getSystemService(ConnectivityManager::class.java)
        }.getOrNull() ?: return null

        // API 23+: the global proxy, or the bound network's, or the default
        // network's — one call, and the documented meaning of all three.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val fromDefault = runCatching { manager.defaultProxy }
                .onFailure { Log.w(TAG, "getDefaultProxy() failed", it) }
                .getOrNull()
            if (fromDefault != null) return fromDefault
        }

        // The same information reached a different way. Worth the second try:
        // OEM builds have been known to answer the first call with null.
        val network = runCatching { manager.activeNetwork }.getOrNull() ?: return null
        return runCatching { manager.getLinkProperties(network)?.httpProxy }
            .onFailure { Log.w(TAG, "getLinkProperties() failed", it) }
            .getOrNull()
    }

    // ------------------------------------------------------------ the update ---

    private fun handleUpdate(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "stagingDirectory" -> result.success(stagingDirectory())
                "canInstall" -> result.success(canInstallPackages())
                "openInstallSettings" -> openInstallSettings(result)
                "inspect" -> result.success(inspect(call))
                "install" -> install(call, result)
                "openUrl" -> openUrl(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("update", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Where the Dart side writes a downloaded APK. Mirrors `update_paths.xml`. */
    private fun stagingDirectory(): String {
        val dir = File(filesDir, UPDATE_DIR)
        dir.mkdirs()
        return dir.absolutePath
    }

    /**
     * Whether the system will let this app hand an APK to the installer.
     *
     * Before Android 8 this is not a per-app switch at all — there is one
     * global "unknown sources" setting — so the honest answer there is yes and
     * the installer decides.
     */
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null)
            return
        }
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
        result.success(null)
    }

    private fun inspect(call: MethodCall): Map<String, Any?> {
        val file = fileFrom(call) ?: return mapOf("readable" to false)
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, archiveFlags())
            ?: return mapOf("readable" to false)
        return mapOf(
            "readable" to true,
            "packageName" to archive.packageName,
            "versionCode" to versionCodeOf(archive),
            "signatureMatches" to signaturesMatch(archive),
        )
    }

    private fun install(call: MethodCall, result: MethodChannel.Result) {
        val file = fileFrom(call)
        if (file == null) {
            result.error("file_missing", "no APK at ${call.argument<String>("path")}", null)
            return
        }
        if (!canInstallPackages()) {
            result.error("install_blocked", "this app may not install packages yet", null)
            return
        }

        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            // The grant is what lets the INSTALLER read a file it has no other
            // way to reach. It lasts for this intent and no longer — which is
            // also why the APK is never made world-readable.
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        result.success(null)
    }

    private fun openUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("bad_args", "openUrl needs url", null)
            return
        }
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        result.success(null)
    }

    private fun fileFrom(call: MethodCall): File? {
        val path = call.argument<String>("path") ?: return null
        val file = File(path)
        return if (file.isFile) file else null
    }

    private fun archiveFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    /**
     * Whether this APK could replace the installed app.
     *
     * THE CHECK THAT EARNS ITS KEEP. Installing over an app signed with a
     * different key fails with "app not installed" and no way forward except
     * uninstalling — which deletes the user's saved machines and SSH
     * credentials. Anyone who builds this app locally (debug key) while also
     * installing the released APK (release key) hits exactly that, and the
     * installer never says why.
     *
     * UNKNOWN MEANS YES. If either side's certificates cannot be read, this
     * reports a match and lets the system do what it would have done anyway: a
     * false "the signatures differ" would block a legitimate update with a
     * warning about losing data, which is far worse than the failure it
     * predicts.
     */
    private fun signaturesMatch(archive: PackageInfo): Boolean {
        val theirs = signerDigests(archive)
        val ours = runCatching {
            signerDigests(packageManager.getPackageInfo(packageName, archiveFlags()))
        }.getOrNull() ?: emptySet()
        if (theirs.isEmpty() || ours.isEmpty()) return true
        // Every signer of the installed app must also sign the APK — that is
        // what the platform requires for an in-place upgrade.
        return theirs.containsAll(ours)
    }

    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // `apkContentsSigners` is the set that signs THIS file. The history
            // in `signingCertificateHistory` is about key rotation, which this
            // app does not do and must not be compared as if it did.
            info.signingInfo?.apkContentsSigners ?: return emptySet()
        } else {
            @Suppress("DEPRECATION")
            info.signatures ?: return emptySet()
        }
        return signatures.mapTo(HashSet()) { sha256(it.toByteArray()) }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    override fun onDestroy() {
        // A session the Dart side forgot (an error path, a hot restart) would
        // otherwise hold a file descriptor until the process dies.
        writers.values.forEach { runCatching { it.close() } }
        writers.clear()
        super.onDestroy()
    }
}
