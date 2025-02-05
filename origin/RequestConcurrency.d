/**
 * This is a low-level messaging API upon which more structured or restrictive
 * APIs may be built.  The general idea is that every messageable entity is
 * represented by a common handle type called a Tid, which allows messages to
 * be sent to logical threads that are executing in both the current process
 * and in external processes using the same interface.  This is an important
 * aspect of scalability because it allows the components of a program to be
 * spread across available resources with few to no changes to the actual
 * implementation.
 *
 * A logical thread is an execution context that has its own stack and which
 * runs asynchronously to other logical threads.  These may be preemptively
 * scheduled kernel threads, fibers (cooperative user-space threads), or some
 * other concept with similar behavior.
 *
 * Copyright: Copyright Sean Kelly 2009 - 2014.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
 * Source:    $(PHOBOSSRC std/concurrency.d)
 */
/*          Copyright Sean Kelly 2009 - 2014.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module geod24.RequestConcurrency;

public import std.variant;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;

///
@system unittest
{
    __gshared string received;
    static void spawnedFunc(Tid ownerTid)
    {
        import std.conv : text;
        // Receive a message from the owner thread.
        receive((int i){
            received = text("Received the number ", i);

            // Send a message back to the owner thread
            // indicating success.
            send(ownerTid, true);
        });
    }

    // Start spawnedFunc in a new thread.
    auto childTid = spawn(&spawnedFunc, thisTid);

    // Send the number 42 to this new thread.
    send(childTid, 42);

    // Receive the result code.
    auto wasSuccessful = receiveOnly!(bool);
    assert(wasSuccessful);
    assert(received == "Received the number 42");
}

private
{
    bool hasLocalAliasing(Types...)()
    {
        // Works around "statement is not reachable"
        bool doesIt = false;
        static foreach (T; Types)
        {
            static if (is(T == Tid))
            { /* Allowed */ }
            else static if (is(T == struct))
                doesIt |= hasLocalAliasing!(typeof(T.tupleof));
            else
                doesIt |= std.traits.hasUnsharedAliasing!(T);
        }
        return doesIt;
    }

    @safe unittest
    {
        static struct Container { Tid t; }
        static assert(!hasLocalAliasing!(Tid, Container, int));
    }

    enum MsgType
    {
        standard,
        priority,
        linkDead,
    }

    struct Message
    {
        MsgType type;
        Variant data;

        this(T...)(MsgType t, T vals) if (T.length > 0)
        {
            static if (T.length == 1)
            {
                type = t;
                data = vals[0];
            }
            else
            {
                import std.typecons : Tuple;

                type = t;
                data = Tuple!(T)(vals);
            }
        }

        @property auto convertsTo(T...)()
        {
            static if (T.length == 1)
            {
                return is(T[0] == Variant) || data.convertsTo!(T);
            }
            else
            {
                import std.typecons : Tuple;
                return data.convertsTo!(Tuple!(T));
            }
        }

        @property auto get(T...)()
        {
            static if (T.length == 1)
            {
                static if (is(T[0] == Variant))
                    return data;
                else
                    return data.get!(T);
            }
            else
            {
                import std.typecons : Tuple;
                return data.get!(Tuple!(T));
            }
        }

        auto map(Op)(Op op)
        {
            alias Args = Parameters!(Op);

            static if (Args.length == 1)
            {
                static if (is(Args[0] == Variant))
                    return op(data);
                else
                    return op(data.get!(Args));
            }
            else
            {
                import std.typecons : Tuple;
                return op(data.get!(Tuple!(Args)).expand);
            }
        }
    }

    void checkops(T...)(T ops)
    {
        foreach (i, t1; T)
        {
            static assert(isFunctionPointer!t1 || isDelegate!t1);
            alias a1 = Parameters!(t1);
            alias r1 = ReturnType!(t1);

            static if (i < T.length - 1 && is(r1 == void))
            {
                static assert(a1.length != 1 || !is(a1[0] == Variant),
                              "function with arguments " ~ a1.stringof ~
                              " occludes successive function");

                foreach (t2; T[i + 1 .. $])
                {
                    static assert(isFunctionPointer!t2 || isDelegate!t2);
                    alias a2 = Parameters!(t2);

                    static assert(!is(a1 == a2),
                        "function with arguments " ~ a1.stringof ~ " occludes successive function");
                }
            }
        }
    }

    @property ref ThreadInfo thisInfo() nothrow
    {
        return ThreadInfo.thisInfo;
    }
}

static ~this()
{
    thisInfo.cleanup();
}

// Exceptions

/**
 * Thrown on calls to `receiveOnly` if a message other than the type
 * the receiving thread expected is sent.
 */
class MessageMismatch : Exception
{
    ///
    this(string msg = "Unexpected message type") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/**
 * Thrown on calls to `receive` if the thread that spawned the receiving
 * thread has terminated and no more messages exist.
 */
class OwnerTerminated : Exception
{
    ///
    this(Tid t, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/**
 * Thrown if a linked thread has terminated.
 */
class LinkTerminated : Exception
{
    ///
    this(Tid t, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/**
 * Thrown if a message was sent to a thread via
 * $(REF prioritySend, std,concurrency) and the receiver does not have a handler
 * for a message of this type.
 */
class PriorityMessageException : Exception
{
    ///
    this(Variant vals)
    {
        super("Priority message");
        message = vals;
    }

    /**
     * The message that was sent.
     */
    Variant message;
}

/**
 * Thrown on mailbox crowding if the mailbox is configured with
 * `OnCrowding.throwException`.
 */
class MailboxFull : Exception
{
    ///
    this(Tid t, string msg = "Mailbox full") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/**
 * Thrown when a Tid is missing, e.g. when `ownerTid` doesn't
 * find an owner thread.
 */
class TidMissingException : Exception
{
    import std.exception : basicExceptionCtors;
    ///
    mixin basicExceptionCtors;
}


// Thread ID


/**
 * An opaque type used to represent a logical thread.
 */
struct Tid
{
private:
    this(MessageBox m) @safe pure nothrow @nogc
    {
        mbox = m;
    }

    MessageBox mbox;

public:

    /**
     * Generate a convenient string for identifying this Tid.  This is only
     * useful to see if Tid's that are currently executing are the same or
     * different, e.g. for logging and debugging.  It is potentially possible
     * that a Tid executed in the future will have the same toString() output
     * as another Tid that has already terminated.
     */
    void toString(scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "Tid(%x)", cast(void*) mbox);
    }

}

@system unittest
{
    // text!Tid is @system
    import std.conv : text;
    Tid tid;
    assert(text(tid) == "Tid(0)");
    auto tid2 = thisTid;
    assert(text(tid2) != "Tid(0)");
    auto tid3 = tid2;
    assert(text(tid2) == text(tid3));
}

/**
 * Returns: The $(LREF Tid) of the caller's thread.
 */
@property Tid thisTid() @safe
{
    // TODO: remove when concurrency is safe
    static auto trus() @trusted
    {
        if (thisInfo.ident != Tid.init)
            return thisInfo.ident;
        thisInfo.ident = Tid(new MessageBox);
        return thisInfo.ident;
    }

    return trus();
}

/**
 * Return the Tid of the thread which spawned the caller's thread.
 *
 * Throws: A `TidMissingException` exception if
 * there is no owner thread.
 */
@property Tid ownerTid()
{
    import std.exception : enforce;

    enforce!TidMissingException(thisInfo.owner.mbox !is null, "Error: Thread has no owner thread.");
    return thisInfo.owner;
}

@system unittest
{
    import std.exception : assertThrown;

    static void fun()
    {
        string res = receiveOnly!string();
        assert(res == "Main calling");
        ownerTid.send("Child responding");
    }

    assertThrown!TidMissingException(ownerTid);
    auto child = spawn(&fun);
    child.send("Main calling");
    string res = receiveOnly!string();
    assert(res == "Child responding");
}

// Thread Creation

private template isSpawnable(F, T...)
{
    template isParamsImplicitlyConvertible(F1, F2, int i = 0)
    {
        alias param1 = Parameters!F1;
        alias param2 = Parameters!F2;
        static if (param1.length != param2.length)
            enum isParamsImplicitlyConvertible = false;
        else static if (param1.length == i)
            enum isParamsImplicitlyConvertible = true;
        else static if (isImplicitlyConvertible!(param2[i], param1[i]))
            enum isParamsImplicitlyConvertible = isParamsImplicitlyConvertible!(F1,
                    F2, i + 1);
        else
            enum isParamsImplicitlyConvertible = false;
    }

    enum isSpawnable = isCallable!F && is(ReturnType!F == void)
            && isParamsImplicitlyConvertible!(F, void function(T))
            && (isFunctionPointer!F || !hasUnsharedAliasing!F);
}

/**
 * Starts fn(args) in a new logical thread.
 *
 * Executes the supplied function in a new logical thread represented by
 * `Tid`.  The calling thread is designated as the owner of the new thread.
 * When the owner thread terminates an `OwnerTerminated` message will be
 * sent to the new thread, causing an `OwnerTerminated` exception to be
 * thrown on `receive()`.
 *
 * Params:
 *  fn   = The function to execute.
 *  args = Arguments to the function.
 *
 * Returns:
 *  A Tid representing the new logical thread.
 *
 * Notes:
 *  `args` must not have unshared aliasing.  In other words, all arguments
 *  to `fn` must either be `shared` or `immutable` or have no
 *  pointer indirection.  This is necessary for enforcing isolation among
 *  threads.
 */
Tid spawn(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(false, fn, args);
}

///
@system unittest
{
    static void f(string msg)
    {
        assert(msg == "Hello World");
    }

    auto tid = spawn(&f, "Hello World");
}

/// Fails: char[] has mutable aliasing.
@system unittest
{
    string msg = "Hello, World!";

    static void f1(string msg) {}
    static assert(!__traits(compiles, spawn(&f1, msg.dup)));
    static assert( __traits(compiles, spawn(&f1, msg.idup)));

    static void f2(char[] msg) {}
    static assert(!__traits(compiles, spawn(&f2, msg.dup)));
    static assert(!__traits(compiles, spawn(&f2, msg.idup)));
}

/// New thread with anonymous function
@system unittest
{
    spawn({
        ownerTid.send("This is so great!");
    });
    assert(receiveOnly!string == "This is so great!");
}

@system unittest
{
    import core.thread : thread_joinAll;

    __gshared string receivedMessage;
    static void f1(string msg)
    {
        receivedMessage = msg;
    }

    auto tid1 = spawn(&f1, "Hello World");
    thread_joinAll;
    assert(receivedMessage == "Hello World");
}

/**
 * Starts fn(args) in a logical thread and will receive a LinkTerminated
 * message when the operation terminates.
 *
 * Executes the supplied function in a new logical thread represented by
 * Tid.  This new thread is linked to the calling thread so that if either
 * it or the calling thread terminates a LinkTerminated message will be sent
 * to the other, causing a LinkTerminated exception to be thrown on receive().
 * The owner relationship from spawn() is preserved as well, so if the link
 * between threads is broken, owner termination will still result in an
 * OwnerTerminated exception to be thrown on receive().
 *
 * Params:
 *  fn   = The function to execute.
 *  args = Arguments to the function.
 *
 * Returns:
 *  A Tid representing the new thread.
 */
Tid spawnLinked(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(true, fn, args);
}

/*
 *
 */
private Tid _spawn(F, T...)(bool linked, F fn, T args)
if (isSpawnable!(F, T))
{
    // TODO: MessageList and &exec should be shared.
    auto spawnTid = Tid(new MessageBox);
    auto ownerTid = thisTid;

    void exec()
    {
        thisInfo.ident = spawnTid;
        thisInfo.owner = ownerTid;
        fn(args);
    }

    auto t = new Thread(&exec);
    t.start();

    thisInfo.links[spawnTid] = linked;
    return spawnTid;
}

@system unittest
{
    void function() fn1;
    void function(int) fn2;
    static assert(__traits(compiles, spawn(fn1)));
    static assert(__traits(compiles, spawn(fn2, 2)));
    static assert(!__traits(compiles, spawn(fn1, 1)));
    static assert(!__traits(compiles, spawn(fn2)));

    void delegate(int) shared dg1;
    shared(void delegate(int)) dg2;
    shared(void delegate(long) shared) dg3;
    shared(void delegate(real, int, long) shared) dg4;
    void delegate(int) immutable dg5;
    void delegate(int) dg6;
    static assert(__traits(compiles, spawn(dg1, 1)));
    static assert(__traits(compiles, spawn(dg2, 2)));
    static assert(__traits(compiles, spawn(dg3, 3)));
    static assert(__traits(compiles, spawn(dg4, 4, 4, 4)));
    static assert(__traits(compiles, spawn(dg5, 5)));
    static assert(!__traits(compiles, spawn(dg6, 6)));

    auto callable1  = new class{ void opCall(int) shared {} };
    auto callable2  = cast(shared) new class{ void opCall(int) shared {} };
    auto callable3  = new class{ void opCall(int) immutable {} };
    auto callable4  = cast(immutable) new class{ void opCall(int) immutable {} };
    auto callable5  = new class{ void opCall(int) {} };
    auto callable6  = cast(shared) new class{ void opCall(int) immutable {} };
    auto callable7  = cast(immutable) new class{ void opCall(int) shared {} };
    auto callable8  = cast(shared) new class{ void opCall(int) const shared {} };
    auto callable9  = cast(const shared) new class{ void opCall(int) shared {} };
    auto callable10 = cast(const shared) new class{ void opCall(int) const shared {} };
    auto callable11 = cast(immutable) new class{ void opCall(int) const shared {} };
    static assert(!__traits(compiles, spawn(callable1,  1)));
    static assert( __traits(compiles, spawn(callable2,  2)));
    static assert(!__traits(compiles, spawn(callable3,  3)));
    static assert( __traits(compiles, spawn(callable4,  4)));
    static assert(!__traits(compiles, spawn(callable5,  5)));
    static assert(!__traits(compiles, spawn(callable6,  6)));
    static assert(!__traits(compiles, spawn(callable7,  7)));
    static assert( __traits(compiles, spawn(callable8,  8)));
    static assert(!__traits(compiles, spawn(callable9,  9)));
    static assert( __traits(compiles, spawn(callable10, 10)));
    static assert( __traits(compiles, spawn(callable11, 11)));
}

/**
 * Places the values as a message at the back of tid's message queue.
 *
 * Sends the supplied value to the thread represented by tid.  As with
 * $(REF spawn, std,concurrency), `T` must not have unshared aliasing.
 */
void send(T...)(Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    _send(tid, vals);
}

/**
 * Places the values as a message on the front of tid's message queue.
 *
 * Send a message to `tid` but place it at the front of `tid`'s message
 * queue instead of at the back.  This function is typically used for
 * out-of-band communication, to signal exceptional conditions, etc.
 */
void prioritySend(T...)(Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    _send(MsgType.priority, tid, vals);
}

/*
 * ditto
 */
private void _send(T...)(Tid tid, T vals)
{
    _send(MsgType.standard, tid, vals);
}

/*
 * Implementation of send.  This allows parameter checking to be different for
 * both Tid.send() and .send().
 */
private void _send(T...)(MsgType type, Tid tid, T vals)
{
    auto msg = Message(type, vals);
    tid.mbox.put(msg);
}

/**
 * Receives a message from another thread.
 *
 * Receive a message from another thread, or block if no messages of the
 * specified types are available.  This function works by pattern matching
 * a message against a set of delegates and executing the first match found.
 *
 * If a delegate that accepts a $(REF Variant, std,variant) is included as
 * the last argument to `receive`, it will match any message that was not
 * matched by an earlier delegate.  If more than one argument is sent,
 * the `Variant` will contain a $(REF Tuple, std,typecons) of all values
 * sent.
 */
void receive(T...)( T ops )
in
{
    assert(thisInfo.ident.mbox !is null,
           "Cannot receive a message until a thread was spawned "
           ~ "or thisTid was passed to a running thread.");
}
do
{
    checkops( ops );

    thisInfo.ident.mbox.get( ops );
}

///
@system unittest
{
    import std.variant : Variant;

    auto process = ()
    {
        receive(
            (int i) { ownerTid.send(1); },
            (double f) { ownerTid.send(2); },
            (Variant v) { ownerTid.send(3); }
        );
    };

    {
        auto tid = spawn(process);
        send(tid, 42);
        assert(receiveOnly!int == 1);
    }

    {
        auto tid = spawn(process);
        send(tid, 3.14);
        assert(receiveOnly!int == 2);
    }

    {
        auto tid = spawn(process);
        send(tid, "something else");
        assert(receiveOnly!int == 3);
    }
}

@safe unittest
{
    static assert( __traits( compiles,
                      {
                          receive( (Variant x) {} );
                          receive( (int x) {}, (Variant x) {} );
                      } ) );

    static assert( !__traits( compiles,
                       {
                           receive( (Variant x) {}, (int x) {} );
                       } ) );

    static assert( !__traits( compiles,
                       {
                           receive( (int x) {}, (int x) {} );
                       } ) );
}

// Make sure receive() works with free functions as well.
version (unittest)
{
    private void receiveFunction(int x) {}
}
@safe unittest
{
    static assert( __traits( compiles,
                      {
                          receive( &receiveFunction );
                          receive( &receiveFunction, (Variant x) {} );
                      } ) );
}


private template receiveOnlyRet(T...)
{
    static if ( T.length == 1 )
    {
        alias receiveOnlyRet = T[0];
    }
    else
    {
        import std.typecons : Tuple;
        alias receiveOnlyRet = Tuple!(T);
    }
}

/**
 * Receives only messages with arguments of types `T`.
 *
 * Throws:  `MessageMismatch` if a message of types other than `T`
 *          is received.
 *
 * Returns: The received message.  If `T.length` is greater than one,
 *          the message will be packed into a $(REF Tuple, std,typecons).
 */
receiveOnlyRet!(T) receiveOnly(T...)()
in
{
    assert(thisInfo.ident.mbox !is null,
        "Cannot receive a message until a thread was spawned or thisTid was passed to a running thread.");
}
do
{
    import std.format : format;
    import std.typecons : Tuple;

    Tuple!(T) ret;

    thisInfo.ident.mbox.get((T val) {
        static if (T.length)
            ret.field = val;
    },
    (LinkTerminated e) { throw e; },
    (OwnerTerminated e) { throw e; },
    (Variant val) {
        static if (T.length > 1)
            string exp = T.stringof;
        else
            string exp = T[0].stringof;

        throw new MessageMismatch(
            format("Unexpected message type: expected '%s', got '%s'", exp, val.type.toString()));
    });
    static if (T.length == 1)
        return ret[0];
    else
        return ret;
}

///
@system unittest
{
    auto tid = spawn(
    {
        assert(receiveOnly!int == 42);
    });
    send(tid, 42);
}

///
@system unittest
{
    auto tid = spawn(
    {
        assert(receiveOnly!string == "text");
    });
    send(tid, "text");
}

///
@system unittest
{
    struct Record { string name; int age; }

    auto tid = spawn(
    {
        auto msg = receiveOnly!(double, Record);
        assert(msg[0] == 0.5);
        assert(msg[1].name == "Alice");
        assert(msg[1].age == 31);
    });

    send(tid, 0.5, Record("Alice", 31));
}

@system unittest
{
    static void t1(Tid mainTid)
    {
        try
        {
            receiveOnly!string();
            mainTid.send("");
        }
        catch (Throwable th)
        {
            mainTid.send(th.msg);
        }
    }

    auto tid = spawn(&t1, thisTid);
    tid.send(1);
    string result = receiveOnly!string();
    assert(result == "Unexpected message type: expected 'string', got 'int'");
}

/**
 * Tries to receive but will give up if no matches arrive within duration.
 * Won't wait at all if provided $(REF Duration, core,time) is negative.
 *
 * Same as `receive` except that rather than wait forever for a message,
 * it waits until either it receives a message or the given
 * $(REF Duration, core,time) has passed. It returns `true` if it received a
 * message and `false` if it timed out waiting for one.
 */
bool receiveTimeout(T...)(Duration duration, T ops)
in
{
    assert(thisInfo.ident.mbox !is null,
        "Cannot receive a message until a thread was spawned or thisTid was passed to a running thread.");
}
do
{
    checkops(ops);

    return thisInfo.ident.mbox.get(duration, ops);
}

@safe unittest
{
    static assert(__traits(compiles, {
        receiveTimeout(msecs(0), (Variant x) {});
        receiveTimeout(msecs(0), (int x) {}, (Variant x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(msecs(0), (Variant x) {}, (int x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(msecs(0), (int x) {}, (int x) {});
    }));

    static assert(__traits(compiles, {
        receiveTimeout(msecs(10), (int x) {}, (Variant x) {});
    }));
}

// MessageBox Limits

/**
 * These behaviors may be specified when a mailbox is full.
 */
enum OnCrowding
{
    block, /// Wait until room is available.
    throwException, /// Throw a MailboxFull exception.
    ignore /// Abort the send and return.
}

private
{
    bool onCrowdingBlock(Tid tid) @safe pure nothrow @nogc
    {
        return true;
    }

    bool onCrowdingThrow(Tid tid) @safe pure
    {
        throw new MailboxFull(tid);
    }

    bool onCrowdingIgnore(Tid tid) @safe pure nothrow @nogc
    {
        return false;
    }
}

/**
 * Sets a maximum mailbox size.
 *
 * Sets a limit on the maximum number of user messages allowed in the mailbox.
 * If this limit is reached, the caller attempting to add a new message will
 * execute the behavior specified by doThis.  If messages is zero, the mailbox
 * is unbounded.
 *
 * Params:
 *  tid      = The Tid of the thread for which this limit should be set.
 *  messages = The maximum number of messages or zero if no limit.
 *  doThis   = The behavior executed when a message is sent to a full
 *             mailbox.
 */
void setMaxMailboxSize(Tid tid, size_t messages, OnCrowding doThis) @safe pure
{
    final switch (doThis)
    {
    case OnCrowding.block:
        return tid.mbox.setMaxMsgs(messages, &onCrowdingBlock);
    case OnCrowding.throwException:
        return tid.mbox.setMaxMsgs(messages, &onCrowdingThrow);
    case OnCrowding.ignore:
        return tid.mbox.setMaxMsgs(messages, &onCrowdingIgnore);
    }
}

/**
 * Sets a maximum mailbox size.
 *
 * Sets a limit on the maximum number of user messages allowed in the mailbox.
 * If this limit is reached, the caller attempting to add a new message will
 * execute onCrowdingDoThis.  If messages is zero, the mailbox is unbounded.
 *
 * Params:
 *  tid      = The Tid of the thread for which this limit should be set.
 *  messages = The maximum number of messages or zero if no limit.
 *  onCrowdingDoThis = The routine called when a message is sent to a full
 *                     mailbox.
 */
void setMaxMailboxSize(Tid tid, size_t messages, bool function(Tid) onCrowdingDoThis)
{
    tid.mbox.setMaxMsgs(messages, onCrowdingDoThis);
}

private
{
    __gshared Tid[string] tidByName;
    __gshared string[][Tid] namesByTid;
}

private @property Mutex registryLock()
{
    __gshared Mutex impl;
    initOnce!impl(new Mutex);
    return impl;
}

private void unregisterMe()
{
    auto me = thisInfo.ident;
    if (thisInfo.ident != Tid.init)
    {
        synchronized (registryLock)
        {
            if (auto allNames = me in namesByTid)
            {
                foreach (name; *allNames)
                    tidByName.remove(name);
                namesByTid.remove(me);
            }
        }
    }
}

/**
 * Associates name with tid.
 *
 * Associates name with tid in a process-local map.  When the thread
 * represented by tid terminates, any names associated with it will be
 * automatically unregistered.
 *
 * Params:
 *  name = The name to associate with tid.
 *  tid  = The tid register by name.
 *
 * Returns:
 *  true if the name is available and tid is not known to represent a
 *  defunct thread.
 */
bool register(string name, Tid tid)
{
    synchronized (registryLock)
    {
        if (name in tidByName)
            return false;
        if (tid.mbox.isClosed)
            return false;
        namesByTid[tid] ~= name;
        tidByName[name] = tid;
        return true;
    }
}

/**
 * Removes the registered name associated with a tid.
 *
 * Params:
 *  name = The name to unregister.
 *
 * Returns:
 *  true if the name is registered, false if not.
 */
bool unregister(string name)
{
    import std.algorithm.mutation : remove, SwapStrategy;
    import std.algorithm.searching : countUntil;

    synchronized (registryLock)
    {
        if (auto tid = name in tidByName)
        {
            auto allNames = *tid in namesByTid;
            auto pos = countUntil(*allNames, name);
            remove!(SwapStrategy.unstable)(*allNames, pos);
            tidByName.remove(name);
            return true;
        }
        return false;
    }
}

/**
 * Gets the Tid associated with name.
 *
 * Params:
 *  name = The name to locate within the registry.
 *
 * Returns:
 *  The associated Tid or Tid.init if name is not registered.
 */
Tid locate(string name)
{
    synchronized (registryLock)
    {
        if (auto tid = name in tidByName)
            return *tid;
        return Tid.init;
    }
}

/**
 * Encapsulates all implementation-level data needed for scheduling.
 */
struct ThreadInfo
{
    Tid ident;
    bool[Tid] links;
    Tid owner;

    /**
     * Gets a thread-local instance of ThreadInfo.
     */
    static @property ref thisInfo() nothrow
    {
        static ThreadInfo val;
        return val;
    }

    /**
     * Cleans up this ThreadInfo.
     *
     * This must be called when a scheduled thread terminates.  It tears down
     * the messaging system for the thread and notifies interested parties of
     * the thread's termination.
     */
    void cleanup()
    {
        if (ident.mbox !is null)
            ident.mbox.close();
        foreach (tid; links.keys)
            _send(MsgType.linkDead, tid, ident);
        if (owner != Tid.init)
            _send(MsgType.linkDead, owner, ident);
        unregisterMe(); // clean up registry entries
    }
}


// Generator

/**
 * If the caller is a Fiber and is not a Generator, this function will call
 * Fiber.yield(), as appropriate.
 */
void yield() nothrow
{
    auto fiber = Fiber.getThis();
    if (!(cast(IsGenerator) fiber))
    {
        if (fiber)
            return Fiber.yield();
    }
}

/// Used to determine whether a Generator is running.
private interface IsGenerator {}


/**
 * A Generator is a Fiber that periodically returns values of type T to the
 * caller via yield.  This is represented as an InputRange.
 */
class Generator(T) :
    Fiber, IsGenerator, InputRange!T
{
    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *
     * In:
     *  fn must not be null.
     */
    this(void function() fn)
    {
        super(fn);
        call();
    }

    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  fn must not be null.
     */
    this(void function() fn, size_t sz)
    {
        super(fn, sz);
        call();
    }

    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *  sz = The stack size for this fiber.
     *  guardPageSize = size of the guard page to trap fiber's stack
     *                  overflows. Refer to $(REF Fiber, core,thread)'s
     *                  documentation for more details.
     *
     * In:
     *  fn must not be null.
     */
    this(void function() fn, size_t sz, size_t guardPageSize)
    {
        super(fn, sz, guardPageSize);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *
     * In:
     *  dg must not be null.
     */
    this(void delegate() dg)
    {
        super(dg);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  dg must not be null.
     */
    this(void delegate() dg, size_t sz)
    {
        super(dg, sz);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *  sz = The stack size for this fiber.
     *  guardPageSize = size of the guard page to trap fiber's stack
     *                  overflows. Refer to $(REF Fiber, core,thread)'s
     *                  documentation for more details.
     *
     * In:
     *  dg must not be null.
     */
    this(void delegate() dg, size_t sz, size_t guardPageSize)
    {
        super(dg, sz, guardPageSize);
        call();
    }

    /**
     * Returns true if the generator is empty.
     */
    final bool empty() @property
    {
        return m_value is null || state == State.TERM;
    }

    /**
     * Obtains the next value from the underlying function.
     */
    final void popFront()
    {
        call();
    }

    /**
     * Returns the most recently generated value by shallow copy.
     */
    final T front() @property
    {
        return *m_value;
    }

    /**
     * Returns the most recently generated value without executing a
     * copy contructor. Will not compile for element types defining a
     * postblit, because Generator does not return by reference.
     */
    final T moveFront()
    {
        static if (!hasElaborateCopyConstructor!T)
        {
            return front;
        }
        else
        {
            static assert(0,
                    "Fiber front is always rvalue and thus cannot be moved since it defines a postblit.");
        }
    }

    final int opApply(scope int delegate(T) loopBody)
    {
        int broken;
        for (; !empty; popFront())
        {
            broken = loopBody(front);
            if (broken) break;
        }
        return broken;
    }

    final int opApply(scope int delegate(size_t, T) loopBody)
    {
        int broken;
        for (size_t i; !empty; ++i, popFront())
        {
            broken = loopBody(i, front);
            if (broken) break;
        }
        return broken;
    }
private:
    T* m_value;
}

///
@system unittest
{
    auto tid = spawn({
        int i;
        while (i < 9)
            i = receiveOnly!int;

        ownerTid.send(i * 2);
    });

    auto r = new Generator!int({
        foreach (i; 1 .. 10)
            yield(i);
    });

    foreach (e; r)
        tid.send(e);

    assert(receiveOnly!int == 18);
}

/**
 * Yields a value of type T to the caller of the currently executing
 * generator.
 *
 * Params:
 *  value = The value to yield.
 */
void yield(T)(ref T value)
{
    Generator!T cur = cast(Generator!T) Fiber.getThis();
    if (cur !is null && cur.state == Fiber.State.EXEC)
    {
        cur.m_value = &value;
        return Fiber.yield();
    }
    throw new Exception("yield(T) called with no active generator for the supplied type");
}

/// ditto
void yield(T)(T value)
{
    yield(value);
}

///
@system unittest
{
    import std.range;

    InputRange!int myIota = iota(10).inputRangeObject;

    myIota.popFront();
    myIota.popFront();
    assert(myIota.moveFront == 2);
    assert(myIota.front == 2);
    myIota.popFront();
    assert(myIota.front == 3);

    //can be assigned to std.range.interfaces.InputRange directly
    myIota = new Generator!int(
    {
        foreach (i; 0 .. 10) yield(i);
    });

    myIota.popFront();
    myIota.popFront();
    assert(myIota.moveFront == 2);
    assert(myIota.front == 2);
    myIota.popFront();
    assert(myIota.front == 3);

    size_t[2] counter = [0, 0];
    foreach (i, unused; myIota) counter[] += [1, i];

    assert(myIota.empty);
    assert(counter == [7, 21]);
}

private
{
    /*
     * A MessageBox is a message queue for one thread.  Other threads may send
     * messages to this owner by calling put(), and the owner receives them by
     * calling get().  The put() call is therefore effectively shared and the
     * get() call is effectively local.  setMaxMsgs may be used by any thread
     * to limit the size of the message queue.
     */
    class MessageBox
    {
        this() @trusted nothrow /* TODO: make @safe after relevant druntime PR gets merged */
        {
            m_lock = new Mutex;
            m_closed = false;

                m_putMsg = new Condition(m_lock);
                m_notFull = new Condition(m_lock);
        }

        ///
        final @property bool isClosed() @safe @nogc pure
        {
            synchronized (m_lock)
            {
                return m_closed;
            }
        }

        /*
         * Sets a limit on the maximum number of user messages allowed in the
         * mailbox.  If this limit is reached, the caller attempting to add
         * a new message will execute call.  If num is zero, there is no limit
         * on the message queue.
         *
         * Params:
         *  num  = The maximum size of the queue or zero if the queue is
         *         unbounded.
         *  call = The routine to call when the queue is full.
         */
        final void setMaxMsgs(size_t num, bool function(Tid) call) @safe @nogc pure
        {
            synchronized (m_lock)
            {
                m_maxMsgs = num;
                m_onMaxMsgs = call;
            }
        }

        /*
         * If maxMsgs is not set, the message is added to the queue and the
         * owner is notified.  If the queue is full, the message will still be
         * accepted if it is a control message, otherwise onCrowdingDoThis is
         * called.  If the routine returns true, this call will block until
         * the owner has made space available in the queue.  If it returns
         * false, this call will abort.
         *
         * Params:
         *  msg = The message to put in the queue.
         *
         * Throws:
         *  An exception if the queue is full and onCrowdingDoThis throws.
         */
        final void put(ref Message msg)
        {
            synchronized (m_lock)
            {
                // TODO: Generate an error here if m_closed is true, or maybe
                //       put a message in the caller's queue?
                if (!m_closed)
                {
                    while (true)
                    {
                        if (isPriorityMsg(msg))
                        {
                            m_sharedPty.put(msg);
                            m_putMsg.notify();
                            return;
                        }
                        if (!mboxFull() || isControlMsg(msg))
                        {
                            m_sharedBox.put(msg);
                            m_putMsg.notify();
                            return;
                        }
                        if (m_onMaxMsgs !is null && !m_onMaxMsgs(thisTid))
                        {
                            return;
                        }
                        m_putQueue++;
                        m_notFull.wait();
                        m_putQueue--;
                    }
                }
            }
        }

        /*
         * Matches ops against each message in turn until a match is found.
         *
         * Params:
         *  ops = The operations to match.  Each may return a bool to indicate
         *        whether a message with a matching type is truly a match.
         *
         * Returns:
         *  true if a message was retrieved and false if not (such as if a
         *  timeout occurred).
         *
         * Throws:
         *  LinkTerminated if a linked thread terminated, or OwnerTerminated
         * if the owner thread terminates and no existing messages match the
         * supplied ops.
         */
        bool get(T...)(scope T vals)
        {
            import std.meta : AliasSeq;

            static assert(T.length);

            static if (isImplicitlyConvertible!(T[0], Duration))
            {
                alias Ops = AliasSeq!(T[1 .. $]);
                alias ops = vals[1 .. $];
                enum timedWait = true;
                Duration period = vals[0];
            }
            else
            {
                alias Ops = AliasSeq!(T);
                alias ops = vals[0 .. $];
                enum timedWait = false;
            }

            bool onStandardMsg(ref Message msg)
            {
                foreach (i, t; Ops)
                {
                    alias Args = Parameters!(t);
                    auto op = ops[i];

                    if (msg.convertsTo!(Args))
                    {
                        static if (is(ReturnType!(t) == bool))
                        {
                            return msg.map(op);
                        }
                        else
                        {
                            msg.map(op);
                            return true;
                        }
                    }
                }
                return false;
            }

            bool onLinkDeadMsg(ref Message msg)
            {
                assert(msg.convertsTo!(Tid));
                auto tid = msg.get!(Tid);

                if (bool* pDepends = tid in thisInfo.links)
                {
                    auto depends = *pDepends;
                    thisInfo.links.remove(tid);
                    // Give the owner relationship precedence.
                    if (depends && tid != thisInfo.owner)
                    {
                        auto e = new LinkTerminated(tid);
                        auto m = Message(MsgType.standard, e);
                        if (onStandardMsg(m))
                            return true;
                        throw e;
                    }
                }
                if (tid == thisInfo.owner)
                {
                    thisInfo.owner = Tid.init;
                    auto e = new OwnerTerminated(tid);
                    auto m = Message(MsgType.standard, e);
                    if (onStandardMsg(m))
                        return true;
                    throw e;
                }
                return false;
            }

            bool onControlMsg(ref Message msg)
            {
                switch (msg.type)
                {
                case MsgType.linkDead:
                    return onLinkDeadMsg(msg);
                default:
                    return false;
                }
            }

            bool scan(ref ListT list)
            {
                for (auto range = list[]; !range.empty;)
                {
                    // Only the message handler will throw, so if this occurs
                    // we can be certain that the message was handled.
                    scope (failure)
                        list.removeAt(range);

                    if (isControlMsg(range.front))
                    {
                        if (onControlMsg(range.front))
                        {
                            // Although the linkDead message is a control message,
                            // it can be handled by the user.  Since the linkDead
                            // message throws if not handled, if we get here then
                            // it has been handled and we can return from receive.
                            // This is a weird special case that will have to be
                            // handled in a more general way if more are added.
                            if (!isLinkDeadMsg(range.front))
                            {
                                list.removeAt(range);
                                continue;
                            }
                            list.removeAt(range);
                            return true;
                        }
                        range.popFront();
                        continue;
                    }
                    else
                    {
                        if (onStandardMsg(range.front))
                        {
                            list.removeAt(range);
                            return true;
                        }
                        range.popFront();
                        continue;
                    }
                }
                return false;
            }

            bool pty(ref ListT list)
            {
                if (!list.empty)
                {
                    auto range = list[];

                    if (onStandardMsg(range.front))
                    {
                        list.removeAt(range);
                        return true;
                    }
                    if (range.front.convertsTo!(Throwable))
                        throw range.front.get!(Throwable);
                    else if (range.front.convertsTo!(shared(Throwable)))
                        throw range.front.get!(shared(Throwable));
                    else
                        throw new PriorityMessageException(range.front.data);
                }
                return false;
            }

            static if (timedWait)
            {
                import core.time : MonoTime;
                auto limit = MonoTime.currTime + period;
            }

            while (true)
            {
                ListT arrived;

                if (pty(m_localPty) || scan(m_localBox))
                {
                    return true;
                }
                yield();
                synchronized (m_lock)
                {
                    updateMsgCount();
                    while (m_sharedPty.empty && m_sharedBox.empty)
                    {
                        // NOTE: We're notifying all waiters here instead of just
                        //       a few because the onCrowding behavior may have
                        //       changed and we don't want to block sender threads
                        //       unnecessarily if the new behavior is not to block.
                        //       This will admittedly result in spurious wakeups
                        //       in other situations, but what can you do?
                        if (m_putQueue && !mboxFull())
                            m_notFull.notifyAll();
                        static if (timedWait)
                        {
                            if (period <= Duration.zero || !m_putMsg.wait(period))
                                return false;
                        }
                        else
                        {
                            m_putMsg.wait();
                        }
                    }
                    m_localPty.put(m_sharedPty);
                    arrived.put(m_sharedBox);
                }
                if (m_localPty.empty)
                {
                    scope (exit) m_localBox.put(arrived);
                    if (scan(arrived))
                    {
                        return true;
                    }
                    else
                    {
                        static if (timedWait)
                        {
                            period = limit - MonoTime.currTime;
                        }
                        continue;
                    }
                }
                m_localBox.put(arrived);
                pty(m_localPty);
                return true;
            }
        }

        /*
         * Called on thread termination.  This routine processes any remaining
         * control messages, clears out message queues, and sets a flag to
         * reject any future messages.
         */
        final void close()
        {
            static void onLinkDeadMsg(ref Message msg)
            {
                assert(msg.convertsTo!(Tid));
                auto tid = msg.get!(Tid);

                thisInfo.links.remove(tid);
                if (tid == thisInfo.owner)
                    thisInfo.owner = Tid.init;
            }

            static void sweep(ref ListT list)
            {
                for (auto range = list[]; !range.empty; range.popFront())
                {
                    if (range.front.type == MsgType.linkDead)
                        onLinkDeadMsg(range.front);
                }
            }

            ListT arrived;

            sweep(m_localBox);
            synchronized (m_lock)
            {
                arrived.put(m_sharedBox);
                m_closed = true;
            }
            m_localBox.clear();
            sweep(arrived);
        }

    private:
        // Routines involving local data only, no lock needed.

        bool mboxFull() @safe @nogc pure nothrow
        {
            return m_maxMsgs && m_maxMsgs <= m_localMsgs + m_sharedBox.length;
        }

        void updateMsgCount() @safe @nogc pure nothrow
        {
            m_localMsgs = m_localBox.length;
        }

        bool isControlMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type != MsgType.standard && msg.type != MsgType.priority;
        }

        bool isPriorityMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type == MsgType.priority;
        }

        bool isLinkDeadMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type == MsgType.linkDead;
        }

        alias OnMaxFn = bool function(Tid);
        alias ListT = List!(Message);

        ListT m_localBox;
        ListT m_localPty;

        Mutex m_lock;
        Condition m_putMsg;
        Condition m_notFull;
        size_t m_putQueue;
        ListT m_sharedBox;
        ListT m_sharedPty;
        OnMaxFn m_onMaxMsgs;
        size_t m_localMsgs;
        size_t m_maxMsgs;
        bool m_closed;
    }

    /*
     *
     */
    struct List(T)
    {
        struct Range
        {
            import std.exception : enforce;

            @property bool empty() const
            {
                return !m_prev.next;
            }

            @property ref T front()
            {
                enforce(m_prev.next, "invalid list node");
                return m_prev.next.val;
            }

            @property void front(T val)
            {
                enforce(m_prev.next, "invalid list node");
                m_prev.next.val = val;
            }

            void popFront()
            {
                enforce(m_prev.next, "invalid list node");
                m_prev = m_prev.next;
            }

            private this(Node* p)
            {
                m_prev = p;
            }

            private Node* m_prev;
        }

        void put(T val)
        {
            put(newNode(val));
        }

        void put(ref List!(T) rhs)
        {
            if (!rhs.empty)
            {
                put(rhs.m_first);
                while (m_last.next !is null)
                {
                    m_last = m_last.next;
                    m_count++;
                }
                rhs.m_first = null;
                rhs.m_last = null;
                rhs.m_count = 0;
            }
        }

        Range opSlice()
        {
            return Range(cast(Node*)&m_first);
        }

        void removeAt(Range r)
        {
            import std.exception : enforce;

            assert(m_count);
            Node* n = r.m_prev;
            enforce(n && n.next, "attempting to remove invalid list node");

            if (m_last is m_first)
                m_last = null;
            else if (m_last is n.next)
                m_last = n; // nocoverage
            Node* to_free = n.next;
            n.next = n.next.next;
            freeNode(to_free);
            m_count--;
        }

        @property size_t length()
        {
            return m_count;
        }

        void clear()
        {
            m_first = m_last = null;
            m_count = 0;
        }

        @property bool empty()
        {
            return m_first is null;
        }

    private:
        struct Node
        {
            Node* next;
            T val;

            this(T v)
            {
                val = v;
            }
        }

        static shared struct SpinLock
        {
            void lock() { while (!cas(&locked, false, true)) { Thread.yield(); } }
            void unlock() { atomicStore!(MemoryOrder.rel)(locked, false); }
            bool locked;
        }

        static shared SpinLock sm_lock;
        static shared Node* sm_head;

        Node* newNode(T v)
        {
            Node* n;
            {
                sm_lock.lock();
                scope (exit) sm_lock.unlock();

                if (sm_head)
                {
                    n = cast(Node*) sm_head;
                    sm_head = sm_head.next;
                }
            }
            if (n)
            {
                import std.conv : emplace;
                emplace!Node(n, v);
            }
            else
            {
                n = new Node(v);
            }
            return n;
        }

        void freeNode(Node* n)
        {
            // destroy val to free any owned GC memory
            destroy(n.val);

            sm_lock.lock();
            scope (exit) sm_lock.unlock();

            auto sn = cast(shared(Node)*) n;
            sn.next = sm_head;
            sm_head = sn;
        }

        void put(Node* n)
        {
            m_count++;
            if (!empty)
            {
                m_last.next = n;
                m_last = n;
                return;
            }
            m_first = n;
            m_last = n;
        }

        Node* m_first;
        Node* m_last;
        size_t m_count;
    }
}

private @property shared(Mutex) initOnceLock()
{
    static shared Mutex lock;
    if (auto mtx = atomicLoad!(MemoryOrder.acq)(lock))
        return mtx;
    auto mtx = new shared Mutex;
    if (cas(&lock, cast(shared) null, mtx))
        return mtx;
    return atomicLoad!(MemoryOrder.acq)(lock);
}

/**
 * Initializes $(D_PARAM var) with the lazy $(D_PARAM init) value in a
 * thread-safe manner.
 *
 * The implementation guarantees that all threads simultaneously calling
 * initOnce with the same $(D_PARAM var) argument block until $(D_PARAM var) is
 * fully initialized. All side-effects of $(D_PARAM init) are globally visible
 * afterwards.
 *
 * Params:
 *   var = The variable to initialize
 *   init = The lazy initializer value
 *
 * Returns:
 *   A reference to the initialized variable
 */
auto ref initOnce(alias var)(lazy typeof(var) init)
{
    return initOnce!var(init, initOnceLock);
}

/// A typical use-case is to perform lazy but thread-safe initialization.
@system unittest
{
    static class MySingleton
    {
        static MySingleton instance()
        {
            __gshared MySingleton inst;
            return initOnce!inst(new MySingleton);
        }
    }

    assert(MySingleton.instance !is null);
}

@system unittest
{
    static class MySingleton
    {
        static MySingleton instance()
        {
            __gshared MySingleton inst;
            return initOnce!inst(new MySingleton);
        }

    private:
        this() { val = ++cnt; }
        size_t val;
        __gshared size_t cnt;
    }

    foreach (_; 0 .. 10)
        spawn({ ownerTid.send(MySingleton.instance.val); });
    foreach (_; 0 .. 10)
        assert(receiveOnly!size_t == MySingleton.instance.val);
    assert(MySingleton.cnt == 1);
}

/**
 * Same as above, but takes a separate mutex instead of sharing one among
 * all initOnce instances.
 *
 * This should be used to avoid dead-locks when the $(D_PARAM init)
 * expression waits for the result of another thread that might also
 * call initOnce. Use with care.
 *
 * Params:
 *   var = The variable to initialize
 *   init = The lazy initializer value
 *   mutex = A mutex to prevent race conditions
 *
 * Returns:
 *   A reference to the initialized variable
 */
auto ref initOnce(alias var)(lazy typeof(var) init, shared Mutex mutex)
{
    // check that var is global, can't take address of a TLS variable
    static assert(is(typeof({ __gshared p = &var; })),
        "var must be 'static shared' or '__gshared'.");
    import core.atomic : atomicLoad, MemoryOrder, atomicStore;

    static shared bool flag;
    if (!atomicLoad!(MemoryOrder.acq)(flag))
    {
        synchronized (mutex)
        {
            if (!atomicLoad!(MemoryOrder.raw)(flag))
            {
                var = init;
                atomicStore!(MemoryOrder.rel)(flag, true);
            }
        }
    }
    return var;
}

/// ditto
auto ref initOnce(alias var)(lazy typeof(var) init, Mutex mutex)
{
    return initOnce!var(init, cast(shared) mutex);
}

/// Use a separate mutex when init blocks on another thread that might also call initOnce.
@system unittest
{
    import core.sync.mutex : Mutex;

    static shared bool varA, varB;
    static shared Mutex m;
    m = new shared Mutex;

    spawn({
        // use a different mutex for varB to avoid a dead-lock
        initOnce!varB(true, m);
        ownerTid.send(true);
    });
    // init depends on the result of the spawned thread
    initOnce!varA(receiveOnly!bool);
    assert(varA == true);
    assert(varB == true);
}

@system unittest
{
    static shared bool a;
    __gshared bool b;
    static bool c;
    bool d;
    initOnce!a(true);
    initOnce!b(true);
    static assert(!__traits(compiles, initOnce!c(true))); // TLS
    static assert(!__traits(compiles, initOnce!d(true))); // local variable
}

// test ability to send shared arrays
@system unittest
{
    static shared int[] x = new shared(int)[1];
    auto tid = spawn({
        auto arr = receiveOnly!(shared(int)[]);
        arr[0] = 5;
        ownerTid.send(true);
    });
    tid.send(x);
    receiveOnly!(bool);
    assert(x[0] == 5);
}
