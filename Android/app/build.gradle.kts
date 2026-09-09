plugins {
    id("com.android.application")
}

android {
    namespace = "app.porter.companion"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.porter.companion"
        // The companion's shared-storage server depends on Android 11's
        // all-files access model. Advertising older support only turns a
        // missing platform API into a startup crash.
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
