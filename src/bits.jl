module Bits

using StructIO, Chain, CodecZlib

abstract type SerializedNamedTuple end

struct NodeHeader
    size::UInt64
    type::UInt8
    elts::Int64
    scalar::Bool

    function NodeHeader(type::DataType, data_length::Int64, scalar::Bool)
        type_idx = findfirst(x->x[1]==type, TYPES)

        if isabstracttype(type)
            return new(0, type_idx, data_length, scalar)
        end

        new(packed_sizeof(type)*data_length, type_idx, data_length, scalar)
    end
end

const TYPES = Tuple{DataType, Bool}[
    (Bool, false),
    (UInt8, false),
    (UInt16, false),
    (UInt32, false),
    (UInt64, false),
    (UInt128, false),
    (Int8, false),
    (Int16, false),
    (Int32, false),
    (Int64, false),
    (Int128, false),
    (Float16, false),
    (Float32, false),
    (Float64, false),
    (ComplexF16, false),
    (ComplexF32, false),
    (ComplexF64, false),
    (Complex{UInt8}, false),
    (Complex{UInt16}, false),
    (Complex{UInt32}, false),
    (Complex{UInt64}, false),
    (Complex{UInt128}, false),
    (Complex{Int8}, false),
    (Complex{Int16}, false),
    (Complex{Int32}, false),
    (Complex{Int64}, false),
    (Complex{Int128}, false),
    (Rational{UInt8}, false),
    (Rational{UInt16}, false),
    (Rational{UInt32}, false),
    (Rational{UInt64}, false),
    (Rational{UInt128}, false),
    (Rational{Int8}, false),
    (Rational{Int16}, false),
    (Rational{Int32}, false),
    (Rational{Int64}, false),
    (Rational{Int128}, false),
    (SerializedNamedTuple, true),
    (String, true)
]

HEADER_SIZE = packed_sizeof(NodeHeader)

custom_convert_to(data::String) = Vector{UInt8}(data)

# Default to byte-size when checking the size of String
StructIO.packed_sizeof(::Type{String}) = packed_sizeof(UInt8)

function to_bits(data::AbstractArray, type, scalar)
    # Header
    header = NodeHeader(type, length(data), scalar)
    header_size = packed_sizeof(NodeHeader)

    # Create bits buffer
    buffer = Vector{UInt8}(undef, header_size + header.size)
    buffer .= 0x00

    writebuf = IOBuffer(buffer; read=false, write=true)
    pack(writebuf, header)
    write(writebuf, data)

    return buffer
end

to_bits(data::AbstractArray{T}) where T = to_bits(data, T, false)

# TODO: Handle arrays of these types
to_bits(data::AbstractString) = to_bits(custom_convert_to(data), String, true)

to_bits(data::T) where T <: Number = to_bits([data], T, true)

function to_bits(data::T) where T <: NamedTuple
    # Preamble tags that N key(string), value pairs are to follow
    preamble = NodeHeader(SerializedNamedTuple, length(keys(data)), true)
    preamble_size = packed_sizeof(NodeHeader)

    buffer = Vector{UInt8}(undef, preamble_size)
    buffer .= 0x00

    writebuf = IOBuffer(buffer; read=false, write=true)
    pack(writebuf, preamble)

    for k in keys(data)
        keybuff = to_bits(String(k))
        valbuff = to_bits(data[k])
        write(writebuf, keybuff)
        write(writebuf, valbuff)
    end

    return buffer
end

export to_bits

function custom_convert_from(
        ::Type{String}, data::AbstractArray{UInt8}, idx::Ref{Int64}
    )
    str = String(data)
    idx[] += length(str)
    return str
end

function custom_convert_from(
        ::Type{SerializedNamedTuple}, data::AbstractArray{UInt8}, idx::Ref{Int64}
    )

    data_dict = Dict{Symbol, Any}()
    ptr = 1
    while true
        cts = Ref(0)
        key = from_bits(@view data[ptr:end]; complete=false, idx=cts)
        idx[] += cts[]
        ptr   += cts[]

        cts = Ref(0)
        val = from_bits(@view data[ptr:end]; complete=false, idx=cts)
        idx[] += cts[]
        ptr   += cts[]

        data_dict[Symbol(key)] = val

        if ptr >= length(data)
            break
        end
    end

    return NamedTuple(data_dict)
end

function from_bits(bits::AbstractArray{UInt8}; complete=true, idx=Ref(0))
    header_bits = @view bits[1:1 + HEADER_SIZE]
    header_buf = IOBuffer(header_bits; read=true, write=false)
    header = unpack(header_buf, NodeHeader)
    type, use_constructor = TYPES[header.type]

    # Some optimization around @view gives me a 25% perf boost if I use `end` in
    # a `@view` => the `complete` flag is used to indicate that the `bits`
    # array is a complete record (as opposed to a larger record or which we're)
    # processing only a chunk
    if complete || isabstracttype(type) || (header.size <= 0)
        data = @view bits[1 + HEADER_SIZE:end]
    else
        data = @view bits[1 + HEADER_SIZE:HEADER_SIZE + header.size]
    end

    idx[] += HEADER_SIZE

    if ! use_constructor
        reconstructed = reinterpret(type, data)
        idx[] += header.size
        if header.scalar
            return reconstructed[1]
        else
            return reconstructed
        end
    else
        return custom_convert_from(type, data, idx)
    end
end

export from_bits

#_______________________________________________________________________________
# Helper functions to compress and decompress data, using these functions
# ensure that a consistent compression and decompression algorithm is used
#-------------------------------------------------------------------------------

compress(data)   = transcode(ZlibCompressor,   data)
decompress(data) = transcode(ZlibDecompressor, data)

export compress, decompress

function serialize(data)
    @chain data begin
        to_bits(_)
        compress(_)
    end
end

function deserialize(data)
    @chain data begin
        decompress(_)
        from_bits(_)
    end
end

export serialize, deserialize

#-------------------------------------------------------------------------------

end
