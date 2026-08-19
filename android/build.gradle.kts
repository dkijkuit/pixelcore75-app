allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    if (name != "app") {
        afterEvaluate {
            // Force plugin subprojects that pin an old compileSdk (e.g. flutter_blue_plus_android
            // pins 33) to compile against the app's SDK version.
            extensions.findByType(com.android.build.api.dsl.CommonExtension::class.java)?.apply {
                if ((compileSdk ?: 0) < 36) {
                    compileSdk = 36
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
