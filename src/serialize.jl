module Serialize

using Chain, CodecZlib, Serialization

#_______________________________________________________________________________
# Helper functions to compress and decompress data, using these functions
# ensure that a consistent compression and decompression algorithm is used
#-------------------------------------------------------------------------------

compress(data)   = transcode(ZlibCompressor,   data)
decompress(data) = transcode(ZlibDecompressor, data)

export compress, decompress

function serialize(data)
    ar_buf = Vector{UInt8}()
    io_buf = IOBuffer(ar_buf; read=false, write=true)
    Serialization.serialize(io_buf, data)
    compress(ar_buf)
end

function deserialize(data)
    @chain data begin
        decompress(_)
        IOBuffer(_; read=true, write=false)
        Serialization.deserialize(_)
    end
end

export serialize, deserialize

#-------------------------------------------------------------------------------


end