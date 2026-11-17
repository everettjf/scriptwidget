// C binding between the .NET host and QuickJS-NG, the Windows counterpart of
// Android/core/src/main/cpp/scriptwidget_jni.c. One Engine owns one runtime
// and one context. All entry points must be called from the thread that
// created the engine. Strings cross the boundary as UTF-16 so astral
// characters and lone surrogates survive unchanged.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <icu.h>

#include "quickjs.h"

#define SW_EXPORT __declspec(dllexport)

// Status of a call that produces a value.
#define SW_NULL 0       // undefined or null
#define SW_VALUE 1      // sw_result holds the string or the bytes
#define SW_EXCEPTION -1 // sw_result holds the message and stack

typedef struct Engine Engine;

// __swNative(op, payload). The host answers by calling sw_host_return or
// sw_host_throw before it returns; neither means null. A length of -1 is null.
typedef void (*sw_host_fn)(void *user, const uint16_t *operation, intptr_t operationLength, const uint16_t *payload, intptr_t payloadLength);

struct Engine {
    JSRuntime *rt;
    JSContext *ctx;
    sw_host_fn host;
    void *user;
    int64_t deadlineTicks;
    bool interrupted;
    // Answer of the host call in progress.
    JSValue hostResult;
    bool hostAnswered;
    bool hostThrew;
    // Result of the last call: UTF-16 text or raw bytes, owned by the engine.
    uint8_t *result;
    size_t resultLength; // UTF-16 code units for text, bytes for bytecode
    size_t resultCapacity;
};

// MARK: - Local time
//
// QuickJS on Windows answers Date's local-time questions with the offset
// that is in force right now, whatever the date asked about, so a date on
// the other side of a daylight-saving change comes out an hour off. The
// build replaces that with sw_timezone_offset (see CMakeLists.txt), which
// asks ICU for the offset at that instant in the host's time zone.

static SRWLOCK zoneLock = SRWLOCK_INIT;
static UChar zoneID[128];
static int32_t zoneLength = -1; // -1: ICU's default zone
static volatile LONG zoneGeneration = 1;
static __declspec(thread) UCalendar *threadCalendar;
static __declspec(thread) LONG threadGeneration;

// IANA zone name such as "America/Los_Angeles"; NULL or a negative length
// selects the system zone.
SW_EXPORT void sw_set_time_zone(const uint16_t *id, intptr_t length) {
    AcquireSRWLockExclusive(&zoneLock);
    if (id == NULL || length < 0 || length >= (intptr_t)(sizeof(zoneID) / sizeof(zoneID[0]))) zoneLength = -1;
    else { memcpy(zoneID, id, (size_t)length * sizeof(UChar)); zoneLength = (int32_t)length; }
    InterlockedIncrement(&zoneGeneration);
    ReleaseSRWLockExclusive(&zoneLock);
}

// Minutes to add to local time to get UTC at `time` (milliseconds since the
// epoch), like Date.prototype.getTimezoneOffset.
int sw_timezone_offset(int64_t time) {
    LONG generation = zoneGeneration;
    if (threadCalendar == NULL || threadGeneration != generation) {
        if (threadCalendar != NULL) { ucal_close(threadCalendar); threadCalendar = NULL; }
        UErrorCode status = U_ZERO_ERROR;
        AcquireSRWLockShared(&zoneLock);
        threadCalendar = ucal_open(zoneLength >= 0 ? zoneID : NULL, zoneLength, "en_US", UCAL_GREGORIAN, &status);
        ReleaseSRWLockShared(&zoneLock);
        if (U_FAILURE(status)) { threadCalendar = NULL; return 0; }
        threadGeneration = generation;
    }
    UErrorCode status = U_ZERO_ERROR;
    ucal_setMillis(threadCalendar, (UDate)time, &status);
    int32_t zone = ucal_get(threadCalendar, UCAL_ZONE_OFFSET, &status);
    int32_t daylight = ucal_get(threadCalendar, UCAL_DST_OFFSET, &status);
    if (U_FAILURE(status)) return 0;
    return -(zone + daylight) / 60000;
}

// MARK: - Engine

static int64_t ticksPerSecond(void) {
    static int64_t frequency;
    if (frequency == 0) { LARGE_INTEGER value; QueryPerformanceFrequency(&value); frequency = value.QuadPart; }
    return frequency;
}

static int64_t monotonicTicks(void) {
    LARGE_INTEGER value;
    QueryPerformanceCounter(&value);
    return value.QuadPart;
}

static int interruptHandler(JSContext *ctx, void *opaque) {
    (void)ctx;
    Engine *engine = (Engine *)opaque;
    if (engine->interrupted) return 1;
    if (engine->deadlineTicks > 0 && monotonicTicks() > engine->deadlineTicks) {
        engine->interrupted = true;
        return 1;
    }
    return 0;
}

static bool reserve(Engine *engine, size_t bytes) {
    if (bytes <= engine->resultCapacity) return true;
    size_t capacity = bytes + bytes / 2 + 64;
    uint8_t *grown = (uint8_t *)realloc(engine->result, capacity);
    if (grown == NULL) return false;
    engine->result = grown;
    engine->resultCapacity = capacity;
    return true;
}

static void setResultBytes(Engine *engine, const void *bytes, size_t length) {
    if (!reserve(engine, length)) { engine->resultLength = 0; return; }
    if (length > 0) memcpy(engine->result, bytes, length);
    engine->resultLength = length;
}

static void appendResultText(Engine *engine, const uint16_t *chars, size_t length) {
    if (!reserve(engine, (engine->resultLength + length) * sizeof(uint16_t))) return;
    if (length > 0) memcpy(engine->result + engine->resultLength * sizeof(uint16_t), chars, length * sizeof(uint16_t));
    engine->resultLength += length;
}

static void appendResultAscii(Engine *engine, const char *text) {
    for (const char *cursor = text; *cursor; cursor += 1) { uint16_t unit = (uint16_t)(unsigned char)*cursor; appendResultText(engine, &unit, 1); }
}

static JSValue stringFromHost(Engine *engine, const uint16_t *chars, intptr_t length) {
    if (chars == NULL || length < 0) return JS_NULL;
    return JS_NewStringUTF16(engine->ctx, chars, (size_t)length);
}

// Appends value converted to a string; returns false when conversion throws
// (the exception is cleared).
static bool appendValue(Engine *engine, JSValueConst value) {
    size_t length = 0;
    const uint16_t *chars = JS_ToCStringLenUTF16(engine->ctx, &length, value);
    if (chars == NULL) { JS_FreeValue(engine->ctx, JS_GetException(engine->ctx)); return false; }
    appendResultText(engine, chars, length);
    JS_FreeCStringUTF16(engine->ctx, chars);
    return true;
}

// Moves the pending JS exception into the result as "message\nstack".
static int takeException(Engine *engine) {
    JSContext *ctx = engine->ctx;
    JSValue error = JS_GetException(ctx);
    engine->resultLength = 0;
    if (!appendValue(engine, error)) appendResultAscii(engine, "unknown error");
    if (JS_IsError(error)) {
        JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
        if (JS_IsException(stack)) JS_FreeValue(ctx, JS_GetException(ctx));
        else if (!JS_IsUndefined(stack) && !JS_IsNull(stack)) {
            size_t before = engine->resultLength;
            appendResultAscii(engine, "\n");
            size_t afterSeparator = engine->resultLength;
            if (!appendValue(engine, stack) || engine->resultLength == afterSeparator) engine->resultLength = before;
        }
        JS_FreeValue(ctx, stack);
    }
    JS_FreeValue(ctx, error);
    return SW_EXCEPTION;
}

static int finishValue(Engine *engine, JSValue value) {
    if (JS_IsException(value)) return takeException(engine);
    if (JS_IsUndefined(value) || JS_IsNull(value)) { JS_FreeValue(engine->ctx, value); engine->resultLength = 0; return SW_NULL; }
    size_t length = 0;
    const uint16_t *chars = JS_ToCStringLenUTF16(engine->ctx, &length, value);
    JS_FreeValue(engine->ctx, value);
    if (chars == NULL) return takeException(engine);
    engine->resultLength = 0;
    appendResultText(engine, chars, length);
    JS_FreeCStringUTF16(engine->ctx, chars);
    return SW_VALUE;
}

// __swNative(op, payload) -> string | null. Synchronous call into the host.
static JSValue hostCall(JSContext *ctx, JSValueConst thisValue, int argc, JSValueConst *argv) {
    (void)thisValue;
    Engine *engine = (Engine *)JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    if (argc < 1) return JS_ThrowTypeError(ctx, "__swNative requires an operation");
    size_t operationLength = 0;
    const uint16_t *operation = JS_ToCStringLenUTF16(ctx, &operationLength, argv[0]);
    if (operation == NULL) return JS_EXCEPTION;
    const uint16_t *payload = NULL;
    size_t payloadLength = 0;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        payload = JS_ToCStringLenUTF16(ctx, &payloadLength, argv[1]);
        if (payload == NULL) { JS_FreeCStringUTF16(ctx, operation); return JS_EXCEPTION; }
    }
    // A host call can run JavaScript that makes another host call.
    JSValue outerResult = engine->hostResult;
    bool outerAnswered = engine->hostAnswered, outerThrew = engine->hostThrew;
    engine->hostResult = JS_NULL;
    engine->hostAnswered = false;
    engine->hostThrew = false;
    engine->host(engine->user, operation, (intptr_t)operationLength, payload, payload != NULL ? (intptr_t)payloadLength : -1);
    JS_FreeCStringUTF16(ctx, operation);
    if (payload != NULL) JS_FreeCStringUTF16(ctx, payload);
    JSValue result = engine->hostResult;
    bool threw = engine->hostThrew;
    engine->hostResult = outerResult;
    engine->hostAnswered = outerAnswered;
    engine->hostThrew = outerThrew;
    if (threw) {
        JSValue error = JS_NewError(ctx);
        JS_SetPropertyStr(ctx, error, "message", result);
        return JS_Throw(ctx, error);
    }
    return result;
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

static void enter(Engine *engine) { JS_UpdateStackTop(engine->rt); }

SW_EXPORT Engine *sw_create(int64_t memoryLimit, int64_t stackSize, sw_host_fn host, void *user) {
    Engine *engine = (Engine *)calloc(1, sizeof(Engine));
    if (engine == NULL) return NULL;
    engine->rt = JS_NewRuntime();
    if (engine->rt == NULL) { free(engine); return NULL; }
    JS_SetRuntimeOpaque(engine->rt, engine);
    if (memoryLimit > 0) JS_SetMemoryLimit(engine->rt, (size_t)memoryLimit);
    if (stackSize > 0) JS_SetMaxStackSize(engine->rt, (size_t)stackSize);
    JS_SetInterruptHandler(engine->rt, interruptHandler, engine);
    engine->ctx = JS_NewContext(engine->rt);
    if (engine->ctx == NULL) { JS_FreeRuntime(engine->rt); free(engine); return NULL; }
    engine->host = host;
    engine->user = user;
    engine->hostResult = JS_NULL;
    JSValue global = JS_GetGlobalObject(engine->ctx);
    JS_SetPropertyStr(engine->ctx, global, "__swNative", JS_NewCFunction(engine->ctx, hostCall, "__swNative", 2));
    JS_SetPropertyStr(engine->ctx, global, "__swEvaluate", JS_NewCFunction(engine->ctx, evaluateGlobal, "__swEvaluate", 2));
    JS_FreeValue(engine->ctx, global);
    return engine;
}

SW_EXPORT void sw_destroy(Engine *engine) {
    enter(engine);
    JS_FreeContext(engine->ctx);
    JS_FreeRuntime(engine->rt);
    free(engine->result);
    free(engine);
}

SW_EXPORT void sw_set_deadline(Engine *engine, int64_t millisecondsFromNow) {
    engine->interrupted = false;
    engine->deadlineTicks = millisecondsFromNow > 0 ? monotonicTicks() + millisecondsFromNow * ticksPerSecond() / 1000 : 0;
}

SW_EXPORT int sw_interrupted(Engine *engine) { return engine->interrupted ? 1 : 0; }

// Text or bytes of the last call, valid until the next call on this engine.
// The length is in UTF-16 code units for text and in bytes for bytecode.
SW_EXPORT const void *sw_result(Engine *engine, intptr_t *length) {
    *length = (intptr_t)engine->resultLength;
    return engine->result;
}

SW_EXPORT void sw_host_return(Engine *engine, const uint16_t *chars, intptr_t length) {
    if (engine->hostAnswered) JS_FreeValue(engine->ctx, engine->hostResult);
    engine->hostResult = stringFromHost(engine, chars, length);
    engine->hostAnswered = true;
    engine->hostThrew = false;
}

SW_EXPORT void sw_host_throw(Engine *engine, const uint16_t *chars, intptr_t length) {
    if (engine->hostAnswered) JS_FreeValue(engine->ctx, engine->hostResult);
    engine->hostResult = chars != NULL && length >= 0 ? JS_NewStringUTF16(engine->ctx, chars, (size_t)length) : JS_NewString(engine->ctx, "native host error");
    engine->hostAnswered = true;
    engine->hostThrew = true;
}

// JS_Eval needs NUL-terminated UTF-8. Round-trip through a JS string so the
// conversion from UTF-16 is done by the engine.
static JSValue evaluateSource(Engine *engine, const uint16_t *code, intptr_t length, const char *fileName, int flags) {
    JSValue source = JS_NewStringUTF16(engine->ctx, code, (size_t)length);
    if (JS_IsException(source)) return source;
    size_t utf8Length = 0;
    const char *utf8 = JS_ToCStringLen(engine->ctx, &utf8Length, source);
    JS_FreeValue(engine->ctx, source);
    if (utf8 == NULL) return JS_EXCEPTION;
    JSValue value = JS_Eval(engine->ctx, utf8, utf8Length, fileName, flags);
    JS_FreeCString(engine->ctx, utf8);
    return value;
}

SW_EXPORT int sw_evaluate(Engine *engine, const uint16_t *code, intptr_t length, const char *fileName) {
    enter(engine);
    return finishValue(engine, evaluateSource(engine, code, length, fileName, JS_EVAL_TYPE_GLOBAL));
}

SW_EXPORT int sw_compile(Engine *engine, const uint16_t *code, intptr_t length, const char *fileName) {
    enter(engine);
    JSValue function = evaluateSource(engine, code, length, fileName, JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(function)) return takeException(engine);
    size_t size = 0;
    uint8_t *bytes = JS_WriteObject(engine->ctx, &size, function, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(engine->ctx, function);
    if (bytes == NULL) return takeException(engine);
    setResultBytes(engine, bytes, size);
    js_free(engine->ctx, bytes);
    return SW_VALUE;
}

// Bytecode must come from sw_compile in this application build; it is never
// read from packages or other untrusted input.
SW_EXPORT int sw_evaluate_bytecode(Engine *engine, const uint8_t *bytes, intptr_t length) {
    enter(engine);
    JSValue function = JS_ReadObject(engine->ctx, bytes, (size_t)length, JS_READ_OBJ_BYTECODE);
    if (JS_IsException(function)) return takeException(engine);
    return finishValue(engine, JS_EvalFunction(engine->ctx, function));
}

SW_EXPORT int sw_call(Engine *engine, const char *functionName, const uint16_t *const *arguments, const intptr_t *lengths, int count) {
    enter(engine);
    JSContext *ctx = engine->ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue function = JS_GetPropertyStr(ctx, global, functionName);
    JSValue *values = count > 0 ? (JSValue *)calloc((size_t)count, sizeof(JSValue)) : NULL;
    for (int index = 0; index < count; index += 1) values[index] = stringFromHost(engine, arguments[index], lengths[index]);
    JSValue result = JS_Call(ctx, function, global, count, values);
    for (int index = 0; index < count; index += 1) JS_FreeValue(ctx, values[index]);
    free(values);
    JS_FreeValue(ctx, function);
    JS_FreeValue(ctx, global);
    return finishValue(engine, result);
}

// Runs queued promise jobs. Returns the number executed, or -1 when a job
// threw (sw_result holds the message).
SW_EXPORT int sw_run_jobs(Engine *engine, int maximum) {
    enter(engine);
    int executed = 0;
    while (executed < maximum) {
        JSContext *jobContext = NULL;
        int status = JS_ExecutePendingJob(engine->rt, &jobContext);
        if (status == 0) break;
        if (status < 0) { takeException(engine); return -1; }
        executed += 1;
    }
    return executed;
}

SW_EXPORT int64_t sw_memory_used(Engine *engine) {
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(engine->rt, &usage);
    return (int64_t)usage.malloc_size;
}
