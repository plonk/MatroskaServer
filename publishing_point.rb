require_relative 'matroska'
require_relative 'monitor_helper'
require_relative 'util'

# パブリッシングポイント
class PublishingPoint
  include MonitorHelper
  include Matroska

  def initialize
    @header = nil
    @subscribers = []
    @lock = Monitor.new
    @closed = false
  end

  def inspect
    if @subscribers.empty?
      subs = "none"
    else
      subs = @subscribers.map { |conn|
        # peeraddr could fail
        Util.addr_format(conn.socket.peeraddr) rescue "unknown"
      }.join(', ')
    end

    "subscribers: " + subs
  end

  def closed?
    @closed
  end

  def ready?
    @header != nil
  end
  make_safe :ready?

  def header
    @header
  end
  make_safe :header

  def add_subscriber(subscriber)
    fail 'not ready' unless ready?
    fail 'already closed' if closed?
    subscriber.write @header
    @subscribers << subscriber
  end
  make_safe :add_subscriber

  def <<(packet)
    broadcast_packet(packet)
    self
  end
  make_safe(:<<)

  def close
    # close all subscriber connections
    @subscribers.each do |subscriber|
      begin
        subscriber.close
      rescue => e
        puts "an error occured while closing #{subscriber}: #{e.message}"
      end
    end
    @closed = true
  end
  make_safe :close

  def read_id_size(sock)
    id = VInt.read(sock)
    size = VInt.read(sock)
    return id, size
  end

  def start(sock)
    fail "sock is nil" if sock.nil?

    id           = nil
    size         = nil
    skip_id_size = nil

    # ヘッダーを読み込む.
    Timeout.timeout(20) do
      header = ""
      while true
        id, size = read_id_size(sock)
        p [id.name, size.unsigned]
        header += id.bytes.pack("c*")
        header += size.bytes.pack("c*")
        if id.name != "Segment"
          header += sock.read(size.unsigned)
        else
          break
        end
      end

      while true
        id, size = read_id_size(sock)
        p [id.name, size.unsigned]
        if id.name != "Cluster"
          header += id.bytes.pack("c*")
          header += size.bytes.pack("c*")
          header += sock.read(size.unsigned)
        else
          @header = header
          skip_id_size = true
          break
        end
      end
    end

    while true
      Timeout.timeout(20) do
        if skip_id_size
          skip_id_size = false
        else
          id, size = read_id_size(sock)
        end
        if id.name != "Cluster"
          STDERR.puts "Cluster expected but got #{id.name}"
        end
        payload = sock.read(size.unsigned)
        data = id.bytes.pack("c*") +
               size.bytes.pack("c*") +
               payload
        self << data
      end
    end
  ensure
    p :exit_start
  end

  private

  def broadcast_packet(packet)
    @subscribers.each do |s|
      begin
        # TODO: ノンブロッキングでやる。
        s.write(packet)
      rescue => e
        puts "subscriber disconnected #{s}: #{e}"
        @subscribers.delete(s)
      end
    end
  end
end
