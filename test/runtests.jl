using Test

import DistributedStreams


#_______________________________________________________________________________
# Test fn_ret_type
# Currently this functionality is pretty limited -- so add more tests when they
# are expanded
#-------------------------------------------------------------------------------

a(i) = Int64(1)
@test DistributedStreams.fn_ret_type(a, Any) == Int64

#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Test serialization
# These functions can pack bits-like data types into vectors of bits
#-------------------------------------------------------------------------------

val = 10
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x)[1] == val

val = 10.1
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x)[1] == val

val = Complex(10, 2)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x)[1] == val

val = Rational(1, 2)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x)[1] == val

val = "hello there"
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x) == val

#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Test basic producer-consumer setup:
# * 4 workers running the monitor setup
#-------------------------------------------------------------------------------

using Distributed

addprocs(4)

@everywhere using DistributedStreams

@everywhere function serialize(data)
    DistributedStreams.@chain data begin
        [_]
        DistributedStreams.Bits.to_bits(_)
        compress(_)
    end
end

@everywhere function deserialize(data)
    DistributedStreams.@chain data begin
        decompress(_)
        DistributedStreams.Bits.from_bits(_)
        _[1]
    end
end

input, output, control = launch_monitor(
    x->begin
        id = x.id
        data = deserialize(x.data) + 1
        Entry(id=x.id, data=serialize(data), valid=true)
    end;
    start_safe = false,
    verbose = true
)

N = 100000
@async for i=1:N
    put!(input, Entry(id=i, data=serialize(10+i), valid=false))
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
    @test deserialize(e.data) == e.id + 10 + 1
end


println("Everthing has been shut down -- sleeping while workers quit")
sleep(2)
println("All done")

#-------------------------------------------------------------------------------
