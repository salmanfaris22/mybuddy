# kotlinx.serialization keeps generated serializers via its consumer rules.
# OkHttp ships consumer rules.
# libwebrtc (io.github.webrtc-sdk) ships no consumer rules, and its native code finds Java classes, methods and
# fields by name through JNI — renaming or removing any of them crashes at runtime. Keep its Java API intact,
# including Chromium's jni_zero registration glue it uses since M150 (a release build without this aborts with
# ClassNotFoundException: org.jni_zero.JniZero as soon as WebRTC starts).
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }
-dontwarn org.webrtc.**
-dontwarn org.jni_zero.**
