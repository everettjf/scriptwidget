using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace ScriptWidget.Core.Js;

/// <summary>Thrown when JavaScript raises an uncaught exception or is interrupted.</summary>
public sealed class JsException(string message, bool interrupted) : Exception(message)
{
    public bool Interrupted { get; } = interrupted;
}

/// <summary>Synchronous bridge invoked by the <c>__swNative(op, payload)</c> JavaScript global.</summary>
public delegate string? JsHost(string operation, string? payload);

/// <summary>
/// One QuickJS-NG runtime and context. Not thread safe: create, use and close
/// an instance on a single thread (see <see cref="JsThread"/>).
/// </summary>
public sealed unsafe class QuickJs : IDisposable
{
    public const long DefaultMemoryLimit = 64L * 1024 * 1024;
    public const long DefaultStack = 3L * 1024 * 1024;

    private readonly JsHost host;
    private GCHandle self;
    private nint pointer;

    public QuickJs(JsHost host, long memoryLimitBytes = DefaultMemoryLimit, long stackBytes = DefaultStack)
    {
        this.host = host;
        self = GCHandle.Alloc(this);
        pointer = Native.sw_create(memoryLimitBytes, stackBytes, &HostCall, GCHandle.ToIntPtr(self));
        if (pointer == 0)
        {
            self.Free();
            throw new InvalidOperationException("QuickJS runtime could not be created");
        }
    }

    /// <summary>Stops running JavaScript after the given time; 0 clears the deadline.</summary>
    public void SetDeadline(long milliseconds) => Native.sw_set_deadline(Handle(), milliseconds);

    public string? Evaluate(string code, string fileName = "script.js")
    {
        var engine = Handle();
        var name = Utf8(fileName);
        int status;
        fixed (char* chars = code)
        fixed (byte* file = name)
            status = Native.sw_evaluate(engine, chars, code.Length, file);
        return Finish(engine, status);
    }

    public byte[] Compile(string code, string fileName = "script.js")
    {
        var engine = Handle();
        var name = Utf8(fileName);
        int status;
        fixed (char* chars = code)
        fixed (byte* file = name)
            status = Native.sw_compile(engine, chars, code.Length, file);
        if (status < 0) throw Failure(engine);
        var bytes = Native.sw_result(engine, out var length);
        return new ReadOnlySpan<byte>(bytes, (int)length).ToArray();
    }

    /// <summary>Bytecode must come from <see cref="Compile"/> in this application build.</summary>
    public string? EvaluateBytecode(byte[] bytecode)
    {
        var engine = Handle();
        int status;
        fixed (byte* bytes = bytecode)
            status = Native.sw_evaluate_bytecode(engine, bytes, bytecode.Length);
        return Finish(engine, status);
    }

    public string? Call(string function, params string?[] arguments)
    {
        var engine = Handle();
        var name = Utf8(function);
        var count = arguments.Length;
        var handles = new GCHandle[count];
        var pointers = stackalloc char*[Math.Max(count, 1)];
        var lengths = stackalloc nint[Math.Max(count, 1)];
        try
        {
            for (var index = 0; index < count; index++)
            {
                var argument = arguments[index];
                if (argument is null) { pointers[index] = null; lengths[index] = -1; continue; }
                handles[index] = GCHandle.Alloc(argument, GCHandleType.Pinned);
                pointers[index] = (char*)handles[index].AddrOfPinnedObject();
                lengths[index] = argument.Length;
            }
            int status;
            fixed (byte* file = name)
                status = Native.sw_call(engine, file, pointers, lengths, count);
            return Finish(engine, status);
        }
        finally
        {
            foreach (var handle in handles) if (handle.IsAllocated) handle.Free();
        }
    }

    /// <summary>Runs queued promise jobs; returns how many ran.</summary>
    public int RunJobs(int maximum = 10_000)
    {
        var engine = Handle();
        var executed = Native.sw_run_jobs(engine, maximum);
        if (executed < 0) throw Failure(engine);
        return executed;
    }

    public long MemoryUsed() => Native.sw_memory_used(Handle());

    public void Dispose()
    {
        if (pointer == 0) return;
        Native.sw_destroy(pointer);
        pointer = 0;
        self.Free();
    }

    /// <summary>
    /// Time zone of JavaScript's local time for every engine in the process:
    /// an IANA name such as "America/Los_Angeles", or null for the system zone.
    /// </summary>
    public static void SetTimeZone(string? ianaName)
    {
        if (ianaName is null) { Native.sw_set_time_zone(null, -1); return; }
        fixed (char* chars = ianaName) Native.sw_set_time_zone(chars, ianaName.Length);
    }

    private nint Handle() => pointer != 0 ? pointer : throw new ObjectDisposedException(nameof(QuickJs), "QuickJS runtime is closed");

    private static string? Finish(nint engine, int status)
    {
        if (status < 0) throw Failure(engine);
        return status == 0 ? null : ResultText(engine);
    }

    private static string ResultText(nint engine)
    {
        var chars = (char*)Native.sw_result(engine, out var length);
        return length == 0 ? "" : new string(chars, 0, (int)length);
    }

    private static JsException Failure(nint engine) => new(ResultText(engine), Native.sw_interrupted(engine) != 0);

    private static byte[] Utf8(string text)
    {
        var bytes = new byte[System.Text.Encoding.UTF8.GetByteCount(text) + 1];
        System.Text.Encoding.UTF8.GetBytes(text, bytes);
        return bytes;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void HostCall(nint user, char* operation, nint operationLength, char* payload, nint payloadLength)
    {
        var engine = (QuickJs)GCHandle.FromIntPtr(user).Target!;
        try
        {
            var result = engine.host(new string(operation, 0, (int)operationLength), payload is null || payloadLength < 0 ? null : new string(payload, 0, (int)payloadLength));
            if (result is null) return;
            fixed (char* chars = result) Native.sw_host_return(engine.pointer, chars, result.Length);
        }
        catch (Exception error)
        {
            // Exceptions must not unwind through native frames: hand the message to JavaScript.
            var message = string.IsNullOrEmpty(error.Message) ? "native host error" : error.Message;
            fixed (char* chars = message) Native.sw_host_throw(engine.pointer, chars, message.Length);
        }
    }

    private static partial class Native
    {
        private const string Library = "swcore";

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern nint sw_create(long memoryLimit, long stackSize, delegate* unmanaged[Cdecl]<nint, char*, nint, char*, nint, void> host, nint user);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sw_destroy(nint engine);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sw_set_deadline(nint engine, long millisecondsFromNow);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_interrupted(nint engine);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void* sw_result(nint engine, out nint length);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sw_host_return(nint engine, char* chars, nint length);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sw_host_throw(nint engine, char* chars, nint length);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_evaluate(nint engine, char* code, nint length, byte* fileName);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_compile(nint engine, char* code, nint length, byte* fileName);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_evaluate_bytecode(nint engine, byte* bytes, nint length);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_call(nint engine, byte* functionName, char** arguments, nint* lengths, int count);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sw_run_jobs(nint engine, int maximum);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern long sw_memory_used(nint engine);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sw_set_time_zone(char* id, nint length);
    }
}

/// <summary>Runs work on a fresh thread with a stack large enough for deep JavaScript recursion.</summary>
public static class JsThread
{
    private const int StackBytes = 8 * 1024 * 1024;

    public static T Run<T>(Func<T> block, string name = "scriptwidget-js", int stackBytes = StackBytes)
    {
        T result = default!;
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() =>
        {
            try { result = block(); }
            catch (Exception error) { failure = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error); }
        }, stackBytes) { Name = name, IsBackground = true };
        thread.Start();
        thread.Join();
        failure?.Throw();
        return result;
    }
}

/// <summary>A dedicated large-stack thread that runs submitted work in order.</summary>
public sealed class JsWorker : IDisposable
{
    private readonly System.Collections.Concurrent.BlockingCollection<Action> queue = new();
    private readonly Thread thread;

    public JsWorker(string name, int stackBytes)
    {
        thread = new Thread(() => { foreach (var work in queue.GetConsumingEnumerable()) work(); }, stackBytes) { Name = name, IsBackground = true };
        thread.Start();
    }

    public T Run<T>(Func<T> block)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        queue.Add(() =>
        {
            try { completion.SetResult(block()); }
            catch (Exception error) { completion.SetException(error); }
        });
        try { return completion.Task.GetAwaiter().GetResult(); }
        catch (AggregateException error) when (error.InnerException is not null) { throw error.InnerException; }
    }

    public void Post(Action work) => queue.Add(work);

    public void Dispose() => queue.CompleteAdding();
}
