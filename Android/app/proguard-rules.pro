# The JNI layer finds these by name.
-keep class com.everettjf.scriptwidget.core.js.JsException { *; }
-keep class com.everettjf.scriptwidget.core.js.JsHost { *; }
-keep class com.everettjf.scriptwidget.core.js.QuickJs { *; }
# Methods the Studio editor page calls.
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }
# Layouts referenced only from RemoteViews are kept by resource shrinking rules; workers are created by name.
-keep class * extends androidx.work.ListenableWorker { <init>(android.content.Context, androidx.work.WorkerParameters); }
