import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
// Shared root .env (gitignored). Simple KEY=value lines; # starts a comment.
val dotEnv: Map<String, String> = rootProject.file(".env").takeIf { it.exists() }?.readLines().orEmpty()
    .map { it.trim() }
    .filter { it.isNotEmpty() && !it.startsWith("#") && "=" in it }
    .associate { it.substringBefore("=").trim() to it.substringAfter("=").trim().removeSurrounding("\"") }
fun configString(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "com.rayguardian.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.rayguardian.app"
        minSdk = 31
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
        manifestPlaceholders["mwdat_application_id"] = localProperties.getProperty("mwdat_application_id", "0")
        manifestPlaceholders["mwdat_client_token"] = localProperties.getProperty("mwdat_client_token", "0")
    }
    buildTypes {
        debug {
            buildConfigField("String", "AI_BASE_URL", configString(dotEnv["AI_BASE_URL"]?.ifBlank { null } ?: "http://10.0.2.2:8787"))
            buildConfigField("String", "AI_CLIENT_TOKEN", configString(dotEnv["RAY_GUARDIAN_CLIENT_TOKEN"].orEmpty()))
        }
        release {
            // This development token is never shipped in a release APK.
            buildConfigField("String", "AI_BASE_URL", "\"\"")
            buildConfigField("String", "AI_CLIENT_TOKEN", "\"\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { buildConfig = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }

dependencies {
    implementation("androidx.activity:activity-ktx:1.12.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("com.meta.wearable:mwdat-core:1.0.1")
    debugImplementation("com.meta.wearable:mwdat-mockdevice:1.0.1")
    testImplementation("junit:junit:4.13.2")
}
