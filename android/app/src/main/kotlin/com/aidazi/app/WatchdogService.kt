package com.aidazi.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * 前台看门狗服务（设备模式开启时运行，方案见 docs/aidazi 开机自启与看门狗 开发文档.md）。
 * 职责：周期检测 MainActivity 是否在前台，不在则拉回前台。
 * 通过 startForeground 获得前台状态，抵抗 Doze 休眠/后台清理。
 */
class WatchdogService : Service() {

    private val handler = Handler(Looper.getMainLooper())

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (!AppLifecycle.isMainActivityVisible) {
                Log.w(TAG, "MainActivity 不在前台，尝试拉起")
                launchMain()
            }
            handler.postDelayed(this, CHECK_INTERVAL)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        // startForegroundService 之后必须在 5 秒内调用 startForeground，否则系统崩溃（Android 12 规则）
        startForeground(NOTIFY_ID, buildNotification())
        Log.i(TAG, "看门狗服务已启动（前台）")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 无论开机拉起还是 MainActivity onResume 拉起，统一走看门狗检查路径：
        // 首次检查延时 3 秒（MTK 开机慢），此后每 5 秒一次；
        // 主界面已在前台时检查为空操作，不会重复拉起（修复每 3 秒重启死循环）
        handler.removeCallbacks(watchdogRunnable)
        handler.postDelayed(watchdogRunnable, FIRST_CHECK_DELAY)
        // START_STICKY：系统意外杀进程后会自动重启服务
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(watchdogRunnable)
        Log.i(TAG, "看门狗服务已销毁")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 拉起 MainActivity。
     * 双重防护：
     *  1. 已在前台直接返回（防「onResume 拉服务 → 服务拉主界面」死循环）；
     *  2. REORDER_TO_FRONT 复用已存在的实例，绝不销毁重建（CLEAR_TASK 曾导致前台界面被反复摧毁）。
     */
    private fun launchMain() {
        if (AppLifecycle.isMainActivityVisible) return
        try {
            val intent = Intent(this, MainActivity::class.java)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            startActivity(intent)
            Log.i(TAG, "已拉起 MainActivity")
        } catch (e: Exception) {
            Log.e(TAG, "拉起 MainActivity 失败", e)
        }
    }

    /* ---------- 通知相关 ---------- */

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "aidazi 保活服务", NotificationManager.IMPORTANCE_MIN
            ) // MIN：静默常驻，不响不震动不打扰
            channel.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("aidazi 运行中")
            .setContentText("保持前台服务运行")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pi)
            .setOngoing(true) // 不可滑动删除
            .apply {
                if (Build.VERSION.SDK_INT >= 31) {
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                }
            }
            .build()
    }

    companion object {
        private const val TAG = "AidaziWatchdog"
        private const val CHANNEL_ID = "aidazi_watchdog_channel"
        private const val NOTIFY_ID = 1001
        /** 首次检查延时（毫秒）：MTK 开机系统资源加载慢 */
        private const val FIRST_CHECK_DELAY = 3000L
        /** 看门狗检查间隔（毫秒） */
        private const val CHECK_INTERVAL = 5000L
    }
}
