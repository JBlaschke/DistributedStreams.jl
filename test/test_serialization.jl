using Test, DistributedStreams

#_______________________________________________________________________________
# Test serialization
# These functions can pack bits-like data types into vectors of bits
#-------------------------------------------------------------------------------

val = 10
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx)[1] == val
@test idx[] == length(x)

val = 10.1
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx)[1] == val
@test idx[] == length(x)

val = Complex(10, 2)
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx)[1] == val
@test idx[] == length(x)

val = Rational(1, 2)
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx)[1] == val
@test idx[] == length(x)

val = "hello there"
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx) == val
@test idx[] == length(x)

# Test very large random inputs -- to check eg. for off-by-one errors in at the
# end of the NodeHeader struct

using Random

val = randstring(1_000_000_000)
idx = Ref(0)
x = DistributedStreams.Bits.to_bits(val)
@test DistributedStreams.Bits.from_bits(x; idx=idx) == val
@test idx[] == length(x)
#-------------------------------------------------------------------------------
