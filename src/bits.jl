module Bits

using StructIO

abstract type SerializedNamedTuple end

struct NodeHeader
    size::UInt64
    type::UInt8

    function NodeHeader(type::DataType, data_length)
        type_idx = findfirst(x->x[1]==type, TYPES)

        if isabstracttype(type)
            return new(data_length, type_idx)
        end

        new(packed_sizeof(type)*data_length, type_idx)
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

function to_bits(data::AbstractArray, type)
    # Header
    header = NodeHeader(type, length(data))
    header_size = packed_sizeof(NodeHeader)

    # Create bits buffer
    buffer = Vector{UInt8}(undef, header_size + header.size)
    buffer .= 0x00

    writebuf = IOBuffer(buffer; read=false, write=true)
    pack(writebuf, header)
    write(writebuf, data)

    return buffer
end

to_bits(data::AbstractArray{T}) where T = to_bits(data, T)

# TODO: Handle arrays of these types
to_bits(data::AbstractString) = to_bits(custom_convert_to(data), String)

# TODO: flag quantities as "scalar"
to_bits(data::Number) = to_bits([data])

function to_bits(data::T) where T <: NamedTuple
    # Preamble tags that N key(string), value pairs are to follow
    preamble = NodeHeader(SerializedNamedTuple, length(keys(data)))
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

custom_convert_from(::Type{String}, data::AbstractArray{UInt8}) = String(data)

function custom_convert_from(
        ::Type{SerializedNamedTuple}, data::AbstractArray{UInt8}
    )

    # preamble_bits = @view bits[1:HEADER_SIZE]
    # preamble_buf = IOBuffer(preamble_bits; read=true, write=false)
    # preamble = unpack(header_buf, NodeHeader)

    data_dict = Dict{Symbol, Any}()
    # idx += HEADER_SIZE
    idx = 1

    while true # preamble.size
        header_bits = @view bits[idx:idx + HEADER_SIZE]
        header_buf = IOBuffer(header_bits; read=true, write=false)
        header = unpack(header_buf, NodeHeader)

        type, _ = TYPES[header.type]
        @assert type == String

        key = custom_convert_from(String, @view bits[
            idx + HEADER_SIZE:idx + HEADER_SIZE + header.size
        ])

        val = from_bits(bits; complete=false)
        idx += HEADER_SIZE + header.size
        if idx >= length(data)
            break
        end
    end
end

function from_bits(bits::Vector{UInt8}; complete=true, idx=Ref(0))
    header_bits = @view bits[1:1 + HEADER_SIZE]
    header_buf = IOBuffer(header_bits; read=true, write=false)
    header = unpack(header_buf, NodeHeader)
    type, use_constructor = TYPES[header.type]

    # Some optimization around @view gives me a 25% perf boost if I use `end` in
    # a `@view` => the `complete` flag is used to indicate that the `bits`
    # array is a complete record (as opposed to a larger record or which we're)
    # processing only a chunk
    if complete || isabstracttype(type)
        data = @view bits[1 + HEADER_SIZE:end]
    else
        data = @view bits[1 + HEADER_SIZE:HEADER_SIZE + header.size]
    end

    idx[] += HEADER_SIZE + header.size

    if ! use_constructor
        return reinterpret(type, data)
    else
        return custom_convert_from(type, data)
    end
end

export from_bits

end
