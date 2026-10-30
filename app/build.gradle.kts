import com.android.build.api.variant.FilterConfiguration
import java.io.FileInputStream
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

data class AppVersion(val major: Int, val minor: Int, val patch: Int) {
    val versionCode: Int get() = major * 1_000_000 + minor * 10_000 + patch * 100
    val versionName: String get() = "$major.$minor.$patch"
}

val flavorVersions = mapOf(
    "nodejs" to Pair("NodeJS", AppVersion(major = 26, minor = 12, patch = 1)),
    "deno" to Pair("Deno", AppVersion(major = 2, minor = 7, patch = 7)),
    "python" to Pair("Python", AppVersion(major = 3, minor = 14, patch = 8)),
    "ffmpeg" to Pair("FFmpeg", AppVersion(major = 7, minor = 1, patch = 1)),
)

val abiCodes = mapOf(
    "armeabi-v7a" to 1,
    "arm64-v8a" to 2,
    "x86" to 3,
    "x86_64" to 4
)

android {
    namespace = "com.deniscerri.ytdl"
    compileSdk = 36

    val properties = Properties()
    val propertiesFile = rootProject.file("keystore.properties")
    if (propertiesFile.exists()) {
        runCatching {
            FileInputStream(propertiesFile).use { properties.load(it) }
        }
    }

    signingConfigs {
        getByName("debug") {
            if (propertiesFile.exists()) {
                storeFile = file(properties.getProperty("signingConfig.storeFile"))
                storePassword = properties.getProperty("signingConfig.storePassword")
                keyAlias = properties.getProperty("signingConfig.keyAlias")
                keyPassword = properties.getProperty("signingConfig.keyPassword")
            }
        }
    }

    defaultConfig {
        minSdk = 24
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // 1. Define the Backend Engine Dimension
    flavorDimensions += "engine"

    productFlavors {
        flavorVersions.forEach { (flavorName, nameVersion) ->
            create(flavorName) {
                dimension = "engine"
                applicationId = "com.deniscerri.ytdl.$flavorName"
                versionCode = nameVersion.second.versionCode
                versionName = nameVersion.second.versionName
                resValue("string", "app_name", "YTDLnis ${nameVersion.first} Package")
            }
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
            isUniversalApk = true
        }
    }

// 4. Centralized ABI Version Code Resolver
    //noinspection WrongGradleMethod
    androidComponents {
        onVariants { variant ->
            // Reads the flavor name dynamically (e.g. "nodejs", "deno")
            val flavorName = variant.flavorName
            val baseVersion = flavorVersions[flavorName]?.second

            variant.outputs.forEach { output ->
                val abiName = output.filters.find {
                    it.filterType == FilterConfiguration.FilterType.ABI
                }?.identifier

                val abiCode = abiCodes[abiName] ?: 0
                val baseCode = baseVersion?.versionCode ?: 0

                // Sets version code: [Flavor Base Version Code] + [ABI Code]
                output.versionCode.set(baseCode + abiCode)
            }
        }
    }

    buildFeatures {
        resValues = true
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
    "pythonImplementation"(project(":python_library"))
    "ffmpegImplementation"(project(":ffmpeg_library"))
    "nodejsImplementation"(project(":nodejs_library"))
    "denoImplementation"(project(":deno_library"))

    // Common core UI and library logic
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
}