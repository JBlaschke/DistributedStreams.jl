module Bits

using StructIO

struct NodeHeader
    size::UInt64
    type::UInt8
end

TYPES = Tuple{DataType, Bool}[
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
    (String, true)
]

custom_convert_to(data::String) = Vector{UInt8}(data)
custom_convert_from(::Type{String}, data::AbstractArray{UInt8}) = String(data)

# Default to byte-size when checking the size of String
StructIO.packed_sizeof(::Type{String}) = packed_sizeof(UInt8)

function to_bits(data::AbstractArray, type)
    data_len = length(data)
    type_idx = findfirst(x->x[1]==type, TYPES)
    type_len = packed_sizeof(type)

    # Header
    header = NodeHeader(type_len*data_len, type_idx)
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

export to_bits

function from_bits(bits::Vector{UInt8})
    header_bits = @view bits[1:packed_sizeof(NodeHeader)]
    header_buf = IOBuffer(header_bits; read=true, write=false)
    header = unpack(header_buf, NodeHeader)
    type, use_constructor = TYPES[header.type]

    data = @view bits[packed_sizeof(NodeHeader)+1:end] 
    @assert length(data) == header.size
    if ! use_constructor
        return reinterpret(type, data)
    else
        return custom_convert_from(type, data)
    end
end

export from_bits

end
