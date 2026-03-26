import com.android.build.api.variant.FilterConfiguration
import com.android.tools.build.jetifier.core.utils.Log
import org.gradle.kotlin.dsl.getByName
import java.io.FileInputStream
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

val versionMajor = 7
val versionMinor = 1
val versionPatch = 1

val abiCodes = mapOf(
    "armeabi-v7a" to 1,
    "arm64-v8a" to 2,
    "x86" to 3,
    "x86_64" to 4
)

android {
    namespace = "com.deniscerri.ytdl.ffmpeg"
    compileSdk = 36
    
    val properties = Properties()
    val propertiesFile = rootProject.file("keystore.properties")

    if (propertiesFile.exists()) {
        try {
            FileInputStream(propertiesFile).use { stream ->
                properties.load(stream)
            }

            signingConfigs {
                getByName("debug") {
                    storeFile = file(properties.getProperty("signingConfig.storeFile"))
                    storePassword = properties.getProperty("signingConfig.storePassword")
                    keyAlias = properties.getProperty("signingConfig.keyAlias")
                    keyPassword = properties.getProperty("signingConfig.keyPassword")
                }
            }
        } catch (e: Exception) {}
    }

    defaultConfig {
        applicationId = "com.deniscerri.ytdl.ffmpeg"
        minSdk = 24
        targetSdk = 36

        // Base version code
        versionCode = versionMajor * 1000000 + versionMinor * 10000 + versionPatch * 100
        versionName = "$versionMajor.$versionMinor.$versionPatch"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
            isUniversalApk = true
        }
    }

    //noinspection WrongGradleMethod
    androidComponents {
        onVariants { variant ->
            variant.outputs.forEach { output ->
                val abiName = output.filters.find {
                    it.filterType == FilterConfiguration.FilterType.ABI
                }?.identifier

                val abiCode = abiCodes[abiName] ?: 0
                val baseCode = versionMajor * 1000000 + versionMinor * 10000 + versionPatch * 100

                // Set the version code directly using the base code + ABI offset
                output.versionCode.set(baseCode + abiCode)
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
}