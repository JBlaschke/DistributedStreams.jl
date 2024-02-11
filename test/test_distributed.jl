using Test, DistributedStreams

#_______________________________________________________________________________
# Test basic producer-consumer setup:
# * 4 workers running the monitor setup
#-------------------------------------------------------------------------------

using Distributed

addprocs(4)

@everywhere using DistributedStreams

input, output, control, status = launch_monitor(
    x->begin
        id = x.id
        data = DistributedStreams.Serialize.deserialize(x.data) + 1
        Entry(
            id=x.id,
            data=DistributedStreams.Serialize.serialize(data),
            valid=true
        )
    end;
    start_safe = false,
    verbose = true
)

N = 100000
@async for i=1:N
    put!(input, Entry(
            id=i,
            data=DistributedStreams.Serialize.serialize(10+i),
            valid=false
    ))
    if i > N - 2*length(workers())
        make_unsafe!(control)
    end
end

using ProgressMeter

p  = Progress(
    N; desc="Collected: ", showspeed=true, enabled=true
)
update!(p, 0)

global total_collected = 0
global all_out = Any[]
while true
    out = collect!(output)
    global total_collected += length(out)
    global all_out = vcat(all_out, out)
    update!(p, total_collected)

    if (total_collected >= N) && (length(out) == 0)
        break
    end
    sleep(1)
end

stop_workers!(control)

for e in all_out
    @test DistributedStreams.Serialize.deserialize(e.data) == e.id + 10 + 1
end

rmprocs(workers())
println("Everthing has been shut down -- sleeping while workers quit")
sleep(2)
println("All done")

#-------------------------------------------------------------------------------
