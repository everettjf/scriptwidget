import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.everettjf.scriptwidget"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    ndkVersion = "28.1.13356709"

    defaultConfig {
        // The Play package name. The Kotlin namespace above keeps its original name.
        applicationId = "com.atomsprout.scriptwidget"
        minSdk = 33
        targetSdk = 36
        versionCode = 4
        versionName = "1.1.2"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    // The upload key lives outside the repository. keystore.properties (git-ignored) holds
    // storeFile, storePassword, keyAlias and keyPassword; without it the release is debug-signed
    // and only suitable for local installs.
    val keystoreProperties = Properties().apply {
        val file = rootProject.file("keystore.properties")
        if (file.isFile) file.inputStream().use { load(it) }
    }
    // Push-triggered refresh needs a Firebase project. firebase.properties (git-ignored) holds
    // projectId, applicationId, apiKey and senderId; without it push is compiled in but stays off.
    val firebaseProperties = Properties().apply {
        val file = rootProject.file("firebase.properties")
        if (file.isFile) file.inputStream().use { load(it) }
    }
    val firebaseFields = listOf("FIREBASE_PROJECT_ID" to "projectId", "FIREBASE_APP_ID" to "applicationId", "FIREBASE_API_KEY" to "apiKey", "FIREBASE_SENDER_ID" to "senderId")
    // Two builds of the same app. `play` is the Google Play build and contains Firebase Cloud
    // Messaging. `foss` contains no Google library and is the APK published on GitHub Releases;
    // it never reads firebase.properties.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") {
            dimension = "distribution"
            isDefault = true
            for ((field, key) in firebaseFields) buildConfigField("String", field, "\"" + firebaseProperties.getProperty(key, "").replace("\"", "") + "\"")
        }
        create("foss") {
            dimension = "distribution"
            for ((field, _) in firebaseFields) buildConfigField("String", field, "\"\"")
        }
    }
    val hasUploadKey = keystoreProperties.getProperty("storeFile")?.let { rootProject.file(it).isFile } == true
    signingConfigs {
        if (hasUploadKey) create("upload") {
            storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        debug {
            // `-PdevSuffix=.dev` installs a debug build beside the Play Store one on the same
            // device, with its own data. Without it the debug build keeps the Play package name.
            (project.findProperty("devSuffix") as String?)?.takeIf { it.isNotBlank() }?.let { applicationIdSuffix = it; versionNameSuffix = "-dev" }
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (hasUploadKey) "upload" else "debug")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    androidResources { noCompress += listOf("ttf") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Bundled templates and the Studio editor are the same files the Apple apps ship.
    sourceSets["main"].assets.srcDirs(
        "src/main/assets",
        "../../Shared/ScriptWidgetRuntime/Resource",
        "../../iOS/ScriptWidget/View/CodeEditor/MirrorEditor",
    )
}

dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.navigation:navigation-compose:2.10.2")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    "playImplementation"("com.google.firebase:firebase-messaging:26.0.2")
    // The Health Connect permission contract used by the System Access screen.
    implementation("androidx.health.connect:connect-client:1.1.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
