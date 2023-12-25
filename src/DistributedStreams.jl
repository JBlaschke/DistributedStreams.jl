module DistributedStreams

greet() = print("Hello World!")

using Base: @kwdef

using Distributed
using CodecZlib
using Chain
using JSON
using Dates

end # module DistributedStreams
