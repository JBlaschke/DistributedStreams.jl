module DistributedStreams

include("bits.jl")
using .Bits

using Base: @kwdef

using Distributed
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
    in, out = launch_monitor(processor; buffer_size=32)

Launches a "processor" worker, returning two remote channels: an input and an
output. The worker "lives" indefintely. For every element in `in`, it applies
the function `processor`, and adds its result to `out`.

The function `processor` must:
1. Take a single input argument, and return a single output
2. Be statically typed: the input and output types are not allowed to change

The monitor worker only quits when it cannot take from `in`. The difference to
`launch_consumer` is that `launch_monitor` creates its own input channel,
whereas `launch_consumer` needs to be given an existing input channel.
"""
function launch_monitor(processor; buffer_size=32)
    function remote_monitor(fn, entries, results)
        @sync while true
            entry = try
                take!(entries)
            catch y
                # TODO: This should be handled more gracefully: only kill the
                # worker if there is the "right" error
                println(y)
                break
            end
            t = @async fn(entry)
            @async put!(results, fetch(t))
        end
    end

    entries = RemoteChannel(()->Channel{Entry}(buffer_size))
    results = RemoteChannel(
            ()->Channel{fn_ret_type(processor, Entry)}(buffer_size)
        )

    for p in workers()
        remote_do(remote_monitor, p, processor, entries, results)
    end

    return entries, results
end

export launch_monitor

function launch_consumer(processor, entries; buffer_size=32)
    function remote_monitor(fn, entries, results)
        @sync while true
            entry = try
                take!(entries)
            catch y
                # TODO: This should be handled more gracefully: only kill the
                # worker if there is the "right" error
                println(y)
                break
            end
            t = @async fn(entry)
            @async put!(results, fetch(t))
        end
    end

    results = RemoteChannel(
            ()->Channel{fn_ret_type(processor, Entry)}(buffer_size)
        )

    for p in workers()
        remote_do(remote_monitor, p, processor, entries, results)
    end

    return results
end


function collect!(
        results::A; collect_time=1,
    ) where {
             T <: Entry,
             S <: AbstractChannel{T},
             A <: Union{S, RemoteChannel{S}}
            }

    collected = Vector{Entry}()

    t = @async while true
        fd = take!(results)
        push!(collected, fd)
    end

    sleep(collect_time)
    schedule(t, InterruptException(), error=true)

    return collected
end


#-------------------------------------------------------------------------------

end # module DistributedStreams
