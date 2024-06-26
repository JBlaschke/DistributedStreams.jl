module DistributedStreams

include("bits.jl")
using .Bits
include("serialize.jl")
using .Serialize

using Base: @kwdef

using Distributed
using DistributedArrays
using Serialization


#_______________________________________________________________________________
# Data Type Representing an entry into the stream database
#-------------------------------------------------------------------------------

@kwdef struct Entry
    id::Int64           = 0
    data::Vector{UInt8} = UInt8[]
    valid::Bool         = false
end

export Entry

#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Helper function to infer return types of a function
# TODO: maybe this should work with varags? Right now the design assumes a
# single input and a single outpuentriest type argument.
#-------------------------------------------------------------------------------

fn_ret_type(fn, in_type::DataType) = Base.return_types(fn, (in_type,))[1]

#-------------------------------------------------------------------------------

function verbose_println(verbose, message)
    if verbose
        println(message)
    end
end

#_______________________________________________________________________________
# Worker functions following a producer-consumer pattern:
# + `launch_monitor` starts a worker that generates `Entry` objects based on a
#   `processor` function. It is a data source (producer)
# + `launch_consumer` starts a worker that consumes `Entry` objects (from a
#   source/producer) and applies a processor function to each. It is a consumer
#   and producer
# + `collect!` consumes all data of type `Entry` and adds it to a vector. It is
#   a data sink (consumer)
#-------------------------------------------------------------------------------

@kwdef struct RemoteWorkerControl
    control::Any
    status::Any
end

"""
    out, control = launch_consumer(
        processor, in;
        workers=workers(),
        verbose=false, buffer_size=32, timeout=1, start_safe=false
    )

Launches a "processor" worker, returning a remote channel containing the
processor output. The worker "lives" indefintely. For every element in `in` (a
RemoteChannel), it applies the function `processor`, and adds its result to
`out` (also a RemoteChannel).

The function `processor` must:
1. Take a single input argument, and return a single output
2. Be statically typed: the input and output types are not allowed to change

The remote worker only quits when it cannot take from `in`. The difference to
`launch_consumer` is that `launch_monitor` creates its own input channel,
whereas `launch_consumer` needs to be given an existing input channel.

`launch_consumer` also returns a `DArray` containing control flags for each
process:
```julia
    (worker=process_id, safe=Ref(start_safe), flag=Ref(false))
```
which is used to control the workers using the `make_safe!`, `make_unsafe!`, and
`stop_workers!` functions. These are used to control the worker's global
behavior:
* `flag` starts by being set to `false`.
* if `safe == true`, then the worker will not check for `flag == true`.
* if `safe == false`, and `flag == true` then the worker is shut if (and only
  if) `take!(in)` takes more than `timeout` seconds.

The `verbose` setting can be used to toggle printing uptdates to stdout.

The `workers` kwarg can be used to specify on which workers `processor` should
run.
"""
function launch_consumer(
        processor, entries;
        workers=workers(),
        verbose=false, buffer_size=32, timeout=1, start_safe=false
    )

    results = RemoteChannel(
            ()->Channel{fn_ret_type(processor, Entry)}(buffer_size)
        )

    remote_worker_control = launch_consumer(
        processor, entries, results;
        workers=workers, verbose=verbose, timeout=timeout, start_safe=start_safe
    )

    return results, remote_worker_control
end

function launch_consumer(
        processor, entries, results;
        workers=workers(),
        verbose=false, timeout=1, start_safe=false
    )

    distributed_control = DArray([
        @spawnat p [(worker = p, safe = Ref(start_safe), flag = Ref(false))]
        for p in workers
    ])

    function remote_worker(fn, entries, results, control)
        local_control = only(localpart(control))
        while true
            # take data from remote channel asynchronously
            t = @async take!(entries)
            # Gard against hanging `take!` calls by periodically checking if the
            # worker is flagged to be shut down. timedwait is slow, so we run
            # this in async mode. `local_control.safe` can be used to skip this
            # check entirely.
            @async while true
                if local_control.safe[]
                    break
                end
                # THIS IS UNSAFE MODE: SLOWER, but it does NOT assume that `t`
                # is bound to finish => introduce timeout which will shut down
                # the worker with `local_control.flag[] == true`
                if timedwait(()->istaskdone(t), timeout) == :ok
                    break
                end
                # ALL CODE ENTERING HERE => TIMEDWAIT TIMED OUT
                if local_control.flag[]  # Shutdown flag raised
                    verbose_println(verbose,
                        "Worker $(local_control.worker) is shutting down"
                    )
                    return
                end
            end
            # process data and return result in output channel -- and sync loop
            @sync put!(results, fn(fetch(t)))
        end
    end

    worker_status = []
    for p in workers
        status = remotecall(
            remote_worker, p,
            processor, entries, results, distributed_control
        )
        push!(worker_status, status)
    end

    return RemoteWorkerControl(
        control=distributed_control,
        status=worker_status
    )
end

export launch_consumer

"""
    in, out, control = launch_monitor(
        processor, in;
        workers=workers(),
        verbose=false, buffer_size=32, timeout=1, start_safe=false
    )

Launches a "processor" worker, returning two remote channels: the inputs (`in`)
and outputs (`out`) used by `processor`. The worker "lives" indefintely. For
every element in `in` (a RemoteChannel), it applies the function `processor`,
and adds its result to `out` (also a RemoteChannel).

The function `processor` must:
1. Take a single input argument, and return a single output
2. Be statically typed: the input and output types are not allowed to change

The remote worker only quits when it cannot take from `in`. The difference to
`launch_consumer` is that `launch_monitor` creates its own input channel,
whereas `launch_consumer` needs to be given an existing input channel.

`launch_consumer` also returns a `DArray` containing control flags for each
process:
```julia
    (worker=process_id, safe=Ref(start_safe), flag=Ref(false))
```
which is used to control the workers using the `make_safe!`, `make_unsafe!`, and
`stop_workers!` functions. These are used to control the worker's global
behavior:
* `flag` starts by being set to `false`.
* if `safe == true`, then the worker will not check for `flag == true`.
* if `safe == false`, and `flag == true` then the worker is shut if (and only
  if) `take!(in)` takes more than `timeout` seconds.

The `verbose` setting can be used to toggle printing uptdates to stdout.

The `workers` kwarg can be used to specify on which workers `processor` should
run.
"""
function launch_monitor(
        processor;
        workers=workers(),
        verbose=false, buffer_size=32, timeout=1, start_safe=false
    )

    entries = RemoteChannel(()->Channel{Entry}(buffer_size))

    results, remote_worker_control = launch_consumer(
        processor, entries;
        workers=workers,
        verbose=verbose, buffer_size=32, timeout=timeout, start_safe=start_safe
    )

    return entries, results, remote_worker_control
end

export launch_monitor

function collect!(
        results::A; collect_time=1,
    ) where {
             T <: Any,
             S <: AbstractChannel{T},
             A <: Union{S, RemoteChannel{S}}
            }

    collected = Vector{T}()

    t = @async while true
        fd = take!(results)
        push!(collected, fd)
    end

    sleep(collect_time)
    # Note that this is potentially unsafe. TODO: implement better solution once
    # https://github.com/JuliaLang/julia/issues/6283 and
    # https://github.com/JuliaLang/julia/issues/36217 are fixed
    schedule(t, InterruptException(), error=true)

    return collected
end

export collect!

"""
    make_safe!(control; workers=workers())

Sets workers managed by `control` into "safe" mode: the worker assumes that
there is enough data in the input channel for `take!(in)` not to become
deadlocked. This can save time and resources by not polling `@async take!`.

The `workers` kwarg can be used to specify on which workers `processor` should
run.
"""
function make_safe!(control::DArray{T}; workers=workers()) where T <: Any
    for p in workers
        @fetchfrom p only(localpart(control)).safe[] = true
    end
end

make_safe!(control::RemoteWorkerControl; workers=workers()) = make_safe!(
    control.control; workers
)

export make_safe!

"""
    make_unsafe!(control; workers=workers())

Sets workers managed by `control` into "unsafe" mode: the worker assumes that
data could stop coming -- possibly causing `take!(in)` to become deadlocked. In
order to avoid this, for every `take!` the worker polls the status of the
`take!` task -- if it times out, and the shutdown flag (set up `stop_workers!`)
is set, then the worker will shut down.

**Note:** Safe mode is not protected from deadlocked `take!` operations --
therefore it is off by default. Only turn safe mode on if conserving resources.

The `workers` kwarg can be used to specify on which workers `processor` should
run.
"""
function make_unsafe!(control::DArray{T}; workers=workers()) where T <: Any
    for p in workers
        @fetchfrom p only(localpart(control)).safe[] = false
    end
end

make_unsafe!(control::RemoteWorkerControl; workers=workers()) = make_unsafe!(
    control.control; workers
)

export make_unsafe!

"""
    stop_workers!(control; workers=workers())

Sets the shutdown flag on the workers managed by `control`. If there is no more
data in the input RemoteChannel (determined by checking that `take!(in)`
finishes before `timeout`), then the worker shuts down.

**Note:** this setting has no effect on workers that are not in unsafe mode. It
is therefore recommended that you call `make_unsafe!` in addition to calling
`stop_workers!` these do not have to be called in a particular order -- however
they will not resolve a deadlocked worker. In order to resolve a deadlocked
worker, ensure that `make_unsafe!` and `stop_workers!` is called, then send some
junk data into the input channel.

The `workers` kwarg can be used to specify on which workers `processor` should
run.
"""
function stop_workers!(control::DArray{T}; workers=workers()) where T <:Any
    for p in workers
        @fetchfrom p only(localpart(control)).flag[] = true
    end
end

stop_workers!(control::RemoteWorkerControl; workers=workers()) = stop_workers!(
    control.control; workers
)

export stop_workers!

#-------------------------------------------------------------------------------

@enum MessageType begin
    start
    stop
    started
    stopped
    failed
    completed
end

@kwdef struct FunctionPayload
    f::Function
    in::RemoteChannel
    out::RemoteChannel
end

struct ReturnPayload
    value::Any
end

@kwdef struct ControlMessage
    message_type::MessageType
    target::Int64
    payload::Union{Nothing, FunctionPayload, ReturnPayload}
end

function sendfunc(f::Function, dest::Int64, mod::Union{Module, Nothing}=nothing)
    if isnothing(mod)
        mod = parentmodule(f)
    end
    # get fully-qualified name of function
    fname = Symbol(f)
    mname = Symbol(mod)
    # sender serializes function
    buf = IOBuffer()
    Serialization.serialize(buf, methods(eval(:($mname.$fname))))
    # receiver deserializes function
    Distributed.remotecall_eval(
        mod, [dest], quote
            function $fname end
            Serialization.deserialize(seekstart($buf))
        end
    )
end

export sendfunc

function launch_sentinel(
        ;workers=[2], verbose=false, buffer_size=32, timeout=1, start_safe=true
    )

    distributed_control = DArray([
        @spawnat p [(worker = p, flag = Ref(false))]
        for p in workers
    ])

    function remote_worker(entries, results, control)
        # list of active workers
        active_workers = Dict{Int64}{RemoteWorkerControl}()
        active_watchers = Dict{Int64}{Task}()

        # controller used to modify the behaviour of a running worker, e.g.
        # shut it down gracefully
        local_control = only(localpart(control))

        # create mechanism to bypass take! if message is not ready => avoid
        # blocking channel with a `fetch`
        message_task = @async take!(entries)

        while true
            #___________________________________________________________________
            # check for any failed workers -- if failures did occur, report them
            # as a `failed` type message and remove them from the active_workers
            # list
            #-------------------------------------------------------------------

            # check the status of Distributed worker processes => External
            # interrupt could have killed those
            current_worker_list = Distributed.workers()
            for w in keys(active_workers)
                # active worker doesn't have a watcher => start one
                if !(w in keys(active_watchers))
                    active_watchers[w] = @async fetch(
                        only(active_workers[w].status)
                    ) # assumption: workers only ever active on a single process
                    println("Worker started for: $(w)")
                end
                # active worker process no longer running => report
                if !(w in current_worker_list)
                    @async put!(results, ControlMessage(
                        message_type=failed,
                        target=w,
                        payload=nothing
                    ))
                    delete!(active_workers, w)
                    verbose_println(verbose, "Worker $(w) died")
                end
            end

            # check the status of the watchers => Internal error could have
            # caused the workers to complete execution
            for w in keys(active_watchers)
                if istaskdone(active_watchers[w])
                    @async put!(results, ControlMessage(
                        message_type=completed,
                        target=w,
                        payload=ReturnPayload(active_watchers[w].result)
                    ))
                    verbose_println(verbose, "Worker $(w) completed")
                    delete!(active_watchers, w)
                    delete!(active_workers, w)  # delete worker also => avoid restart loop
                end
            end

            #___________________________________________________________________
            # Process control messages, and check if the worker is flagged to be
            # shut down (shutdown occurs only if no more messages are to be
            # processed).
            #-------------------------------------------------------------------

            if ! istaskdone(message_task)
                sleep(timeout)

                if (! istaskdone(message_task)) && local_control.flag[]
                    # Shutdown flag raised and no more messages have arrived
                    verbose_println(verbose,
                        "Sentinel on $(local_control.worker) is shutting down"
                    )
                    break
                end
                # No more messages have arrived, but shutodwn order hasn't been
                # given either => go to top of loop and check for failed workers
                continue
            end

            message = fetch(message_task)

            if message.message_type == start
                verbose_println(verbose, "Start instruction for $(message.target)")
                if typeof(message.payload) != FunctionPayload
                    @async put!(results, ControlMessage(
                        message_type=completed,
                        target=message.target,
                        payload=ReturnPayload(ArgumentError(
                            "Start request does not contain function"
                        ))
                    ))
                else
                    func::FunctionPayload = message.payload
                    control = launch_consumer(
                        func.f, func.in, func.out;
                        workers=[message.target], verbose=verbose,
                        timeout=timeout, start_safe=start_safe
                    )
                    active_workers[message.target] = control
                    @async put!(results, ControlMessage(
                        message_type=started,
                        target=message.target,
                        payload=nothing
                    ))
                end
            elseif message.message_type == stop
                verbose_println(verbose, "Stop instruction for $(message.target)")
                if message.target in keys(active_workers)
                    make_unsafe!(
                        active_workers[message.target];
                        workers=[message.target]
                    )
                    stop_workers!(
                        active_workers[message.target];
                        workers=[message.target]
                    )
                    @async put!(results, ControlMessage(
                        message_type=stopped,
                        target=message.target,
                        payload=nothing
                    ))
                    delete!(active_workers, message.target)
                end
            else
                # all other message types ignored by putting them directly into
                # the output channel
                @async put!(results, message)
            end

            # All done with this one => take the next message, rinse, repeat
            message_task = @async take!(entries)
        end
    end

    # these remote channels are owned by PID=1
    control_messages  = RemoteChannel(
        ()->Channel{ControlMessage}(buffer_size), 1
    )
    control_responses = RemoteChannel(
        ()->Channel{ControlMessage}(buffer_size), 1
    )

    worker_status = []
    for p in workers
        status = remotecall(
            remote_worker, p,
            control_messages, control_responses, distributed_control
        )
        push!(worker_status, status)
    end

    return control_messages, control_responses, RemoteWorkerControl(
        control=distributed_control,
        status=worker_status
    )
end

export launch_sentinel, ControlMessage, FunctionPayload, ReturnPayload, MessageType

end # module DistributedStreams
