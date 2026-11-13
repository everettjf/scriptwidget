plugins {
    id("com.android.library")
}

android {
    namespace = "com.everettjf.scriptwidget.core"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    ndkVersion = "28.1.13356709"

    defaultConfig {
        minSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_STL=none") } }
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    androidResources { noCompress += listOf("ttf") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.19.1")
    // $health reads through Health Connect. Unit tests use a fake HealthPlatform and never touch the client.
    implementation("androidx.health.connect:connect-client:1.1.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    testImplementation("junit:junit:4.13.2")
    // android.jar only ships throwing stubs of org.json; local unit tests need a real implementation.
    testImplementation("org.json:json:20240303")
}
