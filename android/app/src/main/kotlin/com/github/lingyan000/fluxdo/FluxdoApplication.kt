package com.github.lingyan000.fluxdo

import android.app.Application
import android.util.Log
import android.webkit.WebView
import androidx.webkit.ProcessGlobalConfig
import androidx.webkit.WebViewFeature
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics

class FluxdoApplication : Application() {

    companion object {
        private var appInstance: FluxdoApplication? = null

        /**
         * 设置 Crashlytics 开关。
         * 首次开启时才初始化 Firebase，避免未开启时产生任何网络请求。
         */
        fun setCrashlytics(enable: Boolean) {
            val app = appInstance ?: return
            if (enable) {
                // 延迟初始化：只在用户主动开启时初始化 Firebase
                if (FirebaseApp.getApps(app).isEmpty()) {
                    FirebaseApp.initializeApp(app)
                }
                FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
            } else {
                // Firebase 已初始化时才操作，未初始化则无需处理
                if (FirebaseApp.getApps(app).isNotEmpty()) {
                    FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(false)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        appInstance = this
        // 进程级禁用 WebView 分区 cookie(CHIPS)。
        // CF 会给 cf_clearance 附加 Partitioned 属性,分区副本与挑战流程写入的
        // 普通副本在 Chromium 中同名同域同路径共存,CookieManager 常规删除头
        // 无法命中分区副本,导致双变体清不掉、边界同步反复在新旧值间摇摆,
        // 频繁触发 CF 盾。App 内 WebView 只服务主站单一第一方站点,不依赖
        // 跨站 iframe 的分区隔离,直接关闭该特性从源头消除双变体。
        // 必须先于任何加载 WebView 的调用(包括下方 setWebContentsDebuggingEnabled)。
        try {
            if (WebViewFeature.isStartupFeatureSupported(
                    this, WebViewFeature.STARTUP_FEATURE_CONFIGURE_PARTITIONED_COOKIES
                )
            ) {
                ProcessGlobalConfig.apply(
                    ProcessGlobalConfig().setPartitionedCookiesEnabled(this, false)
                )
                Log.i("WebViewConfig", "Partitioned cookies (CHIPS) disabled process-wide")
            } else {
                Log.i("WebViewConfig", "CONFIGURE_PARTITIONED_COOKIES not supported, skip")
            }
        } catch (e: Throwable) {
            // apply 只能调一次且要求 WebView 未初始化;任何异常都不应阻断启动
            Log.e("WebViewConfig", "Failed to disable partitioned cookies: ${e.message}", e)
        }
        try {
            WebView.setWebContentsDebuggingEnabled(false)
            Log.i("WebViewDebug", "WebView debugging disabled in Application.onCreate")
        } catch (e: Throwable) {
            Log.e("WebViewDebug", "Failed to disable WebView debugging early: ${e.message}", e)
        }
        // 不在此处初始化 Firebase，等待用户主动开启
    }
}
