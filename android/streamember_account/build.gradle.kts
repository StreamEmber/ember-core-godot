// StreamEmberAccount: Godot 4 Android plugin — the StreamEmber sign-in shared by every StreamEmber game on the phone
// (AccountManager account type com.streamember.account; apps signed with the same key see it).
// Build: gradle assembleRelease (Android SDK: ANDROID_HOME or local.properties sdk.dir)
// Output: build/outputs/aar/streamember_account-release.aar → addons/streamember/android/streamember-account.aar
plugins {
    id("com.android.library") version "8.6.1"
    id("org.jetbrains.kotlin.android") version "2.1.21"
}

android {
    namespace = "com.streamember.account"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

repositories {
    google()
    mavenCentral()
}

dependencies {
    compileOnly("org.godotengine:godot:4.3.0.stable")
}
