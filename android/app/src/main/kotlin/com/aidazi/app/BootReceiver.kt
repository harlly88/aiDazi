package com.aidazi.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 开机广播接收器（设备模式默认关闭，由关于弹窗隐藏开关运行时启用组件）。
 * 收到开机广播后启动前台看门狗服务，由服务延时拉起主界面。
 * 不在 Receiver 里直接 startActivity：Android 12 后台启动 Activity 受限。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.i(TAG, "收到广播: $action")
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == ACTION_QUICKBOOT_POWERON ||
            action == Intent.ACTION_USER_PRESENT
        ) {
            try {
                context.startForegroundService(Intent(context, WatchdogService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "启动看门狗服务失败", e)
            }
        }
    }

    companion object {
        private const val TAG = "AidaziBoot"
        /** MTK 联发科定制开机广播 */
        private const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}
