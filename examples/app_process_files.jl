using Distribued, DistributedStreams


# Sentinel service
@enum MessageType begin
    start
    stop
end

struct ControlMessage
    type::MessageType
    func::Function
    target::Int64
    channel_in::RemoteChannel
    channel_out::RemoteChannel
end

function launch_sentinel(;workers=[2], verbose=false, buffer_size=32, timeout=1)

    distributed_control = DArray([
        @spawnat p [(worker = p, flag = Ref(false))]
        for p in workers
    ])

    worker_distribution = Dict{Int64}{Function}()

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
            message = fetch(t)
            if message.type == start
            elseif message.type == stop
            end
            # process data and return result in output channel -- and sync loop
            @sync put!(results, fetch(t))
        end
    end

    control_messages  = RemoteChannel(()->Channel{ControlMessage}(buffer_size))
    control_responses = RemoteChannel(()->Channel{ControlMessage}(buffer_size))

    for p in workers
        remote_do(
            remote_worker, p,
            processor, control_messages, control_responses, distributed_control
        )
    end

    return control_messages, control_responses, distributed_control
end


# Start sentinel service

input, output, control = launch_monitor(
    x->begin
        id = x.id
        data = deserialize(x.data)
        Entry(id=x.id, data=serialize(data), valid=true)
    end;
    start_safe = false,
    verbose = true
)
