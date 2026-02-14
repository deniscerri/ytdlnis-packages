import com.android.build.api.variant.FilterConfiguration

plugins {
    alias(libs.plugins.android.application)
}

val versionMajor = 25
val versionMinor = 3
val versionPatch = 0

val abiCodes = mapOf(
    "armeabi-v7a" to 1,
    "arm64-v8a" to 2,
    "x86" to 3,
    "x86_64" to 4
)

android {
    namespace = "com.deniscerri.ytdl.nodejs"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.deniscerri.ytdl.nodejs"
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
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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