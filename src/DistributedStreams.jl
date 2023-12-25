module DistributedStreams

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
    id::Int64                    = 0
    admin_comment::Vector{UInt8} = UInt8[]
    valid::Bool                  = false
end

#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Helper function to infer return types of a function
# TODO: maybe this should work with varags? Right now the design assumes a
# single input and a single output type argument.
#-------------------------------------------------------------------------------

fn_ret_type(fn, in_type::DataType) = Base.return_types(fn, (in_type,))[1]

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
