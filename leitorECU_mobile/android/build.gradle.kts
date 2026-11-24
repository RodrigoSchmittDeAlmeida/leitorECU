allprojects {
    repositories {
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
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android")
            if (androidExt != null) {
                val setter = androidExt.javaClass.methods.firstOrNull {
                    it.name == "setCompileSdk" && it.parameterCount == 1 &&
                        (it.parameterTypes[0] == Int::class.javaPrimitiveType ||
                         it.parameterTypes[0] == Integer::class.java)
                }
                setter?.invoke(androidExt, 37)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
