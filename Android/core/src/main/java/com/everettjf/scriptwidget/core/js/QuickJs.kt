package com.everettjf.scriptwidget.core.js

/** Thrown when JavaScript raises an uncaught exception or is interrupted. */
class JsException(message: String, val interrupted: Boolean) : RuntimeException(message)

/** Synchronous bridge invoked by the `__swNative(op, payload)` JavaScript global. */
fun interface JsHost {
    fun call(operation: String, payload: String?): String?
}

/**
 * One QuickJS-NG runtime and context. Not thread safe: create, use and close
 * an instance on a single thread (see [JsThread]).
 */
class QuickJs(host: JsHost, memoryLimitBytes: Long = DEFAULT_MEMORY_LIMIT, stackBytes: Long = DEFAULT_STACK) : AutoCloseable {
    private var pointer: Long = nativeCreate(host, memoryLimitBytes, stackBytes)

    init {
        check(pointer != 0L) { "QuickJS runtime could not be created" }
    }

    /** Stops running JavaScript after [milliseconds]; 0 clears the deadline. */
    fun setDeadline(milliseconds: Long) = nativeSetDeadline(handle(), milliseconds)

    fun evaluate(code: String, fileName: String = "script.js"): String? = nativeEvaluate(handle(), code, fileName)

    fun compile(code: String, fileName: String = "script.js"): ByteArray = nativeCompile(handle(), code, fileName)

    fun evaluateBytecode(bytecode: ByteArray): String? = nativeEvaluateBytecode(handle(), bytecode)

    fun call(function: String, vararg arguments: String?): String? = nativeCall(handle(), function, arguments)

    /** Runs queued promise jobs; returns how many ran. */
    fun runJobs(maximum: Int = 10_000): Int = nativeRunJobs(handle(), maximum)

    fun memoryUsed(): Long = nativeMemoryUsed(handle())

    override fun close() {
        if (pointer != 0L) {
            nativeDestroy(pointer)
            pointer = 0L
        }
    }

    private fun handle(): Long {
        check(pointer != 0L) { "QuickJS runtime is closed" }
        return pointer
    }

    private external fun nativeCreate(host: JsHost, memoryLimit: Long, stackSize: Long): Long
    private external fun nativeDestroy(pointer: Long)
    private external fun nativeSetDeadline(pointer: Long, millisecondsFromNow: Long)
    private external fun nativeEvaluate(pointer: Long, code: String, fileName: String): String?
    private external fun nativeCompile(pointer: Long, code: String, fileName: String): ByteArray
    private external fun nativeEvaluateBytecode(pointer: Long, bytecode: ByteArray): String?
    private external fun nativeCall(pointer: Long, function: String, arguments: Array<out String?>): String?
    private external fun nativeRunJobs(pointer: Long, maximum: Int): Int
    private external fun nativeMemoryUsed(pointer: Long): Long

    companion object {
        const val DEFAULT_MEMORY_LIMIT = 64L * 1024 * 1024
        const val DEFAULT_STACK = 3L * 1024 * 1024

        init {
            System.loadLibrary("scriptwidget")
        }
    }
}

/** Runs [block] on a fresh thread with a stack large enough for deep JavaScript recursion. */
object JsThread {
    private const val STACK_BYTES = 8L * 1024 * 1024

    fun <T> run(name: String = "scriptwidget-js", block: () -> T): T {
        var result: Result<T>? = null
        val thread = Thread(null, { result = runCatching(block) }, name, STACK_BYTES)
        thread.start()
        thread.join()
        return result!!.getOrThrow()
    }
}
