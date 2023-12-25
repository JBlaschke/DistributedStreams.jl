using Test

import DistributedStreams

println("Testing import:")
@test_nowarn DistributedStreams.greet()
