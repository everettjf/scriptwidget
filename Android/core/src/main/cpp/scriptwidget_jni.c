// JNI binding between Kotlin and QuickJS-NG. One Engine owns one runtime and
// one context. All entry points must be called from the thread that created
// the engine. Strings cross the boundary as UTF-16 so astral characters and
// lone surrogates survive unchanged.

#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs/quickjs.h"

typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    JNIEnv *env;
    jobject host;
    jmethodID hostCall;
    int64_t deadlineNanos;
    bool interrupted;
} Engine;

static int64_t monotonicNanos(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int interruptHandler(JSContext *ctx, void *opaque) {
    (void)ctx;
    Engine *engine = (Engine *)opaque;
    if (engine->interrupted) return 1;
    if (engine->deadlineNanos > 0 && monotonicNanos() > engine->deadlineNanos) {
        engine->interrupted = true;
        return 1;
    }
    return 0;
}

static JSValue jsStringFromJava(Engine *engine, jstring text) {
    if (text == NULL) return JS_NULL;
    JNIEnv *env = engine->env;
    jsize length = (*env)->GetStringLength(env, text);
    const jchar *chars = (*env)->GetStringChars(env, text, NULL);
    if (chars == NULL) return JS_ThrowInternalError(engine->ctx, "out of memory");
    JSValue value = JS_NewStringUTF16(engine->ctx, (const uint16_t *)chars, (size_t)length);
    (*env)->ReleaseStringChars(env, text, chars);
    return value;
}

// Returns NULL for undefined/null, or when conversion throws (the JS
// exception stays pending in that case).
static jstring javaStringFromJS(Engine *engine, JSValueConst value, bool *failed) {
    *failed = false;
    if (JS_IsUndefined(value) || JS_IsNull(value)) return NULL;
    size_t length = 0;
    const uint16_t *chars = JS_ToCStringLenUTF16(engine->ctx, &length, value);
    if (chars == NULL) { *failed = true; return NULL; }
    jstring result = (*engine->env)->NewString(engine->env, (const jchar *)chars, (jsize)length);
    JS_FreeCStringUTF16(engine->ctx, chars);
    return result;
}

static void appendProperty(Engine *engine, JSValueConst error, const char *name, char *buffer, size_t capacity, const char *prefix) {
    JSValue value = JS_GetPropertyStr(engine->ctx, error, name);
    if (!JS_IsUndefined(value) && !JS_IsNull(value) && !JS_IsException(value)) {
        const char *text = JS_ToCString(engine->ctx, value);
        if (text != NULL) {
            size_t used = strlen(buffer);
            if (text[0] != '\0' && used + strlen(prefix) + 1 < capacity) {
                strncat(buffer, prefix, capacity - used - 1);
                used = strlen(buffer);
                strncat(buffer, text, capacity - used - 1);
            }
            JS_FreeCString(engine->ctx, text);
        }
    } else if (JS_IsException(value)) {
        JS_FreeValue(engine->ctx, JS_GetException(engine->ctx));
    }
    JS_FreeValue(engine->ctx, value);
}

// Converts the pending JS exception into a Java JsException.
static void throwPendingException(Engine *engine) {
    JNIEnv *env = engine->env;
    JSContext *ctx = engine->ctx;
    JSValue error = JS_GetException(ctx);
    char message[8192];
    message[0] = '\0';
    const char *text = JS_ToCString(ctx, error);
    if (text != NULL) {
        strncat(message, text, sizeof(message) - 1);
        JS_FreeCString(ctx, text);
    } else {
        JS_FreeValue(ctx, JS_GetException(ctx));
        strncat(message, "unknown error", sizeof(message) - 1);
    }
    if (JS_IsError(error)) appendProperty(engine, error, "stack", message, sizeof(message), "\n");
    JS_FreeValue(ctx, error);

    jclass type = (*env)->FindClass(env, "com/everettjf/scriptwidget/core/js/JsException");
    if (type == NULL) return;
    jmethodID constructor = (*env)->GetMethodID(env, type, "<init>", "(Ljava/lang/String;Z)V");
    // Messages are produced by JS_ToCString (UTF-8); replace bytes that
    // Modified UTF-8 cannot carry so NewStringUTF never aborts.
    for (unsigned char *cursor = (unsigned char *)message; *cursor; cursor += 1) {
        if (*cursor >= 0xF0) {
            for (int index = 0; index < 4 && cursor[index]; index += 1) cursor[index] = '?';
        }
    }
    jstring javaMessage = (*env)->NewStringUTF(env, message);
    jobject exception = (*env)->NewObject(env, type, constructor, javaMessage, (jboolean)engine->interrupted);
    if (exception != NULL) (*env)->Throw(env, (jthrowable)exception);
}

// __swNative(op, payload) -> string | null. Synchronous call into Kotlin.
static JSValue hostCall(JSContext *ctx, JSValueConst thisValue, int argc, JSValueConst *argv) {
    (void)thisValue;
    Engine *engine = (Engine *)JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    JNIEnv *env = engine->env;
    if (argc < 1) return JS_ThrowTypeError(ctx, "__swNative requires an operation");
    bool failed = false;
    jstring operation = javaStringFromJS(engine, argv[0], &failed);
    if (failed) return JS_EXCEPTION;
    jstring payload = NULL;
    if (argc > 1) {
        payload = javaStringFromJS(engine, argv[1], &failed);
        if (failed) { (*env)->DeleteLocalRef(env, operation); return JS_EXCEPTION; }
    }
    jstring result = (jstring)(*env)->CallObjectMethod(env, engine->host, engine->hostCall, operation, payload);
    if (operation != NULL) (*env)->DeleteLocalRef(env, operation);
    if (payload != NULL) (*env)->DeleteLocalRef(env, payload);
    if ((*env)->ExceptionCheck(env)) {
        jthrowable thrown = (*env)->ExceptionOccurred(env);
        (*env)->ExceptionClear(env);
        jclass throwableClass = (*env)->FindClass(env, "java/lang/Throwable");
        jmethodID getMessage = (*env)->GetMethodID(env, throwableClass, "getMessage", "()Ljava/lang/String;");
        jstring message = (jstring)(*env)->CallObjectMethod(env, thrown, getMessage);
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); message = NULL; }
        JSValue error = JS_NewError(ctx);
        JSValue text = message != NULL ? jsStringFromJava(engine, message) : JS_NewString(ctx, "native host error");
        JS_SetPropertyStr(ctx, error, "message", text);
        if (message != NULL) (*env)->DeleteLocalRef(env, message);
        (*env)->DeleteLocalRef(env, thrown);
        (*env)->DeleteLocalRef(env, throwableClass);
        return JS_Throw(ctx, error);
    }
    if (result == NULL) return JS_NULL;
    JSValue value = jsStringFromJava(engine, result);
    (*env)->DeleteLocalRef(env, result);
    return value;
}

// __swEvaluate(code, fileName): classic-script evaluation in the global
// lexical scope, like JSContext.evaluateScript. Indirect eval would scope
// top-level let/const/class to the call and hide them from later scripts.
static JSValue evaluateGlobal(JSContext *ctx, JSValueConst thisValue, int argc, JSValueConst *argv) {
    (void)thisValue;
    if (argc < 1) return JS_ThrowTypeError(ctx, "__swEvaluate requires source text");
    size_t length = 0;
    const char *code = JS_ToCStringLen(ctx, &length, argv[0]);
    if (code == NULL) return JS_EXCEPTION;
    const char *name = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
    JSValue result = JS_Eval(ctx, code, length, name != NULL ? name : "script.js", JS_EVAL_TYPE_GLOBAL);
    if (name != NULL) JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, code);
    return result;
}

static Engine *enter(JNIEnv *env, jlong pointer) {
    Engine *engine = (Engine *)(intptr_t)pointer;
    engine->env = env;
    JS_UpdateStackTop(engine->rt);
    return engine;
}

JNIEXPORT jlong JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeCreate(JNIEnv *env, jobject thiz, jobject host, jlong memoryLimit, jlong stackSize) {
    (void)thiz;
    Engine *engine = (Engine *)calloc(1, sizeof(Engine));
    if (engine == NULL) return 0;
    engine->rt = JS_NewRuntime();
    if (engine->rt == NULL) { free(engine); return 0; }
    JS_SetRuntimeOpaque(engine->rt, engine);
    if (memoryLimit > 0) JS_SetMemoryLimit(engine->rt, (size_t)memoryLimit);
    if (stackSize > 0) JS_SetMaxStackSize(engine->rt, (size_t)stackSize);
    JS_SetInterruptHandler(engine->rt, interruptHandler, engine);
    engine->ctx = JS_NewContext(engine->rt);
    if (engine->ctx == NULL) { JS_FreeRuntime(engine->rt); free(engine); return 0; }
    engine->env = env;
    engine->host = (*env)->NewGlobalRef(env, host);
    jclass hostClass = (*env)->GetObjectClass(env, host);
    engine->hostCall = (*env)->GetMethodID(env, hostClass, "call", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    JSValue global = JS_GetGlobalObject(engine->ctx);
    JS_SetPropertyStr(engine->ctx, global, "__swNative", JS_NewCFunction(engine->ctx, hostCall, "__swNative", 2));
    JS_SetPropertyStr(engine->ctx, global, "__swEvaluate", JS_NewCFunction(engine->ctx, evaluateGlobal, "__swEvaluate", 2));
    JS_FreeValue(engine->ctx, global);
    return (jlong)(intptr_t)engine;
}

JNIEXPORT void JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeDestroy(JNIEnv *env, jobject thiz, jlong pointer) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    JS_FreeContext(engine->ctx);
    JS_FreeRuntime(engine->rt);
    (*env)->DeleteGlobalRef(env, engine->host);
    free(engine);
}

JNIEXPORT void JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeSetDeadline(JNIEnv *env, jobject thiz, jlong pointer, jlong millisecondsFromNow) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    engine->interrupted = false;
    engine->deadlineNanos = millisecondsFromNow > 0 ? monotonicNanos() + millisecondsFromNow * 1000000LL : 0;
}

static jstring finishValue(Engine *engine, JSValue value) {
    if (JS_IsException(value)) { throwPendingException(engine); return NULL; }
    bool failed = false;
    jstring result = javaStringFromJS(engine, value, &failed);
    JS_FreeValue(engine->ctx, value);
    if (failed) { throwPendingException(engine); return NULL; }
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeEvaluate(JNIEnv *env, jobject thiz, jlong pointer, jstring code, jstring fileName) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    // JS_Eval needs NUL-terminated UTF-8. Round-trip through a JS string so
    // the conversion from UTF-16 is done by the engine.
    JSValue source = jsStringFromJava(engine, code);
    if (JS_IsException(source)) { throwPendingException(engine); return NULL; }
    size_t length = 0;
    const char *utf8 = JS_ToCStringLen(engine->ctx, &length, source);
    JS_FreeValue(engine->ctx, source);
    if (utf8 == NULL) { throwPendingException(engine); return NULL; }
    const char *name = (*env)->GetStringUTFChars(env, fileName, NULL);
    JSValue value = JS_Eval(engine->ctx, utf8, length, name, JS_EVAL_TYPE_GLOBAL);
    (*env)->ReleaseStringUTFChars(env, fileName, name);
    JS_FreeCString(engine->ctx, utf8);
    return finishValue(engine, value);
}

JNIEXPORT jbyteArray JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeCompile(JNIEnv *env, jobject thiz, jlong pointer, jstring code, jstring fileName) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    JSValue source = jsStringFromJava(engine, code);
    if (JS_IsException(source)) { throwPendingException(engine); return NULL; }
    size_t length = 0;
    const char *utf8 = JS_ToCStringLen(engine->ctx, &length, source);
    JS_FreeValue(engine->ctx, source);
    if (utf8 == NULL) { throwPendingException(engine); return NULL; }
    const char *name = (*env)->GetStringUTFChars(env, fileName, NULL);
    JSValue function = JS_Eval(engine->ctx, utf8, length, name, JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    (*env)->ReleaseStringUTFChars(env, fileName, name);
    JS_FreeCString(engine->ctx, utf8);
    if (JS_IsException(function)) { throwPendingException(engine); return NULL; }
    size_t size = 0;
    uint8_t *bytes = JS_WriteObject(engine->ctx, &size, function, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(engine->ctx, function);
    if (bytes == NULL) { throwPendingException(engine); return NULL; }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)size);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize)size, (const jbyte *)bytes);
    js_free(engine->ctx, bytes);
    return result;
}

// Bytecode must come from nativeCompile in this app build; it is never read
// from packages or other untrusted input.
JNIEXPORT jstring JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeEvaluateBytecode(JNIEnv *env, jobject thiz, jlong pointer, jbyteArray bytecode) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    jsize size = (*env)->GetArrayLength(env, bytecode);
    jbyte *bytes = (*env)->GetByteArrayElements(env, bytecode, NULL);
    JSValue function = JS_ReadObject(engine->ctx, (const uint8_t *)bytes, (size_t)size, JS_READ_OBJ_BYTECODE);
    (*env)->ReleaseByteArrayElements(env, bytecode, bytes, JNI_ABORT);
    if (JS_IsException(function)) { throwPendingException(engine); return NULL; }
    return finishValue(engine, JS_EvalFunction(engine->ctx, function));
}

JNIEXPORT jstring JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeCall(JNIEnv *env, jobject thiz, jlong pointer, jstring functionName, jobjectArray arguments) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    JSContext *ctx = engine->ctx;
    const char *name = (*env)->GetStringUTFChars(env, functionName, NULL);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue function = JS_GetPropertyStr(ctx, global, name);
    (*env)->ReleaseStringUTFChars(env, functionName, name);
    jsize count = arguments != NULL ? (*env)->GetArrayLength(env, arguments) : 0;
    JSValue *values = count > 0 ? (JSValue *)calloc((size_t)count, sizeof(JSValue)) : NULL;
    for (jsize index = 0; index < count; index += 1) {
        jstring item = (jstring)(*env)->GetObjectArrayElement(env, arguments, index);
        values[index] = jsStringFromJava(engine, item);
        if (item != NULL) (*env)->DeleteLocalRef(env, item);
    }
    JSValue result = JS_Call(ctx, function, global, (int)count, values);
    for (jsize index = 0; index < count; index += 1) JS_FreeValue(ctx, values[index]);
    free(values);
    JS_FreeValue(ctx, function);
    JS_FreeValue(ctx, global);
    return finishValue(engine, result);
}

// Runs queued promise jobs. Returns the number executed, or -1 when a job
// threw (the exception is raised to Kotlin).
JNIEXPORT jint JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeRunJobs(JNIEnv *env, jobject thiz, jlong pointer, jint maximum) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    jint executed = 0;
    while (executed < maximum) {
        JSContext *jobContext = NULL;
        int status = JS_ExecutePendingJob(engine->rt, &jobContext);
        if (status == 0) break;
        if (status < 0) { throwPendingException(engine); return -1; }
        executed += 1;
    }
    return executed;
}

JNIEXPORT jlong JNICALL
Java_com_everettjf_scriptwidget_core_js_QuickJs_nativeMemoryUsed(JNIEnv *env, jobject thiz, jlong pointer) {
    (void)thiz;
    Engine *engine = enter(env, pointer);
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(engine->rt, &usage);
    return (jlong)usage.malloc_size;
}
