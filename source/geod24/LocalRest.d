/*******************************************************************************

    Provides utilities to mock a network in unittests

    This module is based on the idea that D `interface`s can be used
    to represent a server's API, and that D `class` inheriting this `interface`
    are used to define the server's business code,
    abstracting away the communication layer.

    For example, a server that exposes an API to concatenate two strings would
    define the following code:
    ---
    interface API { public string concat (string a, string b); }
    class Server : API
    {
        public override string concat (string a, string b)
        {
            return a ~ b;
        }
    }
    ---

    Then one can use "generators" to define how multiple process communicate
    together. One such generator, that pioneered this design is `vibe.web.rest`,
    which allows to expose such servers as REST APIs.

    `localrest` is another generator, which uses message passing and threads
    to create a local "network".
    The motivation was to create a testing library that could be used to
    model a network at a much cheaper cost than spawning processes
    (and containers) would be, when doing integration tests.

    Control_Interface:
    When instantiating a `RemoteAPI`, one has the ability to call foreign
    implementations through auto-generated `override`s of the `interface`.
    In addition to that, as this library is intended for testing,
    a few extra functionalities are offered under a control interface,
    accessible under the `ctrl` namespace in the instance.
    The control interface allows to make the node unresponsive to one or all
    methods, for some defined time or until unblocked.
    See `sleep`, `filter`, and `clearFilter` for more details.

    Event_Loop:
    Server process usually needs to perform some action in an asynchronous way.
    Additionally, some actions needs to be completed at a semi-regular interval,
    for example based on a timer.
    For those use cases, a node should call `runTask` or `sleep`, respectively.
    Note that this has the same name (and purpose) as Vibe.d's core primitives.
    Users should only ever call Vibe's `runTask` / `sleep` with `vibe.web.rest`,
    or only call LocalRest's `runTask` / `sleep` with `RemoteAPI`.

    Implementation:
    In order for tests to simulate an asynchronous system accurately,
    multiple nodes need to be able to run concurrently and asynchronously.

    There are two common solutions to this, to use either fibers or threads.
    Fibers have the advantage of being simpler to implement and predictable.
    Threads have the advantage of more accurately describing an asynchronous
    system and thus have the ability to uncover more issues.

    When spawning a node, a thread is spawned, a node is instantiated with
    the provided arguments, and an event loop waits for messages sent
    to the Tid. Messages consist of the sender's Tid, the mangled name
    of the function to call (to support overloading) and the arguments,
    serialized as a JSON string.

    Note:
    While this module's original motivation was to test REST nodes,
    the only dependency to Vibe.d is actually to it's JSON module,
    as Vibe.d is the only available JSON module known to the author
    to provide an interface to deserialize composite types.

    Removed Tid
    Added ITransceiver

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2018-2019 Mathias Lang. All rights reserved.

*******************************************************************************/

module geod24.LocalRest;

import geod24.concurrency;

import vibe.data.json;

import std.meta : AliasSeq;
import std.traits : Parameters, ReturnType;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time;

/// Data sent by the caller
private struct Request
{
    /// ITransceiver of the sender thread
    ITransceiver sender;
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response`
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;
    /// Method to call
    string method;
    /// Arguments to the method, JSON formatted
    string args;
};

/// Status of a request
private enum Status
{
    /// Request failed
    Failed,

    /// Request timed-out
    Timeout,

    /// Request succeeded
    Success
};

/// Data sent by the callee back to the caller
private struct Response
{
    /// Final status of a request (failed, timeout, success, etc)
    Status status;
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response` so the scheduler can
    /// properly dispatch this event
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;
    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
};

/// Ask the node to exhibit a certain behavior for a given time
private struct TimeCommand
{
    /// For how long our remote node apply this behavior
    Duration dur;
    /// Whether or not affected messages should be dropped
    bool drop = false;
}

/// Filter out requests before they reach a node
private struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}

/// Simple wrapper to deal with tuples
/// Vibe.d might emit a pragma(msg) when T.length == 0
private struct ArgWrapper (T...)
{
    static if (T.length == 0)
        size_t dummy;
    T args;
}

/*******************************************************************************

    Receve request and response
    Interfaces to and from data

*******************************************************************************/

private interface ITransceiver
{
    /***************************************************************************

        It is a function that accepts `Request`.

    ***************************************************************************/

    void send (Request msg);


    /***************************************************************************

        It is a function that accepts `Response`.

    ***************************************************************************/

    void send (Response msg);


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    void toString (scope void delegate(const(char)[]) sink);
}


/*******************************************************************************

    Accept only Request. It has `Channel!Request`

*******************************************************************************/

private class ServerTransceiver : ITransceiver
{
    /// Channel of Request
    private Channel!Request req;

    /// Channel of TimeCommand - Using for sleeping
    private Channel!TimeCommand ctrl_time;

    /// Channel of FilterAPI - Using for filtering
    private Channel!FilterAPI ctrl_filter;

    /// Ctor
    public this () @safe nothrow
    {
        req = new Channel!Request();
        ctrl_time = new Channel!TimeCommand();
        ctrl_filter = new Channel!FilterAPI();
    }


    /***************************************************************************

        It is a function that accepts `Request`.

    ***************************************************************************/

    public void send (Request msg) @trusted
    {
        if (thisScheduler !is null)
            this.req.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.req.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        It is a function that accepts `TimeCommand`.

    ***************************************************************************/

    public void send (TimeCommand msg) @trusted
    {
        if (thisScheduler !is null)
            this.ctrl_time.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.ctrl_time.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }

    /***************************************************************************

        It is a function that accepts `FilterAPI`.

    ***************************************************************************/

    public void send (FilterAPI msg) @trusted
    {
        if (thisScheduler !is null)
            this.ctrl_filter.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.ctrl_filter.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        It is a function that accepts `Response`.
        It is not use.

    ***************************************************************************/

    public void send (Response msg) @trusted
    {
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    public void close () @trusted
    {
        this.req.close();
        this.ctrl_time.close();
        this.ctrl_filter.close();
    }


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "STR(%x:0)", cast(void*) req);
    }
}

/*******************************************************************************

    Accept only Response. It has `Channel!Response`

*******************************************************************************/

private class ClientTransceiver : ITransceiver
{
    /// Channel of Response
    private Channel!Response res;

    /// Ctor
    public this () @safe nothrow
    {
        res = new Channel!Response();
    }


    /***************************************************************************

        It is a function that accepts `Request`.
        It is not use.

    ***************************************************************************/

    public void send (Request msg) @trusted
    {
    }


    /***************************************************************************

        It is a function that accepts `Response`.

    ***************************************************************************/

    public void send (Response msg) @trusted
    {
        if (thisScheduler !is null)
            this.res.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.res.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    public void close () @trusted
    {
        this.res.close();
    }


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "CTR(0:%x)", cast(void*) res);
    }
}


/*******************************************************************************

    After making the request, wait until the response comes,
    and find the response that suits the request.

*******************************************************************************/

private class WaitingManager
{
    /// Just a Condition with a state
    private struct Waiting
    {
        Condition c;
        bool busy;
    }

    /// The 'Response' we are currently processing, if any
    public Response pending;

    /// Request IDs waiting for a response
    public Waiting[ulong] waiting;

    /// Get the next available request ID
    public size_t getNextResponseId () @safe nothrow
    {
        static size_t last_idx;
        return last_idx++;
    }

    /// Wait for a response.
    public Response waitResponse (size_t id, Duration duration) @trusted nothrow
    {
        try
        {
            if (id !in this.waiting)
                this.waiting[id] = Waiting(thisScheduler.newCondition(null), false);

            Waiting* ptr = &this.waiting[id];
            if (ptr.busy)
                assert(0, "Trying to override a pending request");

            // We yield and wait for an answer
            ptr.busy = true;

            if (duration == Duration.init)
                ptr.c.wait();
            else if (!ptr.c.wait(duration))
                this.pending = Response(Status.Timeout, id, "");

            ptr.busy = false;
            // After control returns to us, `pending` has been filled
            scope(exit) this.pending = Response.init;
            return this.pending;
        }
        catch (Exception e)
        {
            import std.format;
            assert(0, format("Exception - %s", e.message));
        }
    }

    /// Called when a waiting condition was handled and can be safely removed
    public void remove (size_t id) @safe nothrow
    {
        this.waiting.remove(id);
    }

    /// Returns true if a key value equal to id exists.
    public bool exist (size_t id) @safe nothrow
    {
        return ((id in this.waiting) !is null);
    }
}

/// Helper template to get the constructor's parameters
private static template CtorParams (Impl)
{
    static if (is(typeof(Impl.__ctor)))
        private alias CtorParams = Parameters!(Impl.__ctor);
    else
        private alias CtorParams = AliasSeq!();
}


/*******************************************************************************

    Receive requests, To obtain and return results by passing
    them to an instance of the Node.

*******************************************************************************/

private class Server (API)
{
    /***************************************************************************

        Instantiate a node and start it

        This is usually called from the main thread, which will start all the
        nodes and then start to process request.
        In order to have a connected network, no nodes in any thread should have
        a different reference to the same node.
        In practice, this means there should only be one `ServerTransceiver`
        per "address".

        Note:
            When the `Server` returned by this function is finalized,
            the child thread will be shut down.
            This ownership mechanism should be replaced with reference counting
            in a later version.

        Params:
            Impl = Type of the implementation to instantiate
            args = Arguments to the object's constructor

        Returns:
            A `Server` owning the node reference

    ***************************************************************************/

    public static Server!API spawn (Impl) (CtorParams!Impl args)
    {
        auto transceiver = spawned!Impl(args);
        return new Server(transceiver);
    }


    /***************************************************************************

        Handler function

        Performs the dispatch from `req` to the proper `node` function,
        provided the function is not filtered.

        Params:
            req    = the request to run (contains the method name and the arguments)
            node   = the node to invoke the method on
            filter = used for filtering API calls (returns default response)

    ***************************************************************************/

    private static void handleRequest (Request req, API node, FilterAPI filter)
    {
        import std.format;

        switch (req.method)
        {
            static foreach (member; __traits(allMembers, API))
            static foreach (ovrld; __traits(getOverloads, API, member))
            {
                mixin(
                q{
                    case `%2$s`:
                    try
                    {
                        if (req.method == filter.func_mangleof)
                        {
                            // we have to send back a message
                            import std.format;
                            req.sender.send(Response(Status.Failed, req.id,
                                format("Filtered method '%%s'", filter.pretty_func)));
                            return;
                        }

                        auto args = req.args.deserializeJson!(ArgWrapper!(Parameters!ovrld));

                        static if (!is(ReturnType!ovrld == void))
                        {
                            req.sender.send(Response(Status.Success, req.id, node.%1$s(args.args).serializeToJsonString()));
                        }
                        else
                        {
                            node.%1$s(args.args);
                            req.sender.send(Response(Status.Success, req.id));
                        }
                    }
                    catch (Throwable t)
                    {
                        // Our sender expects a response
                        req.sender.send(Response(Status.Failed, req.id, t.toString()));
                    }

                    return;
                }.format(member, ovrld.mangleof));
            }
        default:
            assert(0, "Unmatched method name: " ~ req.method);
        }
    }


    /***************************************************************************

        Main dispatch function

        This function receive string-serialized messages from the calling thread,
        which is a struct with the sender's ITransceiver, the method's mangleof,
        and the method's arguments as a tuple, serialized to a JSON string.

        Params:
            Implementation = Type of the implementation to instantiate
            args = Arguments to `Implementation`'s constructor

    ***************************************************************************/

    private static ServerTransceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        import std.datetime.systime : Clock, SysTime;

        ServerTransceiver transceiver = new ServerTransceiver();
        auto thread_scheduler = ThreadScheduler.instance;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;    // filter specific messages
            SysTime sleep_until; // sleep until this time
            bool drop;           // drop messages if sleeping
        }

        thread_scheduler.spawn({

            scope node = new Implementation(cargs);

            Control control;

            bool isSleeping()
            {
                return control.sleep_until != SysTime.init
                    && Clock.currTime < control.sleep_until;
            }

            void handle (Request req)
            {
                thisScheduler.spawn(() {
                    Server!(API).handleRequest(req, node, control.filter);
                });
            }

            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                bool terminate = false;
                thisScheduler.spawn({
                    while (!terminate)
                    {
                        Request req = transceiver.req.receive();

                        if (req.method == "shutdown@command")
                            terminate = true;

                        if (terminate)
                            break;

                        if (!isSleeping())
                        {
                            thisScheduler.spawn({
                                Server!(API).handleRequest(req, node, control.filter);
                            });
                        }
                        else if (!control.drop)
                        {
                            auto c = thisScheduler.newCondition(null);
                            thisScheduler.spawn({
                                while (isSleeping())
                                    thisScheduler.wait(c, 1.msecs);
                                Server!(API).handleRequest(req, node, control.filter);
                            });
                        }
                    }
                });

                thisScheduler.spawn({
                    while (!terminate)
                    {
                        TimeCommand time_command = transceiver.ctrl_time.receive();

                        if (terminate)
                            break;

                        control.sleep_until = Clock.currTime + time_command.dur;
                        control.drop = time_command.drop;
                    }
                });

                thisScheduler.spawn({
                    while (!terminate)
                    {
                        FilterAPI filter = transceiver.ctrl_filter.receive();

                        if (terminate)
                            break;

                        control.filter = filter;
                    }
                });
            });
        });

        return transceiver;
    }

    /// Devices that can receive requests.
    private ServerTransceiver _transceiver;


    /***************************************************************************

        Create an instante of a `Server`

        Params:
            transceiver = This is an instance of `ServerTransceiver` and
                a device that can receive requests.

    ***************************************************************************/

    public this (ServerTransceiver transceiver) @nogc pure nothrow
    {
        this._transceiver = transceiver;
    }


    /***************************************************************************

        Returns the `ServerTransceiver`

        This can be useful for calling `geod24.concurrency.register` or similar.
        Note that the `ServerTransceiver` should not be used directly,
        as our event loop, would error out on an unknown message.

    ***************************************************************************/

    @property public ServerTransceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        Send an async message to the thread to immediately shut down.

    ***************************************************************************/

    public void shutdown () @trusted
    {
        this._transceiver.send(Request(null, 0, "shutdown@command"));
        this._transceiver.close();
    }
}


/*******************************************************************************

    Request to the `Server`, receive a response

*******************************************************************************/

private class Client
{
    /// Devices that can receive a response
    private ClientTransceiver _transceiver;

    /// After making the request, wait until the response comes,
    /// and find the response that suits the request.
    private WaitingManager _manager;

    /// Timeout to use when issuing requests
    private Duration _timeout;

    ///
    private bool _terminate;

    /// Ctor
    public this (Duration timeout = Duration.init) @safe nothrow
    {
        this._transceiver = new ClientTransceiver;
        this._manager = new WaitingManager();
        this._timeout = timeout;
    }


    /***************************************************************************

        Returns client's Transceiver.
        It accept only `Response`.

        Returns:
            Client's Transceiver

    ***************************************************************************/

    @property public ClientTransceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        This enables appropriate responses to requests through the API

        Params:
           remote = Instance of ServerTransceiver
           req = `Request`
           res = `Response`

    ***************************************************************************/

    public void router (ServerTransceiver remote, ref Request req, ref Response res) @trusted
    {
        this._terminate = false;

        if (thisScheduler is null)
            thisScheduler = new FiberScheduler();

        thisScheduler.spawn({
            remote.send(req);
        });

        Condition cond = thisScheduler.newCondition(null);
        thisScheduler.spawn({
            while (!this._terminate)
            {
                Response res = this._transceiver.res.receive();

                if (this._terminate)
                    break;

                while (!this._manager.exist(res.id))
                    cond.wait(1.msecs);

                this._manager.pending = res;
                this._manager.waiting[res.id].c.notify();
                this._manager.remove(res.id);
            }
        });

        thisScheduler.start({
            res = this._manager.waitResponse(req.id, this._timeout);
            this._terminate = true;
        });
    }


    /***************************************************************************

        Send an async message to the thread to immediately shut down.

    ***************************************************************************/

    public void shutdown () @trusted
    {
        this._terminate = true;
        this._transceiver.close();
    }


    /***************************************************************************

        Get next response id

        Returns:
            Next Response id, It use in Resuest's id

    ***************************************************************************/

    public size_t getNextResponseId () @trusted nothrow
    {
        return this._manager.getNextResponseId();
    }
}


/*******************************************************************************

    It has one `Server` and one `Client`. make a new thread It uses `Server`.

*******************************************************************************/

public class RemoteAPI (API) : API
{
    /***************************************************************************

        Instantiate a node and start it

        This is usually called from the main thread, which will start all the
        nodes and then start to process request.
        In order to have a connected network, no nodes in any thread should have
        a different reference to the same node.
        In practice, this means there should only be one `ServerTransceiver`
        per "address".

        Note:
          When the `RemoteAPI` returned by this function is finalized,
          the child thread will be shut down.
          This ownership mechanism should be replaced with reference counting
          in a later version.

        Params:
          Impl = Type of the implementation to instantiate
          args = Arguments to the object's constructor
          timeout = (optional) timeout to use with requests

        Returns:
          A `RemoteAPI` owning the node reference

    ***************************************************************************/

    public static RemoteAPI!(API) spawn (Impl) (CtorParams!Impl args)
    {
        auto server = Server!API.spawn!Impl(args);
        return new RemoteAPI(server.transceiver);
    }

    /// A device that can requests.
    private ServerTransceiver _server_transceiver;

    /// Request to the `Server`, receive a response
    private Client _client;

    // Vibe.d mandates that method must be @safe
    @safe:

    /***************************************************************************

        Create an instante of a client

        This connects to an already instantiated node.
        In order to instantiate a node, see the static `spawn` function.

        Params:
            transceiver = `ServerTransceiver` of the node.
            timeout = any timeout to use

    ***************************************************************************/

    public this (ServerTransceiver transceiver, Duration timeout = Duration.init) @safe nothrow
    {
        this._server_transceiver = transceiver;
        this._client = new Client(timeout);
    }


    /***************************************************************************

        Introduce a namespace to avoid name clashes

        The only way we have a name conflict is if someone exposes `ctrl`,
        in which case they will be served an error along the following line:
        LocalRest.d(...): Error: function `RemoteAPI!(...).ctrl` conflicts
        with mixin RemoteAPI!(...).ControlInterface!() at LocalRest.d(...)

    ***************************************************************************/

    public mixin ControlInterface!() ctrl;

    /// Ditto
    private mixin template ControlInterface ()
    {

        /***********************************************************************

            Returns the `ServerTransceiver`

        ***********************************************************************/

        @property public ServerTransceiver transceiver () @safe nothrow
        {
            return this._server_transceiver;
        }


        /***********************************************************************

            Send an async message to the thread to immediately shut down.

        ***********************************************************************/

        public void shutdown () @trusted
        {
            this._server_transceiver.send(Request(null, 0, "shutdown@command"));
            this._server_transceiver.close();
            this._client.shutdown();
        }


        /***********************************************************************

            Make the remote node sleep for `Duration`

            The remote node will call `Thread.sleep`, becoming completely
            unresponsive, potentially having multiple tasks hanging.
            This is useful to simulate a delay or a network outage.

            Params:
              delay = Duration the node will sleep for
              dropMessages = Whether to process the pending requests when the
                             node come back online (the default), or to drop
                             pending traffic

        ***********************************************************************/

        public void sleep (Duration d, bool dropMessages = false) @trusted
        {
            this._server_transceiver.send(TimeCommand(d, dropMessages));
        }


        /***********************************************************************

            Filter any requests issued to the provided method.

            Calling the API endpoint will throw an exception,
            therefore the request will fail.

            Use via:

            ----
            interface API { void call(); }
            class C : API { void call() { } }
            auto obj = new RemoteAPI!API(...);
            obj.filter!(API.call);
            ----

            To match a specific overload of a method, specify the
            parameters to match against in the call. For example:

            ----
            interface API { void call(int); void call(int, float); }
            class C : API { void call(int) {} void call(int, float) {} }
            auto obj = new RemoteAPI!API(...);
            obj.filter!(API.call, int, float);  // only filters the second overload
            ----

            Params:
              method = the API method for which to filter out requests
              OverloadParams = (optional) the parameters to match against
                  to select an overload. Note that if the method has no other
                  overloads, then even if that method takes parameters and
                  OverloadParams is empty, it will match that method
                  out of convenience.

        ***********************************************************************/

        public void filter (alias method, OverloadParams...) () @trusted
        {
            import std.format;
            import std.traits;
            enum method_name = __traits(identifier, method);

            // return the mangled name of the matching overload
            template getBestMatch (T...)
            {
                static if (is(Parameters!(T[0]) == OverloadParams))
                {
                    enum getBestMatch = T[0].mangleof;
                }
                else static if (T.length > 0)
                {
                    enum getBestMatch = getBestMatch!(T[1 .. $]);
                }
                else
                {
                    static assert(0,
                        format("Couldn't select best overload of '%s' for " ~
                        "parameter types: %s",
                        method_name, OverloadParams.stringof));
                }
            }

            // ensure it's used with API.method, *not* RemoteAPI.method which
            // is an override of API.method. Otherwise mangling won't match!
            // special-case: no other overloads, and parameter list is empty:
            // just select that one API method
            alias Overloads = __traits(getOverloads, API, method_name);
            static if (Overloads.length == 1 && OverloadParams.length == 0)
            {
                immutable pretty = method_name ~ Parameters!(Overloads[0]).stringof;
                enum mangled = Overloads[0].mangleof;
            }
            else
            {
                immutable pretty = format("%s%s", method_name, OverloadParams.stringof);
                enum mangled = getBestMatch!Overloads;
            }

            this._server_transceiver.send(FilterAPI(mangled, pretty));
        }


        /***********************************************************************

            Clear out any filtering set by a call to filter()

        ***********************************************************************/

        public void clearFilter () @trusted
        {
            this._server_transceiver.send(FilterAPI(""));
        }
    }

    static foreach (member; __traits(allMembers, API))
        static foreach (ovrld; __traits(getOverloads, API, member))
        {
            mixin(q{
                override ReturnType!(ovrld) } ~ member ~ q{ (Parameters!ovrld params)
                {
                    auto serialized = ArgWrapper!(Parameters!ovrld)(params)
                        .serializeToJsonString();

                    auto req = Request(this._client.transceiver, this._client.getNextResponseId(), ovrld.mangleof, serialized);
                    Response res;
                    this._client.router(this._server_transceiver, req, res);

                    if (res.status == Status.Failed)
                        throw new Exception(res.data);

                    if (res.status == Status.Timeout)
                        throw new Exception(serializeToJsonString("Request timed-out"));

                    static if (!is(ReturnType!(ovrld) == void))
                        return res.data.deserializeJson!(typeof(return));
                }
            });
        }
}

/// Simple usage example
unittest
{
    static interface API
    {
        @safe:
        public @property ulong getValue ();
    }

    static class MyAPI : API
    {
        @safe:
        public override @property ulong getValue ()
        { return 42; }
    }

    scope test = RemoteAPI!API.spawn!MyAPI();
    assert(test.getValue() == 42);

    test.shutdown();
}
