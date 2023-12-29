using Test

import DistributedStreams


#_______________________________________________________________________________
# Backend tests: make sure that the basic infrastructure works
#-------------------------------------------------------------------------------
if isempty(ARGS) || "backend" in ARGS
    @testset "Backend" begin
        include("test_backend.jl")
    end
end
#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Test serialization
#-------------------------------------------------------------------------------
if isempty(ARGS) || "serialization" in ARGS
    @testset "Serialization" begin
        include("test_serialization.jl")
    end
end
#-------------------------------------------------------------------------------

#_______________________________________________________________________________
# Test producer-consumer workflow
#-------------------------------------------------------------------------------
if isempty(ARGS) || "distributed" in ARGS
    @testset "Distribued" begin
        include("test_distributed.jl")
    end
end
#-------------------------------------------------------------------------------
