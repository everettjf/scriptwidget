plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.everettjf.scriptwidget"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    ndkVersion = "28.1.13356709"

    defaultConfig {
        applicationId = "com.everettjf.scriptwidget"
        minSdk = 35
        targetSdk = 36
        versionCode = 3
        versionName = "1.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Local builds are signed with the debug key; store uploads use a release key supplied outside the repository.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true }
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
    // The Health Connect permission contract used by the System Access screen.
    implementation("androidx.health.connect:connect-client:1.1.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
