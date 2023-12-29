using Test, DistributedStreams

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
