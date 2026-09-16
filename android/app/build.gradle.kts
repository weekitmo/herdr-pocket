// `Properties` is IMPORTED rather than written as `java.util.Properties`, and
// that is not style: with AGP 9's new DSL there is a `java` extension in the
// script's scope, and it shadows the `java` package — `java.util.Properties()`
// fails to resolve with "Unresolved reference 'util'".
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --------------------------------------------------------------- signing ----
//
// WHERE THE RELEASE KEY COMES FROM. Two sources, environment first:
//
//   CI      `ANDROID_KEYSTORE_*` repository secrets. .github/workflows/
//           release.yml writes the base64 keystore to a temp file outside the
//           checkout and exports ANDROID_KEYSTORE_PATH at it.
//   local   `android/key.properties` — `storeFile`, `storePassword`,
//           `keyAlias`, `keyPassword` — pointing at a keystore on disk.
//
// Neither is in the repository, and `android/key.properties` plus `*.jks` are
// in `.gitignore` so that neither can arrive there by accident. A keystore in
// history is worse than no keystore: it cannot be un-published, and the only
// remedy is a new application id.
//
// WITH NEITHER SET, the release build is signed with Flutter's template debug
// key. That is not a fallback anybody should ship — see the note in
// `tool/build_release.sh` about `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — but it is
// what makes `flutter build apk --release`, `patrol test` and a fresh clone work
// with no setup at all, and the CI job prints a warning naming the secrets.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { stream -> keyProperties.load(stream) }
}

fun signingValue(envName: String, propertyName: String): String? =
    (System.getenv(envName) ?: keyProperties.getProperty(propertyName))
        ?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")

val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

android {
    namespace = "dev.maddax.herdrpocket"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications: it uses java.time, which
        // only exists on newer Android runtimes. Desugaring back-fills it so
        // the app keeps working on older devices instead of raising the
        // minimum SDK for one dependency.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.maddax.herdrpocket"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // --- Patrol (see patrol_test/ and pubspec.yaml) -------------------
        //
        // THE RUNNER IS THE WHOLE MECHANISM. Flutter's default runner
        // (`AndroidJUnitRunner`) starts the app and stops there; it has no
        // channel to the Dart test process, so a `patrolTest` has nothing to
        // attach to. `PatrolJUnitRunner` starts the app, WAITS for Patrol's
        // on-device service, and asks it which Dart test to run — which is how
        // a test can touch the notification shade or a permission dialog that
        // Flutter itself cannot reach.
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        // Each test gets a fresh process. Without it, state written by one test
        // (a saved host, a toggled setting in SharedPreferences) is inherited by
        // the next, and the failure surfaces as "this test passes alone".
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    testOptions {
        // AndroidX Test Orchestrator is what actually enforces the per-test
        // process the argument above asks for — the argument alone is a
        // request, and Orchestrator is the thing that honours it.
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    // Declared BEFORE `buildTypes` because `buildTypes.release` below looks one
    // up by name — AGP evaluates the two blocks in the order they appear.
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // An ABSOLUTE path in CI (the temp file the workflow wrote) and
                // whatever `key.properties` says on a laptop, resolved against
                // `android/app/`.
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                // v3 carries a proof-of-rotation, which is what lets the signing
                // key be replaced later WITHOUT every installed copy having to be
                // uninstalled first — and uninstalling deletes the user's saved
                // machines. v2 alone is enough to install on every device this
                // app supports (minSdk 24), so the APK stays installable either
                // way; v3 is the part that makes a lost keystore recoverable.
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Flutter's template debug key. `flutter run --release` and
                // `patrol test` work with no setup, and `adb install -r`
                // upgrades the copy already on the phone — which is the point
                // while this app is side-loaded. It is NOT distributable; see
                // the comment above `hasReleaseSigning`.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Backs the SAF code in MainActivity: `DocumentFile.fromTreeUri` and
    // `createFile`. It is a small AndroidX helper — `DocumentsContract` in the
    // platform SDK creates documents but gives no object to search an existing
    // directory with — and it is what makes "write a file into a folder the
    // user picked once" about twenty lines instead of two hundred.
    implementation("androidx.documentfile:documentfile:1.0.1")

    // Patrol's `testOptions.execution = ANDROIDX_TEST_ORCHESTRATOR` above is a
    // promise on the test APK; this is the runner that keeps it. Without the
    // line, `patrol test` fails at install time with "Test orchestrator ...
    // not found", which reads like a network problem and is not one.
    androidTestUtil("androidx.test:orchestrator:1.5.1")
}
