allprojects {
    repositories {
        // 阿里云镜像优先,解决国内连 google/maven 超时
        maven(url = "https://maven.aliyun.com/repository/google")
        maven(url = "https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 统一把所有 Flutter 插件的 compileSdk 抬到 36。
// 原因:部分插件(如 flutter_blue_plus_android)自己只声明 compileSdk 33,
// 但它们依赖的 AndroidX 库要求 34+,构建会直接失败。
//
// 必须放在下面的 evaluationDependsOn 之前:那句会提前求值 :app,
// 之后再调 afterEvaluate 会报 "project is already evaluated"。
fun Project.forceCompileSdk36() {
    val androidExt = extensions.findByName("android") ?: return
    runCatching {
        androidExt.javaClass
            .getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
            .invoke(androidExt, 36)
    }.onFailure {
        runCatching {
            androidExt.javaClass
                .getMethod("setCompileSdk", Integer::class.java)
                .invoke(androidExt, 36)
        }
    }
}

subprojects {
    // 已求值的项目直接改,未求值的等求值后再改
    if (state.executed) {
        forceCompileSdk36()
    } else {
        afterEvaluate { forceCompileSdk36() }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
