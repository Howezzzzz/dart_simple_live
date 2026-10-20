package com.slotsun.slive

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "slive/installer"
        private const val REQ_UNKNOWN_APP_SOURCES = 8091
    }

    private var pendingSettingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                    )

                    "openUnknownAppSourcesSetting" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            pendingSettingResult = result
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                            try {
                                startActivityForResult(intent, REQ_UNKNOWN_APP_SOURCES)
                            } catch (e: Exception) {
                                // 个别 ROM 无该设置页 intent 处理者：直接放行，不挂起 Dart 侧
                                pendingSettingResult?.success(true)
                                pendingSettingResult = null
                            }
                        } else {
                            result.success(true)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_UNKNOWN_APP_SOURCES) {
            // 用户已从「允许安装未知应用」设置页返回：告知 Dart 侧继续（自动续装）
            pendingSettingResult?.success(true)
            pendingSettingResult = null
        }
    }

    override fun onResume() {
        super.onResume()
        // 兜底：个别路径（设置页未 finish 直接回前台等）不走 onActivityResult，
        // 这里回复一次，避免 Dart 侧 await 永久挂起（pendingSettingResult 已置 null，不会重复 reply）
        pendingSettingResult?.success(true)
        pendingSettingResult = null
    }
}
