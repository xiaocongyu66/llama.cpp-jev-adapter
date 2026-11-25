import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.android.application)
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    jvm("desktop") {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.compose.runtime)
            implementation(libs.compose.foundation)
            implementation(libs.compose.material3)
            implementation(libs.compose.ui)
            implementation(libs.androidx.lifecycle.viewmodel.compose)
            implementation(libs.androidx.lifecycle.runtime.compose)
            implementation(libs.coroutines.core)
            implementation(libs.kotlinx.datetime)
            implementation(libs.ktor.server.core)
            implementation(libs.ktor.server.cio)
            implementation(libs.ktor.client.cio)
            implementation(libs.ktor.client.content.negotiation)
            implementation(libs.ktor.serialization.kotlinx.json)
            implementation(libs.kotlinx.serialization.json)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        androidMain.dependencies {
            implementation(libs.androidx.security.crypto)
            implementation(libs.androidx.activity.compose)
            implementation(libs.androidx.core.ktx)
            implementation(libs.compose.ui.tooling)
        }
        val desktopMain by getting {
            dependencies {
                implementation(compose.desktop.currentOs)
            }
        }
    }
}

android {
    namespace = "com.example.local_model_hub"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.local_model_hub"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.2.0"
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        jniLibs.useLegacyPackaging = false
    }
}

compose.desktop {
    application {
        mainClass = "com.joyfox.localmodelhub.MainKt"
        nativeDistributions {
            packageName = "Local Model Hub"
            packageVersion = "0.2.0"
            targetFormats(org.jetbrains.compose.desktop.application.dsl.TargetFormat.Deb, org.jetbrains.compose.desktop.application.dsl.TargetFormat.Rpm)
        }
    }
}
