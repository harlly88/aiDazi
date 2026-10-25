package com.aidazi.app

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onResume() {
        super.onResume()
        AppLifecycle.isMainActivityVisible = true
        // 设备模式开启时主动拉起看门狗，增强保活
        startWatchdogIfNeeded()
    }

    override fun onPause() {
        AppLifecycle.isMainActivityVisible = false
        super.onPause()
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // 14.x 设备模式桥：Flutter 侧隐藏开关查询/设置（组件启用状态即持久化存储）
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isDeviceModeEnabled())
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        setDeviceModeEnabled(enabled)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("DEVICE_MODE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 设备模式是否开启：组件被显式 ENABLED 才算开（DEFAULT 即 Manifest 默认 = 关） */
    private fun isDeviceModeEnabled(): Boolean =
        packageManager.getComponentEnabledSetting(bootReceiverComponent()) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED

    private fun setDeviceModeEnabled(enabled: Boolean) {
        packageManager.setComponentEnabledSetting(
            bootReceiverComponent(),
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
        if (enabled) {
            startWatchdogIfNeeded()
        } else {
            stopService(Intent(this, WatchdogService::class.java))
        }
    }

    private fun startWatchdogIfNeeded() {
        if (!isDeviceModeEnabled()) return
        try {
            startForegroundService(Intent(this, WatchdogService::class.java))
        } catch (e: Exception) {
            Log.w("AidaziWatchdog", "启动看门狗服务失败", e)
        }
    }

    private fun bootReceiverComponent() = ComponentName(this, BootReceiver::class.java)

    companion object {
        private const val CHANNEL = "aidazi/device_mode"
    }
}
