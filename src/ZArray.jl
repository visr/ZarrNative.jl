module ZArrays
import JSON
import ..Compressors
import ..Storage: ZStorage, getattrs, DiskStorage, zname, getchunk, MemStorage
import ..Compressors: Compressor, read_uncompress!, compressortypes, getCompressor,
  write_compress, NoCompressor, areltype
export ZArray, zzeros

# Some function to parse metadata and translate between julia and zarr datatypes
ztype2jltype = Dict(
  "<f4"=>Float32,
  "<f8"=>Float64,
  "<i4"=>Int32,
  "<i8"=>Int64
)

#String handling is quite complicated see this https://zarr.readthedocs.io/en/stable/tutorial.html#string-arrays
#for different options that would have to be suported
#This is an initial take on fixed-length UTF8 Strings
struct FixedLengthUTF8String{L} end
jltype(a::Type{T}) where T<:Number = T
jltype(a::Type{FixedLengthUTF8String}) = String

#Translates JSON entry to a julia data type
function tostore(t)
  if startswith(t,"<U")
    return FixedLengthUTF8String{parse(Int,t[3:end])}
  else
    ztype2jltype[t]
  end
end

zshape2shape(x) = ntuple(i->x[i],length(x))

struct C end
struct F end
const StorageOrder = Union{C,F}

zorder2order(x) = x=="C" ? C : x=="F" ? F : error("Unknown storage order")


getfillval(target::Type{T},t::String) where T<: Number =parse(T,t)
getfillval(target::Type{T},t::Union{T,Nothing}) where T = t

#Struct representing a Zarr Array in Julia, note that
#chunks(chunk size) and size are always in Julia column-major order
#Currently this is not an AbstractArray, because indexing single elements is
#would be really slow, although most AbstractArray interface functions are implemented
struct ZArray{T,N,C<:Compressor,S<:ZStorage,T2}
    folder::S
    size::NTuple{N,Int} # Stored in Julia order
    order::StorageOrder
    chunks::NTuple{N,Int} # Stored in Julia order
    fillval::Union{T,Nothing}
    compressor::C
    attrs::Dict
    writeable::Bool
end
Base.eltype(::ZArray{T}) where T =  T
Base.ndims(::ZArray{<:Any,N}) where N = N
Base.size(z::ZArray)=z.size
Base.size(z::ZArray,i)=z.size[i]
Base.length(z::ZArray)=prod(z.size)
Base.lastindex(z::ZArray,n)=size(z,n)
function Base.show(io::IO,z::ZArray)
  print(io,"ZArray{", eltype(z) ,"} of size ",join(string.(size(z))," x "))
end
zname(z::ZArray)=zname(z.folder)

#Construction of a ZArray given a folder on a regular drive
#A lot of the JSON parsing should be moved to a function, since
#this will be the same for other backends
function ZArray(folder::String,mode="r")
    files = readdir(folder)
    @assert in(".zarray",files)
    arrayinfo = JSON.parsefile(joinpath(folder,".zarray"))
    dt = tostore(arrayinfo["dtype"])
    shape = zshape2shape(arrayinfo["shape"])
    order = zorder2order(arrayinfo["order"])
    arrayinfo["zarr_format"] != 2 && error("Expecting Zarr format version 2")
    chunks = zshape2shape(arrayinfo["chunks"])
    fillval = getfillval(dt,arrayinfo["fill_value"])
    compdict = arrayinfo["compressor"]
    compressor = getCompressor(compressortypes[compdict["id"]],compdict)
    attrs = getattrs(DiskStorage(folder))
    writeable= mode=="w"
    ZArray{jltype(dt),length(shape),typeof(compressor),DiskStorage,dt}(DiskStorage(folder),reverse(shape),order(),reverse(chunks),fillval,compressor,attrs,writeable)
end

"""
    convert_index(i,s)

Basic function to translate indices given by the user
to unit ranges.
"""
convert_index(i::Integer,s::Int)=i:i
convert_index(i::AbstractUnitRange,s::Int)=i
convert_index(::Colon,s::Int)=Base.OneTo(s)

#Helper function for reshaping the result in the end
convert_index2(::Colon,s)=Base.OneTo(s)
convert_index2(i,s)=i

"""
    trans_ind(r, bs)

For a given index and blocksize determines which chunks of the Zarray will have to
be accessed.
"""
trans_ind(r::AbstractUnitRange,bs) = ((first(r)-1)÷bs):((last(r)-1)÷bs)
trans_ind(r::Integer,bs)   = (r-1)÷bs

"""
Most important helper function. Returns two tuples of ranges.
  For a given chunks bI it determines the indices
  to read inside the chunk `i1:i2` as well as the indices to write to in the return
  array `io1:io2`.
"""
function inds_in_block(r::CartesianIndices{N}, #Outer Array indices to read
        bI::CartesianIndex{N}, #Index of the current block to read
        blockAll::CartesianIndices{N}, # All blocks to read
        c::NTuple{N,Int}, # Chunks
        enumI::CartesianIndices{N}, # Idices of all block to read
        offsfirst::NTuple{N,Int} # Offset of the first block to read
        ) where N
    sI=size(enumI)
    map(r.indices,bI.I,blockAll.indices,c,enumI.indices,sI,offsfirst) do iouter, iblock, ablock, chunk, enu , senu, o0
        if iblock==first(ablock)
            i1=mod1(first(iouter),chunk)
            io1=1
        else
            i1=1
            io1=(iblock-first(ablock))*chunk+o0
        end
        if iblock==last(ablock)
            i2=mod1(last(iouter),chunk)
            io2=length(iouter)
        else
            i2=chunk
            io2=(iblock-first(ablock)+1)*chunk+o0-1
        end
        i1:i2,io1:io2
    end
end

#Function to read or write from a zarr array. Could be refactored
#using type system to get rid of the `if readmode` statements.
#
function readblock!(aout,z::ZArray{<:Any,N},r::CartesianIndices{N};readmode=true) where N
    if !readmode && !z.writeable
      error("Trying to write to read-only ZArray")
    end
    #Determines which chunks are affected
    blockr = CartesianIndices(map(trans_ind,r.indices,z.chunks))
    enumI = CartesianIndices(blockr)
    #Get the offset of the first index in each dimension
    offsfirst = map((a,bs)->mod(first(a)-1,bs)+1,r.indices,z.chunks)
    #Allocate array of the size of a chunks where uncompressed data can be held
    a = zeros(eltype(z),z.chunks)
    #Get linear indices from user array. This is a workaround to make something
    #like z[:] = 1:10 work, because a unit range can not be accessed through
    #CartesianIndices
    if !readmode
      linoutinds = LinearIndices(r)
    end
    #Now loop through the chunks
    for bI in blockr
      #Uncompress a chunk
      readchunk!(a,z,bI+one(bI))
      #Get indices to extract and to write to for the current chunk
      ii = inds_in_block(r,bI,blockr,z.chunks,enumI,offsfirst)
      #Extract them as CartesianIndices objects
      i_in_a = CartesianIndices(map(i->i[1],ii))
      i_in_out = CartesianIndices(map(i->i[2],ii))

      if readmode
        #Read data
        aout[i_in_out.indices...].=view(a,i_in_a)
      else
        #Write data, here one could dispatch on the IndexStyle
        #Of the user-provided array, and then decide on an
        #Indexing style
        a[i_in_a].=extractreadinds(aout,linoutinds,i_in_out)
        writechunk!(a,z,bI+one(bI))
      end
    end
    aout
end

#Some helper functions to determine the shape of the output array
gets(x::Tuple)=gets(x...)
gets(x::AbstractRange,r...)=(length(x),gets(r...)...)
gets(x::Integer,r...)=gets(r...)
gets()=()

#Short wrapper around readblock! to have getindex-style behavior
function Base.getindex(z::ZArray{T},i::Int...) where T
  ii=CartesianIndices(map(convert_index,i,size(z)))
  aout=zeros(T,size(ii))
  readblock!(aout,z,ii)
  aout[1]
end
function Base.getindex(z::ZArray{T},i...) where T
  ii=CartesianIndices(map(convert_index,i,size(z)))
  aout=zeros(T,size(ii))
  readblock!(aout,z,ii)
  ii2=map(convert_index2,i,size(z))
  reshape(aout,gets(ii2))
end
function Base.getindex(z::ZArray{T,1},::Colon) where T
  ii=CartesianIndices(size(z))
  aout=zeros(T,size(ii))
  readblock!(aout,z,ii)
  reshape(aout,length(aout))
end

function Base.setindex!(z::ZArray,v,i...)
  ii=CartesianIndices(map(convert_index,i,size(z)))
  readblock!(v,z,ii,readmode=false)
end
function Base.setindex!(z::ZArray,v,::Colon)
  ii=CartesianIndices(size(z))
  readblock!(v,z,ii,readmode=false)
end

"""
    readchunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N})

Read the chunk specified by `i` from the Zarray `z` and write its content to
`a`
"""
function readchunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N}) where {T,N}
    length(a)==prod(z.chunks) || throw(DimensionMismatch("Array size does not equal chunk size"))
    curchunk=getchunk(z.folder,i)
    if curchunk==nothing
      fill!(a,z.fillval)
    else
      read_uncompress!(a,curchunk,z.compressor)
    end
    a
end

"""
    writechunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N}) where {T,N}

Write the data from the array `a` to the chunk `i` in the ZArray `z`
"""
function writechunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N}) where {T,N}
  z.writeable || error("ZArray not in write mode")
  length(a)==prod(z.chunks) || throw(DimensionMismatch("Array size does not equal chunk size"))
  curchunk=getchunk(z.folder,i)
  write_compress(a,curchunk,z.compressor)
  a
end

function extractreadinds(a,linoutinds,i_in_out)
  i_in_out2 = linoutinds[i_in_out]
  a[i_in_out2]
end
extractreadinds(a::Number,linoutinds,i_in_out)=a

function zzeros(::Type{T},
        dims...;
        path="",
        name="",
        chunks=dims,
        fillval=nothing,
        compressor=Compressors.BloscCompressor(),
        attrs=Dict(),
        writeable=true,
        ) where T
    length(dims) == length(chunks) || throw(DimensionMismatch("Dims must have the same length as chunks"))
    N=length(dims)
    nsubs = map((s,c)->ceil(Int,s/c),dims,chunks)
    et    = areltype(compressor,T)
    if isempty(path)
        isempty(name) && (name="data")
        a=Array{et}(undef,nsubs...)
        for i in eachindex(a)
            a[i]=T[]
        end
        folder=MemStorage(name,a)
    else
      # Assume that we write to disk, no S3 yet
      if isempty(name)
        name = splitdir(path)[2]
      else
        path = joinpath(path,name)
      end
      isdir(path) && error("Directory $path already exists")
      mkpath(path)
      #Generate JSON file
      jsondict = Dict()
      jsondict["chunks"] = reverse(chunks)
      jsondict["compressor"] = Compressors.tojson(compressor)
      jsondict["dtype"] = findfirst(isequal(T),ztype2jltype)
      jsondict["fill_value"] = fillval
      jsondict["filters"] = nothing
      jsondict["order"] = "C"
      jsondict["shape"] = reverse(dims)
      jsondict["zarr_format"] = 2
      open(joinpath(path,".zarray"),"w") do f
        JSON.print(f,jsondict)
      end
      open(joinpath(path,".zattrs"),"w") do f
        JSON.print(f,attrs)
      end
      folder = DiskStorage(path)
    end
    z=ZArray{jltype(T),N,typeof(compressor),typeof(folder),T}(folder,dims,F(),chunks,fillval,compressor,attrs,writeable)
    as = zeros(T,chunks...)
    for i in CartesianIndices(map(i->1:i,nsubs))
        writechunk!(as,z,i)
    end
    z
end
#ZArray{jltype(dt),length(shape),typeof(compressor),DiskStorage,dt}(DiskStorage(folder),reverse(shape),order(),reverse(chunks),fillval,compressor,attrs,writeable)


end
