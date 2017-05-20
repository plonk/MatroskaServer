# chunked transfer encoding のデコード
class Dechunker
  def initialize(sock)
    @sock = sock
    @buffer = ""
    @buffer.force_encoding("ASCII-8BIT")
  end

  def read(n)
    if n <= @buffer.bytesize
      res, @buffer = @buffer[0,n], @buffer[n..-1]
      return res
    else
      # read next chunk
      line = @sock.gets
      if line.nil?
        fail Errno::EPIPE, "failed to read chunk header"
      end
      line.chomp!
      unless line =~ /\A[0-9A-Fa-f]+;?.*\z/
        fail "invalid(?) chunk header #{line.inspect}"
      end
      nbytes = line.to_i(16)
      if nbytes == 0
        until @sock.gets == "\r\n" # read trailer
        end
        fail Errno::EPIPE, "end of stream"
      end
      @buffer.concat(@sock.read(nbytes))
      crlf = @sock.read(2)
      if crlf != "\r\n"
        fail "protocol error"
      end
      return read(n)
    end
  end
end

class NullReader
  def initialize(sock)
    @sock = sock
  end

  def read(n)
    return @sock.read(n)
  end
end
