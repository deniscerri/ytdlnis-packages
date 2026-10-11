import java.util.Properties
import java.util.Base64
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.library)
    `maven-publish`
    signing
}


object LibraryConfig {
    const val GROUP_ID = "io.github.deniscerri"
    const val ARTIFACT_ID = "ytdlnis_packages.bash"
    const val VERSION = "1.0.0"
    const val NAME = "Bash JNI Library"
    const val DESCRIPTION = "Native shared bash libraries built from termux-packages packaged for Android"
    const val NAMESPACE = "com.deniscerri.ytdl.bash.library"
}

val secretProperties = Properties()
val secretPropertiesFile = rootProject.file("keystore.properties")

if (secretPropertiesFile.exists()) {
    runCatching {
        secretPropertiesFile.inputStream().use { stream ->
            secretProperties.load(stream)
        }
    }
}

fun findSecret(key: String, vararg fallbackKeys: String): String? {
    secretProperties.getProperty(key)?.takeIf { it.isNotEmpty() }?.let { return it }
    for (fallback in fallbackKeys) {
        secretProperties.getProperty(fallback)?.takeIf { it.isNotEmpty() }?.let { return it }
    }

    val provider = providers.gradleProperty(key)
        .orElse(providers.gradleProperty(fallbackKeys.firstOrNull() ?: ""))
        .orNull
    if (!provider.isNullOrEmpty()) return provider

    val envKey = key.replace('.', '_').uppercase()
    return System.getenv(envKey)
}

val gpgKeyId = findSecret("signing.keyId")
val gpgKey = findSecret("signing.key")
val gpgPassword = findSecret("signing.password")


android {
    namespace = LibraryConfig.NAMESPACE
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add(file("src/main/jniLibs").toString())
        }
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

// Dummy Javadoc JAR required by Sonatype for AAR artifacts
val javadocJar by tasks.registering(Jar::class) {
    archiveClassifier.set("javadoc")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifact(javadocJar.get())

                groupId = LibraryConfig.GROUP_ID
                artifactId = LibraryConfig.ARTIFACT_ID
                version = LibraryConfig.VERSION

                pom {
                    name.set(LibraryConfig.NAME)
                    description.set(LibraryConfig.DESCRIPTION)
                    url.set("https://github.com/deniscerri/ytdlnis-packages")

                    licenses {
                        license {
                            name.set("GNU General Public License v3.0")
                            url.set("https://www.gnu.org/licenses/gpl-3.0.txt")
                        }
                    }

                    developers {
                        developer {
                            id.set("deniscerri")
                            name.set("Denis Çerri")
                            email.set("deniscerri7@gmail.com")
                        }
                    }

                    scm {
                        connection.set("scm:git:git://github.com/deniscerri/ytdlnis-packages.git")
                        developerConnection.set("scm:git:ssh://github.com/deniscerri/ytdlnis-packages.git")
                        url.set("https://github.com/deniscerri/ytdlnis-packages")
                    }
                }
            }
        }
    }
}

signing {
    val rawKey = gpgKey?.trim()
    val pass = gpgPassword?.trim()

    if (!rawKey.isNullOrEmpty() && !pass.isNullOrEmpty()) {
        val decodedKey = try {
            if (rawKey.startsWith("-----BEGIN PGP")) {
                rawKey
            } else {
                val cleanBase64 = rawKey.replace("\\s+".toRegex(), "")
                String(Base64.getDecoder().decode(cleanBase64))
            }
        } catch (_: Exception) {
            rawKey
        }

        useInMemoryPgpKeys(decodedKey, pass)
        sign(publishing.publications)
    }
}

val zipMavenPublication by tasks.registering(Zip::class) {
    // Force publishing to local maven FIRST before running zip
    dependsOn("publishReleasePublicationToMavenLocal")

    val groupIdPath = LibraryConfig.GROUP_ID.replace('.', '/')
    val artifactId = LibraryConfig.ARTIFACT_ID
    val version = LibraryConfig.VERSION

    val m2Dir = file("${System.getProperty("user.home")}/.m2/repository/$groupIdPath/$artifactId/$version")

    // Ensure checksums exist in m2Dir before zipping
    doFirst {
        if (m2Dir.exists()) {
            m2Dir.listFiles()?.forEach { file ->
                if (file.isFile && !file.name.endsWith(".md5") && !file.name.endsWith(".sha1")) {
                    val md5File = file("${file.absolutePath}.md5")
                    val sha1File = file("${file.absolutePath}.sha1")

                    if (!md5File.exists()) {
                        val md5 = MessageDigest.getInstance("MD5").digest(file.readBytes())
                        md5File.writeText(md5.joinToString("") { "%02x".format(it) })
                    }
                    if (!sha1File.exists()) {
                        val sha1 = MessageDigest.getInstance("SHA-1").digest(file.readBytes())
                        sha1File.writeText(sha1.joinToString("") { "%02x".format(it) })
                    }
                }
            }
        }
    }

    into("$groupIdPath/$artifactId/$version") {
        from(m2Dir)
    }

    archiveFileName.set("$artifactId-$version-bundle.zip")
    destinationDirectory.set(layout.buildDirectory.dir("outputs/maven"))
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}