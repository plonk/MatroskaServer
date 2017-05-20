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
      line = @sock.gets.chomp
      nbytes = line.to_i(16)
      @buffer.concat(@sock.read(nbytes))
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
