module DistributedStreams

include("bits.jl")
using .Bits

using Base: @kwdef

using Distributed
using DistributedArrays
using CodecZlib
using Chain
using JSON
using Dates


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
# single input and a single output type argument.
#-------------------------------------------------------------------------------

fn_ret_type(fn, in_type::DataType) = Base.return_types(fn, (in_type,))[1]

#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Helper functions to compress and decompress data, using these functions
# ensure that a consistent compression and decompression algorithm is used
#-------------------------------------------------------------------------------

compress(data)   = transcode(ZlibCompressor,   data)
decompress(data) = transcode(ZlibDecompressor, data)

export compress, decompress

function serialize(data)
    @chain data begin
        Bits.to_bits(_)
        compress(_)
    end
end

function deserialize(data)
    @chain data begin
        decompress(_)
        Bits.from_bits(_)
    end
end

export serialize, deserialize

#-------------------------------------------------------------------------------

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

    distributed_control = launch_consumer(
        processor, entries, results;
        workers=workers, verbose=verbose, buffer_size=buffer_size,
        timeout=timeout, start_safe=start_safe
    )

    return results, distributed_control
end

function launch_consumer(
        processor, entries, results;
        workers=workers(),
        verbose=false, buffer_size=32, timeout=1, start_safe=false
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
                    if verbose
                        println("Worker $(local_control.worker) is shutting down")
                    end
                    return
                end
            end
            # process data and return result in output channel -- and sync loop
            @sync put!(results, fn(fetch(t)))
        end
    end

    for p in workers
        remote_do(
            remote_worker, p,
            processor, entries, results, distributed_control
        )
    end

    return distributed_control
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

    results, distributed_control = launch_consumer(
        processor, entries;
        workers=workers,
        verbose=false, buffer_size=32, timeout=1, start_safe=false
    )

    return entries, results, distributed_control
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
function make_safe!(control; workers=workers())
    for p in workers
        @fetchfrom p only(localpart(control)).safe[] = true
    end
end

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
function make_unsafe!(control; workers=workers())
    for p in workers
        @fetchfrom p only(localpart(control)).safe[] = false
    end
end

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
function stop_workers!(control; workers=workers())
    for p in workers
        @fetchfrom p only(localpart(control)).flag[] = true
    end
end

export stop_workers!

#-------------------------------------------------------------------------------

end # module DistributedStreams
