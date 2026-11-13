package com.pkri.sticko

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val CHANNEL = "com.pkri.sticko/stickers"
        private const val NOTIFICATION_CHANNEL = "com.pkri.sticko/update_notifications"
        private const val UPDATE_CHANNEL_ID = "sticko_apk_updates"
        private const val UPDATE_NOTIFICATION_ID = 2026
        private const val ADD_PACK_REQUEST_CODE = 200

        private const val EXTRA_STICKER_PACK_ID = "sticker_pack_id"
        private const val EXTRA_STICKER_PACK_AUTHORITY = "sticker_pack_authority"
        private const val EXTRA_STICKER_PACK_NAME = "sticker_pack_name"
        private const val ACTION_ENABLE_STICKER_PACK = "com.whatsapp.intent.action.ENABLE_STICKER_PACK"

        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
        private const val WHITELIST_PROVIDER_SUFFIX = ".provider.sticker_whitelist_check"

        private val ALL_WHATSAPP_PACKAGES = listOf(
            WHATSAPP_PACKAGE,
            WHATSAPP_BUSINESS_PACKAGE,
            "com.gbwhatsapp",
            "com.whatsapp.plus",
            "com.fmwhatsapp",
            "com.yowhatsapp",
            "com.aero",
            "com.ogwhatsapp",
            "com.mbwhatsapp",
            "com.fouadmods.whatsapp"
        )
    }

    private var pendingAddResult: MethodChannel.Result? = null
    private var pendingPackIdentifier: String? = null
    private var previouslyWhitelistedPackages: Set<String> = emptySet()
    private var updateNotificationChannel: MethodChannel? = null
    private var pendingNotificationPayload: Map<String, String>? = null
    private var exitToast: Toast? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize status bar notification channel for APK updates
        createNotificationChannel()

        // Capture cold-start notification tap payload if launched from status bar
        extractUpdatePayloadFromIntent(intent)?.let {
            pendingNotificationPayload = it
        }

        // Handle APK update status bar notifications
        val notifChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL)
        updateNotificationChannel = notifChannel
        notifChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initNotificationChannel" -> {
                    createNotificationChannel()
                    result.success(true)
                }

                "getAppVersion" -> {
                    result.success(getCurrentInstalledVersion())
                }

                "consumePendingNotificationAction" -> {
                    val payload = pendingNotificationPayload
                    pendingNotificationPayload = null
                    result.success(payload)
                }

                "showUpdateNotification" -> {
                    val title = call.argument<String>("title") ?: "Pembaruan Sticko Tersedia"
                    val body = call.argument<String>("body") ?: "Versi baru tersedia untuk diunduh."
                    val version = call.argument<String>("version") ?: ""
                    val downloadUrl = call.argument<String>("downloadUrl") ?: ""
                    showUpdateNotification(title, body, version, downloadUrl)
                    result.success(true)
                }

                "updateDownloadProgress" -> {
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    val title = call.argument<String>("title") ?: "Mengunduh Pembaruan Sticko"
                    val body = call.argument<String>("body") ?: "$progress% selesai"
                    updateDownloadProgress(progress, max, title, body)
                    result.success(true)
                }

                "showDownloadComplete" -> {
                    val apkPath = call.argument<String>("apkPath")
                    val title = call.argument<String>("title") ?: "Pembaruan Siap Dipasang"
                    val body = call.argument<String>("body") ?: "Unduhan selesai. Ketuk untuk memasang versi terbaru."
                    val version = call.argument<String>("version") ?: ""
                    showDownloadComplete(apkPath, title, body, version)
                    result.success(true)
                }

                "clearNotification" -> {
                    clearNotification()
                    result.success(true)
                }

                "areNotificationsEnabled" -> {
                    val enabled = areNotificationsEnabled()
                    result.success(enabled)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStickersDirectory" -> {
                    try {
                        val dir = File(context.filesDir, "stickers")
                        if (!dir.exists()) {
                            dir.mkdirs()
                        }
                        result.success(dir.absolutePath)
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.localizedMessage, null)
                    }
                }

                "checkInternetConnection" -> {
                    if (!hasActiveNetworkSignal()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val hasQuota = verifyInternetQuota()
                        runOnUiThread {
                            result.success(hasQuota)
                        }
                    }.start()
                }

                "showExitToast" -> {
                    val message = call.argument<String>("message") ?: "Tekan sekali lagi untuk keluar"
                    exitToast?.cancel()
                    exitToast = Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT)
                    exitToast?.show()
                    result.success(true)
                }

                "cancelExitToast" -> {
                    exitToast?.cancel()
                    exitToast = null
                    result.success(true)
                }

                "checkWhatsAppInstalled" -> {
                    val isWaInstalled = isPackageInstalled(WHATSAPP_PACKAGE)
                    val isW4bInstalled = isPackageInstalled(WHATSAPP_BUSINESS_PACKAGE)
                    result.success(
                        mapOf(
                            "whatsapp" to isWaInstalled,
                            "whatsapp_business" to isW4bInstalled
                        )
                    )
                }

                "checkDetailedWhatsAppStatus" -> {
                    val isWaInstalled = isPackageInstalled(WHATSAPP_PACKAGE)
                    val waVersion = getPackageVersion(WHATSAPP_PACKAGE)
                    val isW4bInstalled = isPackageInstalled(WHATSAPP_BUSINESS_PACKAGE)
                    val w4bVersion = getPackageVersion(WHATSAPP_BUSINESS_PACKAGE)

                    val knownClones = listOf(
                        Pair("com.gbwhatsapp", "GBWhatsApp"),
                        Pair("com.whatsapp.plus", "WhatsApp Plus"),
                        Pair("com.fmwhatsapp", "FMWhatsApp"),
                        Pair("com.yowhatsapp", "YoWhatsApp"),
                        Pair("com.aero", "Aero WhatsApp"),
                        Pair("com.ogwhatsapp", "OGWhatsApp")
                    )

                    val detectedClones = mutableListOf<Map<String, String>>()
                    for ((pkg, name) in knownClones) {
                        if (isPackageInstalled(pkg)) {
                            detectedClones.add(
                                mapOf(
                                    "packageName" to pkg,
                                    "name" to name,
                                    "version" to (getPackageVersion(pkg) ?: "")
                                )
                            )
                        }
                    }

                    result.success(
                        mapOf(
                            "whatsapp" to isWaInstalled,
                            "whatsappVersion" to (waVersion ?: ""),
                            "whatsappBusiness" to isW4bInstalled,
                            "whatsappBusinessVersion" to (w4bVersion ?: ""),
                            "clones" to detectedClones
                        )
                    )
                }

                "openWhatsAppApp" -> {
                    val pkg = call.argument<String>("packageName") ?: WHATSAPP_PACKAGE
                    val launchIntent = packageManager.getLaunchIntentForPackage(pkg)
                    if (launchIntent != null) {
                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launchIntent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                "openPlayStore" -> {
                    val pkg = call.argument<String>("packageName") ?: WHATSAPP_PACKAGE
                    try {
                        val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(marketIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val webIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg")).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(webIntent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("PLAYSTORE_ERROR", e2.localizedMessage, null)
                        }
                    }
                }

                "isStickerPackAdded" -> {
                    val identifier = call.argument<String>("identifier")
                    val explicitTargetPkg = call.argument<String>("targetPackage")
                    val isBusiness = call.argument<Boolean>("isBusiness")
                    if (identifier == null) {
                        result.error("INVALID_ARGUMENT", "Identifier cannot be null", null)
                        return@setMethodCallHandler
                    }
                    val isAdded = when {
                        !explicitTargetPkg.isNullOrBlank() -> isWhitelisted(identifier, explicitTargetPkg)
                        isBusiness == true -> isWhitelisted(identifier, WHATSAPP_BUSINESS_PACKAGE)
                        else -> isWhitelistedInAnyWhatsApp(identifier)
                    }
                    result.success(isAdded)
                }

                "addStickerPack" -> {
                    val identifier = call.argument<String>("identifier")
                    val name = call.argument<String>("name")
                    val explicitTargetPkg = call.argument<String>("targetPackage")
                    val isBusiness = call.argument<Boolean>("isBusiness")

                    if (identifier == null || name == null) {
                        result.error("INVALID_ARGUMENT", "Identifier and name are required", null)
                        return@setMethodCallHandler
                    }

                    // Only restrict to a single package if explicitly requested;
                    // by default (targetPkg == null), open the phone's default bottom chooser modal
                    // so the user can choose WhatsApp Original, WhatsApp Business, or Duplicate/Clones.
                    val targetPkg: String? = when {
                        !explicitTargetPkg.isNullOrBlank() -> explicitTargetPkg
                        isBusiness == true -> WHATSAPP_BUSINESS_PACKAGE
                        else -> null
                    }

                    if (targetPkg != null) {
                        if (!isPackageInstalled(targetPkg)) {
                            result.success(
                                mapOf(
                                    "status" to "error",
                                    "message" to if (targetPkg == WHATSAPP_BUSINESS_PACKAGE) {
                                        "WhatsApp Business belum terpasang di HP ini"
                                    } else {
                                        "Aplikasi WhatsApp tujuan ($targetPkg) belum terpasang di HP ini"
                                    }
                                )
                            )
                            return@setMethodCallHandler
                        }
                    } else if (!hasAnyWhatsAppOrStickerHandler(identifier, name)) {
                        result.success(
                            mapOf(
                                "status" to "error",
                                "message" to "Tidak ada aplikasi WhatsApp (Original, Business, atau Duplikat) yang terpasang di HP ini"
                            )
                        )
                        return@setMethodCallHandler
                    }

                    pendingAddResult = result
                    pendingPackIdentifier = identifier
                    previouslyWhitelistedPackages = getWhitelistedPackages(identifier)
                    launchAddPackIntent(identifier, name, targetPkg)
                }

                "extractVideoFrames" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val maxDurationMs = call.argument<Int>("maxDurationMs") ?: 10000

                    if (videoPath == null) {
                        result.error("INVALID_ARGUMENT", "videoPath cannot be null", null)
                        return@setMethodCallHandler
                    }

                    val videoFile = File(videoPath)
                    if (!videoFile.exists()) {
                        result.error("FILE_NOT_FOUND", "Video file not found at $videoPath", null)
                        return@setMethodCallHandler
                    }

                    // Extract frames in background thread to avoid freezing UI
                    Thread {
                        val retriever = MediaMetadataRetriever()
                        try {
                            retriever.setDataSource(videoFile.absolutePath)
                            val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            val videoDurationMs = durationStr?.toLongOrNull() ?: 0L
                            val effectiveDurationMs = minOf(videoDurationMs, maxDurationMs.toLong()).toInt()

                            if (effectiveDurationMs <= 0) {
                                runOnUiThread {
                                    result.error("INVALID_VIDEO", "Video duration could not be determined", null)
                                }
                                return@Thread
                            }

                            // Calculate optimal target frame count for WhatsApp stickers (<= 500 KB limit)
                            val targetFrames = when {
                                effectiveDurationMs <= 2000 -> 16
                                effectiveDurationMs <= 4000 -> 20
                                effectiveDurationMs <= 7000 -> 24
                                else -> 28 // 7 to 10 seconds
                            }

                            val intervalUs = (effectiveDurationMs * 1000L) / targetFrames
                            val frameDurationMs = (effectiveDurationMs / targetFrames).coerceAtLeast(40)

                            val frameByteArrays = ArrayList<ByteArray>()

                            for (i in 0 until targetFrames) {
                                val timeUs = i * intervalUs
                                val rawBitmap = retriever.getFrameAtTime(
                                    timeUs,
                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                ) ?: retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)

                                if (rawBitmap != null) {
                                    val w = rawBitmap.width
                                    val h = rawBitmap.height
                                    val maxDim = 480
                                    val scale = minOf(maxDim.toFloat() / w, maxDim.toFloat() / h, 1.0f)
                                    val targetW = (w * scale).toInt().coerceAtLeast(1)
                                    val targetH = (h * scale).toInt().coerceAtLeast(1)

                                    val scaledBitmap = Bitmap.createScaledBitmap(rawBitmap, targetW, targetH, true)
                                    val baos = ByteArrayOutputStream()
                                    scaledBitmap.compress(Bitmap.CompressFormat.PNG, 85, baos)
                                    frameByteArrays.add(baos.toByteArray())

                                    if (scaledBitmap != rawBitmap) {
                                        scaledBitmap.recycle()
                                    }
                                    rawBitmap.recycle()
                                }
                            }

                            runOnUiThread {
                                result.success(
                                    mapOf(
                                        "frames" to frameByteArrays,
                                        "frameDurationMs" to frameDurationMs,
                                        "totalDurationMs" to effectiveDurationMs,
                                        "frameCount" to frameByteArrays.size
                                    )
                                )
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to extract video frames", e)
                            runOnUiThread {
                                result.error("EXTRACTION_ERROR", e.localizedMessage, null)
                            }
                        } finally {
                            try {
                                retriever.release()
                            } catch (e: Exception) {
                                Log.w(TAG, "Error releasing retriever", e)
                            }
                        }
                    }.start()
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun getPackageVersion(packageName: String): String? {
        return try {
            val pInfo = packageManager.getPackageInfo(packageName, 0)
            pInfo.versionName
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun isWhitelisted(identifier: String, targetPackage: String): Boolean {
        return try {
            val authority = "${context.packageName}.stickercontentprovider"
            val uri = Uri.parse("content://$targetPackage$WHITELIST_PROVIDER_SUFFIX/is_whitelisted")
                .buildUpon()
                .appendQueryParameter("authority", authority)
                .appendQueryParameter("identifier", identifier)
                .build()

            val cursor = contentResolver.query(uri, arrayOf("result"), null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val resultIndex = it.getColumnIndex("result")
                    if (resultIndex != -1) {
                        return it.getInt(resultIndex) == 1
                    }
                }
            }
            false
        } catch (e: Exception) {
            Log.w(TAG, "Failed to check sticker whitelist status for $targetPackage", e)
            false
        }
    }

    private fun isWhitelistedInAnyWhatsApp(identifier: String): Boolean {
        for (pkg in ALL_WHATSAPP_PACKAGES) {
            if (isPackageInstalled(pkg) && isWhitelisted(identifier, pkg)) {
                return true
            }
        }
        return false
    }

    private fun getWhitelistedPackages(identifier: String): Set<String> {
        val whitelisted = mutableSetOf<String>()
        for (pkg in ALL_WHATSAPP_PACKAGES) {
            if (isPackageInstalled(pkg) && isWhitelisted(identifier, pkg)) {
                whitelisted.add(pkg)
            }
        }
        return whitelisted
    }

    private fun createStickerPackIntent(
        identifier: String,
        name: String,
        authority: String,
        targetPackage: String? = null
    ): Intent {
        return Intent(ACTION_ENABLE_STICKER_PACK).apply {
            if (!targetPackage.isNullOrBlank()) {
                setPackage(targetPackage)
            }
            putExtra(EXTRA_STICKER_PACK_ID, identifier)
            putExtra(EXTRA_STICKER_PACK_AUTHORITY, authority)
            putExtra(EXTRA_STICKER_PACK_NAME, name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
    }

    private fun hasAnyWhatsAppOrStickerHandler(identifier: String, name: String): Boolean {
        val authority = "${context.packageName}.stickercontentprovider"
        val baseIntent = createStickerPackIntent(identifier, name, authority, null)
        val resolved = try {
            packageManager.queryIntentActivities(baseIntent, 0)
        } catch (_: Exception) {
            emptyList()
        }
        if (resolved.isNotEmpty()) return true
        return ALL_WHATSAPP_PACKAGES.any { isPackageInstalled(it) }
    }

    private fun grantStickerUriPermissionsToWhatsAppApps(authority: String, baseIntent: Intent) {
        val candidatePackages = mutableSetOf<String>()
        candidatePackages.addAll(ALL_WHATSAPP_PACKAGES.filter { isPackageInstalled(it) })
        try {
            val resolvedActivities = packageManager.queryIntentActivities(baseIntent, 0)
            for (info in resolvedActivities) {
                info.activityInfo?.packageName?.let { candidatePackages.add(it) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query sticker intent activities for URI grant", e)
        }

        val providerUri = Uri.parse("content://$authority")
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        for (pkg in candidatePackages) {
            try {
                grantUriPermission(pkg, providerUri, flags)
            } catch (_: Exception) {
                // Ignore if package does not exist in current user profile
            }
        }
    }

    private fun buildWhatsAppChooserIntent(
        identifier: String,
        name: String,
        authority: String,
        baseIntent: Intent
    ): Intent {
        val chooserIntent = Intent.createChooser(
            baseIntent,
            "Tambahkan paket stiker ke WhatsApp"
        )

        try {
            val resolvedPackages = packageManager.queryIntentActivities(baseIntent, 0)
                .mapNotNull { it.activityInfo?.packageName }
                .toSet()

            val extraIntents = mutableListOf<Intent>()
            for (pkg in ALL_WHATSAPP_PACKAGES) {
                if (pkg !in resolvedPackages && isPackageInstalled(pkg)) {
                    val pkgIntent = createStickerPackIntent(identifier, name, authority, pkg)
                    val pkgResolved = packageManager.queryIntentActivities(pkgIntent, 0)
                    if (pkgResolved.isNotEmpty()) {
                        extraIntents.add(pkgIntent)
                    }
                }
            }

            if (extraIntents.isNotEmpty()) {
                chooserIntent.putExtra(
                    Intent.EXTRA_INITIAL_INTENTS,
                    extraIntents.toTypedArray()
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not attach extra clone intents to chooser", e)
        }

        return chooserIntent
    }

    private fun launchAddPackIntent(
        identifier: String,
        name: String,
        targetPackage: String? = null
    ) {
        val authority = "${context.packageName}.stickercontentprovider"
        val baseIntent = createStickerPackIntent(identifier, name, authority, targetPackage)

        // Grant read access on StickerContentProvider to all installed WhatsApp variants & clones
        grantStickerUriPermissionsToWhatsAppApps(authority, baseIntent)

        try {
            if (targetPackage.isNullOrBlank()) {
                // Show the phone's default bottom chooser modal so the user can choose
                // between WhatsApp Original, WhatsApp Business, Dual Apps, or Clones
                val chooserIntent = buildWhatsAppChooserIntent(
                    identifier,
                    name,
                    authority,
                    baseIntent
                )
                startActivityForResult(chooserIntent, ADD_PACK_REQUEST_CODE)
            } else {
                startActivityForResult(baseIntent, ADD_PACK_REQUEST_CODE)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start WhatsApp sticker chooser/intent, retrying direct intent", e)
            try {
                startActivityForResult(baseIntent, ADD_PACK_REQUEST_CODE)
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to start fallback WhatsApp sticker intent", e2)
                pendingPackIdentifier = null
                previouslyWhitelistedPackages = emptySet()
                pendingAddResult?.success(
                    mapOf(
                        "status" to "error",
                        "message" to "Gagal membuka WhatsApp: ${e2.localizedMessage}"
                    )
                )
                pendingAddResult = null
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == ADD_PACK_REQUEST_CODE) {
            val result = pendingAddResult ?: return
            val packId = pendingPackIdentifier
            val beforePackages = previouslyWhitelistedPackages
            pendingAddResult = null
            pendingPackIdentifier = null
            previouslyWhitelistedPackages = emptySet()

            when (resultCode) {
                Activity.RESULT_OK -> {
                    result.success(
                        mapOf(
                            "status" to "success",
                            "message" to "Paket stiker berhasil ditambahkan ke WhatsApp!"
                        )
                    )
                }

                Activity.RESULT_CANCELED -> {
                    val validationError = data?.getStringExtra("validation_error")
                    if (validationError != null) {
                        Log.e(TAG, "WhatsApp validation error: $validationError")
                        result.success(
                            mapOf(
                                "status" to "error",
                                "message" to "Validasi WhatsApp gagal: $validationError"
                            )
                        )
                    } else {
                        // Some OEM system choosers / Dual App bridges return RESULT_CANCELED
                        // even when the pack was successfully added inside the chosen WhatsApp app.
                        val afterPackages = if (packId != null) {
                            getWhitelistedPackages(packId)
                        } else {
                            emptySet()
                        }
                        if ((afterPackages - beforePackages).isNotEmpty()) {
                            result.success(
                                mapOf(
                                    "status" to "success",
                                    "message" to "Paket stiker berhasil ditambahkan ke WhatsApp!"
                                )
                            )
                        } else {
                            result.success(
                                mapOf(
                                    "status" to "cancelled",
                                    "message" to "Penambahan stiker dibatalkan oleh pengguna."
                                )
                            )
                        }
                    }
                }

                else -> {
                    result.success(
                        mapOf(
                            "status" to "error",
                            "message" to "Hasil tidak diketahui dari WhatsApp (kode: $resultCode)"
                        )
                    )
                }
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                UPDATE_CHANNEL_ID,
                "Pembaruan Aplikasi Sticko",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifikasi bilah status pembaruan APK Sticko"
                setShowBadge(true)
                enableLights(true)
            }
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun getUpdateIconRes(): Int {
        val resId = resources.getIdentifier("ic_stat_update", "drawable", packageName)
        return if (resId != 0) resId else android.R.drawable.stat_sys_download_done
    }

    private fun getDownloadIconRes(): Int {
        return android.R.drawable.stat_sys_download
    }

    private fun areNotificationsEnabled(): Boolean {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            notificationManager.areNotificationsEnabled()
        } else {
            true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = extractUpdatePayloadFromIntent(intent)
        if (payload != null) {
            val ch = updateNotificationChannel
            if (ch != null) {
                ch.invokeMethod("onNotificationTapped", payload)
            } else {
                pendingNotificationPayload = payload
            }
        }
    }

    private fun extractUpdatePayloadFromIntent(intent: Intent?): Map<String, String>? {
        val action = intent?.getStringExtra("action") ?: return null
        if (action != "SHOW_APP_UPDATE" && action != "INSTALL_APP_UPDATE") return null
        val map = mutableMapOf("action" to action)
        intent.getStringExtra("latest_version")?.let { map["version"] = it }
        intent.getStringExtra("version")?.let { map["version"] = it }
        intent.getStringExtra("download_url")?.let { map["downloadUrl"] = it }
        intent.getStringExtra("apk_path")?.let { map["apkPath"] = it }
        intent.getStringExtra("update_title")?.let { map["title"] = it }
        intent.getStringExtra("update_body")?.let { map["body"] = it }
        intent.removeExtra("action")
        return map
    }

    private fun getCurrentInstalledVersion(): String {
        return try {
            val pInfo = packageManager.getPackageInfo(packageName, 0)
            val vName = pInfo.versionName ?: "1.0.6"
            val vCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pInfo.versionCode.toLong()
            }
            "$vName+$vCode"
        } catch (e: Exception) {
            "1.0.6+7"
        }
    }

    private fun showUpdateNotification(title: String, body: String, version: String, downloadUrl: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "SHOW_APP_UPDATE")
            putExtra("latest_version", version)
            putExtra("download_url", downloadUrl)
            putExtra("update_title", title)
            putExtra("update_body", body)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            UPDATE_NOTIFICATION_ID,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, UPDATE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(getUpdateIconRes())
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOngoing(false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
            builder.setCategory(Notification.CATEGORY_RECOMMENDATION)
        }

        @Suppress("DEPRECATION")
        builder.setPriority(Notification.PRIORITY_HIGH)

        notificationManager.notify(UPDATE_NOTIFICATION_ID, builder.build())
    }

    private fun updateDownloadProgress(progress: Int, max: Int, title: String, body: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            UPDATE_NOTIFICATION_ID,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, UPDATE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(getDownloadIconRes())
            .setContentIntent(pendingIntent)
            .setProgress(max, progress, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            builder.setSubText("$progress%")
        }

        notificationManager.notify(UPDATE_NOTIFICATION_ID, builder.build())
    }

    private fun showDownloadComplete(apkPath: String?, title: String, body: String, version: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "INSTALL_APP_UPDATE")
            if (apkPath != null) putExtra("apk_path", apkPath)
            putExtra("version", version)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            UPDATE_NOTIFICATION_ID,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, UPDATE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(getUpdateIconRes())
            .setContentIntent(pendingIntent)
            .setProgress(0, 0, false)
            .setOngoing(false)
            .setAutoCancel(true)

        @Suppress("DEPRECATION")
        builder.setPriority(Notification.PRIORITY_HIGH)

        notificationManager.notify(UPDATE_NOTIFICATION_ID, builder.build())
    }

    private fun clearNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(UPDATE_NOTIFICATION_ID)
    }

    private fun hasActiveNetworkSignal(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val activeNetwork = cm.activeNetwork ?: return false
                val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
                val hasTransport = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                hasTransport && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            } else {
                @Suppress("DEPRECATION")
                val netInfo = cm.activeNetworkInfo
                @Suppress("DEPRECATION")
                netInfo != null && netInfo.isConnected
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error checking network signal", e)
            false
        }
    }

    private fun verifyInternetQuota(): Boolean {
        try {
            val url = URL("https://connectivitycheck.gstatic.com/generate_204")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 2500
                readTimeout = 2500
                instanceFollowRedirects = false
                useCaches = false
            }
            try {
                val responseCode = conn.responseCode
                if (responseCode == 204) {
                    return true
                }
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            // Fall through to DNS + OS network validation fallback
        }

        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val osValidated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && cm != null) {
                val activeNetwork = cm.activeNetwork
                val caps = if (activeNetwork != null) cm.getNetworkCapabilities(activeNetwork) else null
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
            } else {
                true
            }
            if (!osValidated) return false
            val address = InetAddress.getByName("whatsapp.com")
            !address.hostAddress.isNullOrEmpty()
        } catch (_: Exception) {
            false
        }
    }
}
