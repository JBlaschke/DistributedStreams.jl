using Distributed

addprocs(2)
println(workers())

@everywhere using Distributed

@everywhere function remote_worker(fn, entries, results)
    while true
        # take data from remote channel asynchronously
        t = @async take!(entries)
        # process data and return result in output channel -- and sync loop
        @sync put!(results, fn(fetch(t)))
    end
end

ch_in = RemoteChannel(()->Channel{Int64}(32), 1)
ch_out = RemoteChannel(()->Channel{Int64}(32), 1)

@async while true
    t = take!(ch_out)
    println("Taken: $(t)")
end

@everywhere function test_fn(i)
    println("hi there, I'm running on pid=$(myid())")
    sleep(.1)
    return i+1
end

remotecall(remote_worker, 2, test_fn, ch_in, ch_out)
remotecall(remote_worker, 3, test_fn, ch_in, ch_out)
# Wait for all workers to have started properly``
sleep(1) 

put!(ch_in, 1)
put!(ch_in, 2)
put!(ch_in, 3)
put!(ch_in, 4)
# Wait for all workers to be done
sleep(1)

rmprocs(3)
println(workers())

for i in 1:10
  put!(ch_in, 5)
  put!(ch_in, 6)
  put!(ch_in, 7)
  put!(ch_in, 8)
end

# Wait for all workers to be done
sleep(1)

