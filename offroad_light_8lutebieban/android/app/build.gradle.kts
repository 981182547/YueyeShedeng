plugins {
    id("com.android.application")
    // 这一行不能少：下面用了 kotlin { compilerOptions { ... } }，
    // 而它由 Kotlin Gradle 插件提供。settings.gradle.kts 里这个插件是
    // apply false（只声明版本不应用），gradle.properties 又设了
    // android.builtInKotlin=false 关掉 AGP 9 的内置 Kotlin，
    // 两头都不提供 kotlin{} 扩展，缺了它脚本会直接编译失败：
    //   Unresolved reference 'compilerOptions' / 'jvmTarget'
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.offroad_light"
    // 閽夋鍦ㄥ凡瀹夎鐨勭ǔ瀹氱増 36銆備笉瑕佺敤 flutter.compileSdkVersion,
    // 鍚﹀垯鎻掍欢鍙兘鎶婂畠鎷夊埌棰勮鐗?SDK 37(鐩綍鍚?android-37.0,鏋勫缓浼氭壘涓嶅埌)
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.offroad_light"
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
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

