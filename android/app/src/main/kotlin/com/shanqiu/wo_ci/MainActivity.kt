package com.shanqiu.wo_ci

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 唯一职责：给 Dart 侧提供一个「把已下载的 APK 交给系统安装器」的通道。
 *
 * Dart 侧调用：MethodChannel('com.shanqiu.wo_ci/update').invokeMethod('installApk', {'path': '...'})
 * 返回：'ok' = 已唤起安装器；'need_permission' = 已跳转系统「安装未知应用」授权页，需用户授权后重试
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_ARGS", "path is empty", null)
                        } else {
                            try {
                                result.success(installApk(path))
                            } catch (e: Exception) {
                                result.error("INSTALL_FAILED", e.message ?: e.toString(), null)
                            }
                        }
                    }
                    "canInstall" -> result.success(canRequestInstall())
                    else -> result.notImplemented()
                }
            }
    }

    /** 返回 'ok' / 'need_permission' */
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("APK 文件不存在：$path")
        }
        if (!canRequestInstall()) {
            // Android 8.0+ 需要用户显式允许本应用安装未知来源应用
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            return "need_permission"
        }
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return "ok"
    }

    private fun canRequestInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    companion object {
        private const val CHANNEL = "com.shanqiu.wo_ci/update"
    }
}
