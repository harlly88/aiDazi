package com.aidazi.app

/**
 * 进程内共享的前台状态标记。
 * MainActivity 在 onResume/onPause 更新，看门狗服务读取判断主界面是否存活。
 */
object AppLifecycle {
    /** MainActivity 当前是否可见（在前台） */
    @Volatile
    var isMainActivityVisible: Boolean = false
}
