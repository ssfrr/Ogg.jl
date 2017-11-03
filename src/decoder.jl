"""
    OggDecoder(io::IO, ownstream=false)
    OggDecoder(fname::AbstractString)
    OggDecoder(fn::Function, io)

Decodes an Ogg file given by a stream or filename. If opened with a stream, the
`ownstream` argument determines whether the decoder will handle closing the
underlying stream when it is closed. You can also use `do` syntax (with either
a stream or a filename) to to run a block of code, and the decoder will handle
closing itself afterwards.
"""
mutable struct OggDecoder{T<:IO}
    io::T
    ownstream::Bool
    sync_state::OggSyncState
    streams::Dict{Clong,OggStreamState}
end

function OggDecoder(io::IO, ownstream=false)
    syncref = Ref{OggSyncState}(OggSyncState())
    status = ccall((:ogg_sync_init, libogg), Cint, (Ref{OggSyncState},), syncref)
    if status != 0
        error("ogg_sync_init() failed: This should never happen")
    end
    dec = OggDecoder(io, ownstream, syncref[], Dict{Clong,OggStreamState}())

    # This seems to be causing problems.  :(
    # finalizer(dec, x -> begin
    #     for serial in keys(x.streams)
    #         ogg_stream_destroy(x.streams[serial])
    #     end
    #     ogg_sync_destroy(x.sync_state)
    # end )

    return dec
end

OggDecoder(fname::AbstractString) = OggDecoder(open(fname), true)

# handle do syntax. this works whether io is a stream or file
function OggDecoder(f::Function, io)
    dec = OggDecoder(io)
    try
        f(dec)
    finally
        close(dec)
    end
end

function Base.close(dec::OggDecoder)
    if dec.ownstream
        close(dec.io)
    end
    nothing
end

"""
    eachpage(dec::OggDecoder)

Returns an iterator you can use to get the pages from an ogg stream. Note that
the page will point to data within the decoder buffer, and is only valid until
the next page is provided. Often the page will be inserted into a `PageSink`
within the iterator loop, which will handle copying the data to its own buffer

## Examples

```julia
dec = OggDecoder("someotherfile.ogg")
streams = Dict{Int, PageSink}()

# we'll use the page in the loop so we don't need to copy the data
for page in eachpage(dec)
    if bos(page)
        # PacketDecoder is a stand-in for something that expects packets
        streams[serial(page)] = PageSink(PacketDecoder())
    end
    sink = streams[serial(page)]
    write(sink, page)
end
```
"""
eachpage(dec::OggDecoder) = OggPageIterator(dec)

struct OggPageIterator
    dec::OggDecoder
end

# we want to keep one page ahead of the iterator, so that we know ahead of time
# if we're done
Base.start(iter::OggPageIterator) = readpage(iter.dec)
Base.next(iter::OggPageIterator, next) = return get(next), readpage(iter.dec)
Base.done(iter::OggPageIterator, next) = isnull(next)

# we'll try to read from the underlying stream in chunks this size
const READ_CHUNK_SIZE = 4096

"""
    readpage(dec::OggDecoder)::Nullable{OggPage}

Read the next page from the ogg decoder. Returns the nullable-wrapped page,
which is null if there are no more pages. This function will block the task if
it needs to wait to read from the underlying IO stream.
"""
function readpage(dec::OggDecoder)
    # first check to see if there's already a page ready
    page = ogg_sync_pageout(dec)
    if !isnull(page)
        return page
    end
    # no pages ready, so read more data until we get one
    while !eof(dec.io)
        buffer = ogg_sync_buffer(dec, READ_CHUNK_SIZE)
        bytes_read = readbytes!(dec.io, buffer, READ_CHUNK_SIZE)
        ogg_sync_wrote(dec, bytes_read)
        page = ogg_sync_pageout(dec)
        if !isnull(page)
            return page
        end
    end
    # we hit EOF without reading a page
    return Nullable{OggPage}()
end

"""
    PageSink(packetsink)

Decodes pages into packets (each a `Vector{UInt8}`) and writes the packets to
the wrapped sink. Generally when decoding an Ogg file you'll have an instance
of this type for each logical stream multiplexed into the file.
"""
struct PageSink{T}
    packetsink::T
    streamstate::Ref{OggStreamState}
end

function PageSink(packetsink)
    streamref = Ref(OggStreamState())
    status = ccall((:ogg_stream_init,libogg), Cint,
                   (Ref{OggStreamState}, Cint), streamref, serial)
    if status != 0
        error("ogg_stream_init() failed with status $status")
    end
    PageSink(packetsink, streamref)
end

function Base.write(sink::PageSink, page::OggPage)
    ogg_stream_pagein(sink.streamstate, page)
end

# function show(io::IO, x::OggDecoder)
#     num_streams = length(x.streams)
#     if num_streams != 1
#         write(io, "OggDecoder with $num_streams streams")
#     else
#         write(io, "OggDecoder with 1 stream")
#     end
# end

"""
    ogg_sync_buffer(dec::OggDecoder, size)

Provide a buffer for writing new raw data into.

Buffer space which has already been returned is cleared, and the buffer is
extended as necessary by the size plus some additional bytes. Within the current
implementation, an extra 4096 bytes are allocated, but applications should not
rely on this additional buffer space.

The buffer exposed by this function is empty internal storage from the
`ogg_sync_state` struct, beginning at the fill mark within the struct.

After copying data into this buffer you should call `ogg_sync_wrote` to tell the
`ogg_sync_state` struct how many bytes were actually written, and update the
fill mark.

Returns an `Array` wrapping the provided buffer

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_buffer.html)
"""
function ogg_sync_buffer(dec::OggDecoder, size)
    syncref = Ref{OggSyncState}(dec.sync_state)
    buffer = ccall((:ogg_sync_buffer,libogg), Ptr{UInt8}, (Ref{OggSyncState}, Clong), syncref, size)
    dec.sync_state = syncref[]
    if buffer == C_NULL
        error("ogg_sync_buffer() failed: returned buffer NULL")
    end
    return unsafe_wrap(Array, buffer, size)
end

"""
    ogg_sync_wrote(dec::OggDecoder, size)

Tell the ogg_sync_state struct how many bytes we wrote into the buffer.

The general proceedure is to request a pointer into an internal ogg_sync_state
buffer by calling ogg_sync_buffer(). The buffer is then filled up to the
requested size with new input, and ogg_sync_wrote() is called to advance the
fill pointer by however much data was actually available.
"""
function ogg_sync_wrote(dec::OggDecoder, size)
    syncref = Ref{OggSyncState}(dec.sync_state)
    status = ccall((:ogg_sync_wrote,libogg), Cint, (Ref{OggSyncState}, Clong), syncref, size)
    dec.sync_state = syncref[]
    if status != 0
        error("ogg_sync_wrote() failed: error code $status")
    end
    nothing
end

"""
    ogg_sync_pageout(dec::OggDecoder)::Nullable{OggPage}

Takes the data stored in the buffer of the decoder and inserts them into an
ogg_page. Note that the payload data in the page is not copied, so the memory
the OggPage points to is still contained within the ogg_sync_state struct.

Caution:This function should be called before reading into the buffer to ensure
that data does not remain in the ogg_sync_state struct. Failing to do so may
result in a memory leak. See the example code below for details.

Returns a new OggPage if it was available, or null if not, wrapped in a
`Nullable{OggPage}`.

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_pageout.html)
"""
function ogg_sync_pageout(dec::OggDecoder)
    syncref = Ref(dec.sync_state)
    pageref = Ref(OggPage())
    status = ccall((:ogg_sync_pageout,libogg), Cint, (Ref{OggSyncState}, Ref{OggPage}), syncref, pageref)
    dec.sync_state = syncref[]
    if status == 1
        return Nullable{OggPage}(pageref[])
    else
        return Nullable{OggPage}()
    end
end

"""
    ogg_page_serialno(page::OggPage)

Returns the serial number of the given page
"""
function serial(page::OggPage)
    pageref = Ref{OggPage}(page)
    return Clong(ccall((:ogg_page_serialno,libogg), Cint, (Ref{OggPage},), pageref))
end

"""
    ogg_page_eos(page::OggPage)

Indicates whether the given page is an end-of-stream
"""
function eos(page::OggPage)
    pageref = Ref{OggPage}(page)
    return ccall((:ogg_page_eos,libogg), Cint, (Ref{OggPage},), pageref) != 0
end

"""
    ogg_page_bos(page::OggPage)

Indicates whether the given page is an end-of-stream
"""
function bos(page::OggPage)
    pageref = Ref{OggPage}(page)
    return ccall((:ogg_page_eos,libogg), Cint, (Ref{OggPage},), pageref) != 0
end


"""
Send a page in, return the serial number of the stream that we just decoded.

This copies the data that the OggPage points to (contained within the
`ogg_sync_state` struct) into the `ogg_stream_state` struct.
"""
function ogg_stream_pagein(streamref::Ref{OggStreamState}, page::OggPage)
    pageref = Ref(page)
    status = ccall((:ogg_stream_pagein,libogg), Cint,
                   (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
    if status != 0
        error("ogg_stream_pagein() failed with status $status")
    end
    nothing
end

# note that this doesn't actually copy the data into the packet, it just makes
# the packet point to the data within the stream
function ogg_stream_packetout(streamref::Ref{OggStreamState}, retry=false)
    packetref = Ref{OggPacket}(OggPacket())
    status = ccall((:ogg_stream_packetout,libogg), Cint,
                   (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
    if status == 1
        return packetref[]
    else
        # Is our status -1?  That means we're desynchronized and should try again, at least once
        if status == -1 && !retry
            return ogg_stream_packetout(dec, serial; retry = true)
        end
        return nothing
    end
end

function decode_all_pages(dec::OggDecoder, enc_io::IO; chunk_size::Integer = 4096)
    # Load data in until we have a page to sync out
    while !eof(enc_io)
        page = ogg_sync_pageout(dec)
        while page != nothing
            ogg_stream_pagein(dec, page)
            page = ogg_sync_pageout(dec)
        end

        # Load in up to `chunk_size` of data, unless the stream closes before that
        buffer = ogg_sync_buffer(dec, chunk_size)
        bytes_read = readbytes!(enc_io, buffer, chunk_size)
        ogg_sync_wrote(dec, bytes_read)
    end

    # Do our last pageouts to get the last pages
    page = ogg_sync_pageout(dec)
    while page != nothing
        ogg_stream_pagein(dec, page)
        page = ogg_sync_pageout(dec)
    end
end

"""
File goes in, packets come out
"""
function decode_all_packets(dec::OggDecoder, enc_io::IO)
    # Now, decode all packets for these pages
    for serial in keys(dec.streams)
        packet = ogg_stream_packetout(dec, serial)
        while packet != nothing
            # This packet will soon go away, and we're unsafe_wrap'ing its data
            # into an arry, so we make an explicit copy of that wrapped array,
            # then push that into `dec.packets[]`
            packet_data = copy(unsafe_wrap(Array, packet.packet, packet.bytes))
            push!(dec.packets[serial], packet_data)

            # If this was the last packet in this stream, delete the stream from
            # the list of streams.  `ogg_stream_packetout()` should return `nothing`
            # after this.  Note that if a stream just doesn't have more information
            # available, it's possible for `ogg_stream_packetout()` to return `nothing`
            # even without `packet.e_o_s == 1` being true.  In that case, we can come
            # back through `decode_all_packets()` a second time to get more packets
            # from the streams that have not ended.
            if packet.e_o_s == 1
                delete!(dec.streams, serial)
            end

            packet = ogg_stream_packetout(dec, serial)
        end
    end
end

function load(fio::IO; chunk_size=4096)
    dec = OggDecoder()
    decode_all_pages(dec, fio; chunk_size=chunk_size)
    decode_all_packets(dec, fio)
    return dec.packets
end

function load(file_path::Union{File{format"OGG"},AbstractString}; chunk_size=4096)
    open(file_path) do fio
        return load(fio)
    end
end
