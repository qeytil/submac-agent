#!/usr/bin/env python3
"""Turns the folder `flutter create` makes into SubMac's Android app.
Run from the repo root after `flutter create`. Used by every workflow, so release and dev builds match."""
import glob
import os
import shutil

M = "android/app/src/main/AndroidManifest.xml"
G = "android/app/build.gradle"

# ---------------- manifest ----------------
s = open(M).read()
perms = '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" tools:ignore="ScopedStorage"/>
    <uses-permission android:name="com.android.alarm.permission.SET_ALARM"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.READ_SMS"/>
    <uses-permission android:name="android.permission.READ_CALENDAR"/>
    <uses-permission android:name="android.permission.WRITE_CALENDAR"/>
    <uses-permission android:name="android.permission.READ_CONTACTS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.WRITE_SETTINGS" tools:ignore="ProtectedPermissions"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <!-- In-app updates (feature/app-update): open Android's installer for a downloaded SubMac update. -->
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
    <queries>
        <intent><action android:name="android.speech.RecognitionService"/></intent>
        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="http"/></intent>
        <intent><action android:name="android.intent.action.DIAL"/><data android:scheme="tel"/></intent>
        <intent><action android:name="android.intent.action.SENDTO"/><data android:scheme="sms"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="sms"/></intent>
        <intent><action android:name="android.intent.action.SENDTO"/><data android:scheme="mailto"/></intent>
        <intent><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent>
        <intent><action android:name="android.intent.action.SET_ALARM"/></intent>
        <intent><action android:name="android.intent.action.SET_TIMER"/></intent>
        <intent><action android:name="android.intent.action.INSERT"/><data android:mimeType="vnd.android.cursor.dir/event"/></intent>
        <intent><action android:name="android.media.action.IMAGE_CAPTURE"/></intent>
        <!-- WhatsApp and WhatsApp Business on this phone (plan: WhatsApp by controlling the phone) -->
        <package android:name="com.whatsapp"/>
        <package android:name="com.whatsapp.w4b"/>
        <intent><action android:name="android.intent.action.SEND"/><data android:mimeType="*/*"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="whatsapp"/></intent>
    </queries>
    <application android:usesCleartextTraffic="true" android:requestLegacyExternalStorage="true"'''
s = s.replace("<application", perms, 1)
s = s.replace('xmlns:android="http://schemas.android.com/apk/res/android"',
              'xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools"', 1)
s = s.replace('android:label="agent"', 'android:label="SubMac Agent"')
assert 'android:name="${applicationName}"' in s, "applicationName placeholder missing"
s = s.replace('android:name="${applicationName}"', 'android:name=".SubMacApp"', 1)
# "Share to SubMac": accept text and files from other apps.
share = '''</intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="com.submac.agent" android:host="login-callback"/>
            </intent-filter>
            <!-- "Hire in SubMac" from a public bot page: submac://hire?bot=<code>&ref=<ref> -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="submac" android:host="hire"/>
            </intent-filter>
            <!-- Invite link inside the app: submac://invite?ref=<code> (plan 2.4) -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="submac" android:host="invite"/>
            </intent-filter>
            <!-- Back from the hosted payment page (billing-return 303): submac://pay?status=..&purchase=<id>[&reason=..] -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="submac" android:host="pay"/>
            </intent-filter>
            <!-- https://submac.site/b/<code>: opens the app directly once submac.site/.well-known/assetlinks.json lists our key -->
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="submac.site" android:pathPrefix="/b/"/>
            </intent-filter>
            <!-- Links go to app_links (HireLinks, Supabase), not to Flutter's router. -->
            <meta-data android:name="flutter_deeplinking_enabled" android:value="false"/>'''
s = s.replace("</intent-filter>", share, 1)
components = '''
        <!-- Rendering (v1.13.101): Impeller, stated on purpose. Flutter 3.47 picks Vulkan where the GPU supports it and
             falls back to Impeller OpenGL ES; it has no shader-compile jank (Skia compiled shaders on first use, the
             stutter on the first open of a sheet or blur). Skia is deprecated on Android 3.47 (the engine warns on the
             opt-out), so it is not the safer choice. -->
        <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="true"/>
        <service android:name=".WakeService" android:exported="false" android:foregroundServiceType="microphone"/>
        <service android:name=".SubMacA11y" android:exported="false"
            android:label="@string/submac_a11y_label"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService"/></intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/submac_a11y"/>
        </service>
        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
        <service android:name=".TaskService" android:exported="false" android:foregroundServiceType="dataSync"/>
        <receiver android:name=".AlarmReceiver" android:exported="false"/>
        <service android:name=".NotifListener" android:exported="true"
            android:label="SubMac"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter><action android:name="android.service.notification.NotificationListenerService"/></intent-filter>
        </service>
        <!-- v1.13.12 push (plan 2.1): FCM messages are shown natively through Notifier, app open or closed. -->
        <receiver android:name=".PushReceiver" android:exported="true"
            android:permission="com.google.android.c2dm.permission.SEND">
            <intent-filter><action android:name="com.google.android.c2dm.intent.RECEIVE"/></intent-filter>
        </receiver>
        <!-- Files SubMac shares into WhatsApp: read-only, one-time grants, never exported. -->
        <provider android:name=".WaFiles" android:authorities="com.submac.agent.wafiles"
            android:exported="false" android:grantUriPermissions="true"/>
        <!-- In-app updates: the joined update file for the installer (read-only, one-time grants, never exported),
             and DownloadManager's "download finished" broadcast (sent from the system, so exported). -->
        <provider android:name=".UpdateFiles" android:authorities="com.submac.agent.updates"
            android:exported="false" android:grantUriPermissions="true"/>
        <receiver android:name=".UpdateDone" android:exported="true">
            <intent-filter><action android:name="android.intent.action.DOWNLOAD_COMPLETE"/></intent-filter>
        </receiver>
        <receiver android:name=".QuickWidget" android:exported="true" android:label="SubMac">
            <intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter>
            <meta-data android:name="android.appwidget.provider" android:resource="@xml/submac_widget"/>
        </receiver>
    </application>'''
assert "</application>" in s
s = s.replace("</application>", components, 1)
open(M, "w").write(s)

# ---------------- native code + resources ----------------
for f in glob.glob("android/app/src/main/**/MainActivity.*", recursive=True):
    os.remove(f)
kdir = "android/app/src/main/kotlin/com/submac/agent"
os.makedirs(kdir, exist_ok=True)
for f in glob.glob("android_native/*.kt"):
    shutil.copy(f, os.path.join(kdir, os.path.basename(f)))
shutil.copy("android_native/proguard-rules.pro", "android/app/proguard-rules.pro")
for f in glob.glob("android_native/res/**/*", recursive=True):
    if os.path.isfile(f):
        rel = os.path.relpath(f, "android_native/res")
        dst = os.path.join("android/app/src/main/res", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(f, dst)

# ---------------- gradle ----------------
# Flutter 3.44+ generates Kotlin DSL (build.gradle.kts) with AGP 9 / Kotlin 2.x / Gradle 9.
# Older templates (build.gradle, Groovy) are still handled so a pinned older SDK keeps working.
KTS = os.path.exists(G + ".kts")
G = G + ".kts" if KTS else G
g = open(G).read()
for a, b in [
    ("compileSdk = flutter.compileSdkVersion", "compileSdk = flutter.compileSdkVersion"),
    ("targetSdk = flutter.targetSdkVersion", "targetSdk = 34"),
    ("minSdk = flutter.minSdkVersion", "minSdk = 24"),
]:
    assert a in g, a
    g = g.replace(a, b)
if KTS:
    sign = """    signingConfigs {
        create("submac") {
            storeFile = file("${rootProject.projectDir}/../keys/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    packaging {
        jniLibs {
            // Store native libs compressed and extract them at install time (same APK layout as before
            // the Flutter 3.44 upgrade). tools/verify_apk.sh still checks 16 KB zip + ELF alignment.
            useLegacyPackaging = true
        }
    }

    buildTypes {"""
    assert "    buildTypes {" in g
    g = g.replace("    buildTypes {", sign, 1)
    assert 'signingConfig = signingConfigs.getByName("debug")' in g
    g = g.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("submac")')
    assert "        versionName = flutter.versionName" in g
    g = g.replace("        versionName = flutter.versionName",
                  "        versionName = flutter.versionName\n        ndk { abiFilters += listOf(\"armeabi-v7a\", \"arm64-v8a\", \"x86_64\") }", 1)
    g += """
dependencies {
    // Offline wake word ("Hello SubMac"). Its native libs are 16 KB-page aligned.
    implementation("com.alphacephei:vosk-android:0.3.75") { exclude(group = "net.java.dev.jna") }
    implementation("net.java.dev.jna:jna:5.18.1@aar")
}
"""
else:
    g = g.replace("compileSdk = flutter.compileSdkVersion", "compileSdk = 35")
    sign = """    signingConfigs {
        submac {
            storeFile = file("${rootProject.projectDir}/../keys/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    packagingOptions {
        jniLibs {
            // AGP 8.1 only 4 KB-aligns uncompressed libs, which 16 KB-page devices reject.
            useLegacyPackaging = true
        }
    }

    buildTypes {"""
    assert "    buildTypes {" in g
    g = g.replace("    buildTypes {", sign, 1)
    assert "signingConfig = signingConfigs.debug" in g
    g = g.replace("signingConfig = signingConfigs.debug", "signingConfig = signingConfigs.submac")
    g = g.replace("        versionName = flutter.versionName",
                  "        versionName = flutter.versionName\n        ndk { abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64' }", 1)
    g += """
dependencies {
    // Offline wake word ("Hello SubMac"). Its native libs are 16 KB-page aligned.
    implementation('com.alphacephei:vosk-android:0.3.75') { exclude group: 'net.java.dev.jna' }
    implementation 'net.java.dev.jna:jna:5.18.1@aar'
}
"""
open(G, "w").write(g)

# ---------------- toolchain pins ----------------
# Flutter 3.47's template asks for AGP 9.1 / Gradle 9.3. Several plugins we ship (flutter_inappwebview_android 1.1.3
# above all: `getDefaultProguardFile('proguard-android.txt')`) do not build on AGP 9 yet, so the app stays on the newest
# AGP 8 line, which Flutter 3.47 still supports: AGP 8.13, Gradle 8.14.3, Kotlin 2.2 (Flutter needs KGP >= 2.0).
AGP, KGP, GRADLE = "8.13.0", "2.2.20", "8.14.3"
S = "android/settings.gradle.kts"
if os.path.exists(S):
    import re
    t = open(S).read()
    t, n1 = re.subn(r'id\("com\.android\.application"\) version "[^"]+"', 'id("com.android.application") version "%s"' % AGP, t)
    t, n2 = re.subn(r'id\("org\.jetbrains\.kotlin\.android"\) version "[^"]+"', 'id("org.jetbrains.kotlin.android") version "%s"' % KGP, t)
    assert n1 == 1 and n2 == 1, "plugin versions not found in settings.gradle.kts"
    open(S, "w").write(t)
    W = "android/gradle/wrapper/gradle-wrapper.properties"
    w = open(W).read()
    w = re.sub(r"distributionUrl=.*", "distributionUrl=https\\://services.gradle.org/distributions/gradle-%s-all.zip" % GRADLE, w)
    open(W, "w").write(w)
    P = "android/gradle.properties"
    p = open(P).read()
    # AGP 9-only switches from the template; AGP 8 does not know them.
    p = "\n".join(l for l in p.splitlines() if not l.startswith(("android.newDsl", "android.builtInKotlin")) and "flag was added by the Flutter template" not in l) + "\n"
    # Flutter 3.47's template gives Gradle 8 GB and the Kotlin daemon inherits the same, more than a 16 GB CI runner
    # holds next to R8 and gen_snapshot (the build swapped and hung). Back to the old budget.
    p = "\n".join(l for l in p.splitlines() if not l.startswith(("org.gradle.jvmargs", "kotlin.daemon.jvmargs"))) + "\n"
    p += "org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError\n"
    p += "kotlin.daemon.jvmargs=-Xmx2G\n"
    open(P, "w").write(p)
    # Old plugins (flutter_pcm_sound 3.3.3 compiles against API 33) pull AndroidX libraries that need API 34+: every
    # Android library module compiles against at least the app's SDK (36); a newer one of its own (37) is kept. Registered before the
    # template's evaluationDependsOn(":app") so it runs after each plugin's own build file.
    R = "android/build.gradle.kts"
    r = open(R).read()
    hook = """
// SubMac (tools/patch_android.py): every Android library module compiles against at least SDK 36 (raised, never
// lowered: permission_handler_android 14 needs its own 37).
subprojects {
    val forceSdk: Project.() -> Unit = {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.findByName("android")?.withGroovyBuilder {
                val cur = (getProperty("compileSdkVersion") as? String)?.substringAfter("android-")?.toIntOrNull() ?: 0
                if (cur < 36) "compileSdkVersion"(36)
            }
        }
    }
    if (state.executed) forceSdk() else afterEvaluate { forceSdk() }
}
"""
    marker = "subprojects {\n    project.evaluationDependsOn"
    assert marker in r, "evaluationDependsOn block not found in android/build.gradle.kts"
    r = r.replace(marker, hook.lstrip("\n") + marker, 1)
    open(R, "w").write(r)
    # Kotlin plugin is applied explicitly on AGP 8 (no built-in Kotlin).
    g = open(G).read()
    if 'id("kotlin-android")' not in g and 'org.jetbrains.kotlin.android' not in g:
        g = g.replace('    id("com.android.application")\n', '    id("com.android.application")\n    id("kotlin-android")\n', 1)
        open(G, "w").write(g)
print("patched android project (%s)" % ("kts" if KTS else "groovy"))
