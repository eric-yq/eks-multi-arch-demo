/*
 * JNI 桥接层：把 archdemo_native 的 C 接口暴露给 com.example.archdemo.NativeLib。
 *
 * 函数名规则：Java_<包名下划线化>_<类名>_<方法名>
 * 这里对应 com.example.archdemo.NativeLib 的 static native 方法。
 */
#include <jni.h>
#include <stdlib.h>

#include "archdemo_native.h"

JNIEXPORT jstring JNICALL
Java_com_example_archdemo_NativeLib_nativeInfo(JNIEnv *env, jclass clazz) {
    (void)clazz;
    return (*env)->NewStringUTF(env, archdemo_native_info());
}

JNIEXPORT jstring JNICALL
Java_com_example_archdemo_NativeLib_nativeArch(JNIEnv *env, jclass clazz) {
    (void)clazz;
    return (*env)->NewStringUTF(env, archdemo_native_arch());
}

/*
 * 用 GetPrimitiveArrayCritical 拿裸指针，避免大数组拷贝。
 * 临界区内不能回调 JNI / 不能触发 GC，这里只是纯计算，符合要求。
 */
static jlong run_loop(JNIEnv *env, jbyteArray data, jint iterations, int use_crc) {
    if (data == NULL || iterations <= 0) {
        return 0;
    }
    jsize len = (*env)->GetArrayLength(env, data);
    if (len <= 0) {
        return 0;
    }

    void *buf = (*env)->GetPrimitiveArrayCritical(env, data, NULL);
    if (buf == NULL) {
        return 0;
    }

    uint64_t result = use_crc
        ? archdemo_crc32_loop((const uint8_t *)buf, (size_t)len, (uint32_t)iterations)
        : archdemo_fnv1a64_loop((const uint8_t *)buf, (size_t)len, (uint32_t)iterations);

    (*env)->ReleasePrimitiveArrayCritical(env, data, buf, JNI_ABORT);
    return (jlong)result;
}

JNIEXPORT jlong JNICALL
Java_com_example_archdemo_NativeLib_crc32Loop(JNIEnv *env, jclass clazz,
                                              jbyteArray data, jint iterations) {
    (void)clazz;
    return run_loop(env, data, iterations, 1);
}

JNIEXPORT jlong JNICALL
Java_com_example_archdemo_NativeLib_fnv1a64Loop(JNIEnv *env, jclass clazz,
                                                jbyteArray data, jint iterations) {
    (void)clazz;
    return run_loop(env, data, iterations, 0);
}
