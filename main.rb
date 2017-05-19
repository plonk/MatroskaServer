require 'logger'
require 'monitor'
require 'ostruct'
require 'shellwords'
require 'socket'
require 'timeout'

require_relative 'publishing_point'
require_relative 'util'

class HttpMatroskaServer
  include Util

  class BadRequest < StandardError; end
  class AlreadyPublishing < StandardError; end

  SERVER_NAME = 'MatroskaServer/0.0.1'

  def initialize(options = {})
    @host              = options[:host] || '0.0.0.0'
    @port              = options[:port] || 7000
    @log               = options[:log] || Logger.new(STDOUT)
    @listeners         = []
    @publishing_points = {}
    @options           = options

    @lock = Monitor.new
  end

  def run
    @socket = TCPServer.open(@host, @port)
    @log.info format('server is on %s', addr_format(@socket.addr))

    threads = []
    loop do
      client = @socket.accept
      p client
      @log.info "connection accepted #{addr_format(client.peeraddr)}"

      threads = threads.select(&:alive?)
      threads << Thread.start(client) do |sock|
        begin
          peeraddr = sock.peeraddr # コネクションリセットされると取れなくなるので
          @log.info "thread #{Thread.current} started"
          req = nil
          Timeout.timeout(30) do
            req = http_request(sock)
            p req
          end
          sock = nil
          handle_request(req)
          @log.info "done serving #{addr_format(peeraddr)}"
        rescue => e
          @log.error "#{e.message}"
          # fail if $DEBUG
        ensure
          p :close_sockeet
          req.socket.close if req&.socket
          sock.close if sock
          @log.info "thread #{Thread.current} exiting"
        end
      end
    end
  rescue Interrupt
    @log.info 'interrupt from terminal'
    threads.each { |t| t.kill }
    threads = []
    @log.info 'closing publishing points...'
    @publishing_points.each_pair do |_path, point|
      point.close unless point.closed?
    end
  end

  def normalize_header_name(name)
    name.split('-').map(&:capitalize).join('-')
  end

  def http_request(s)
    if (line = s.gets) =~ /\A([A-Z]+) (\S+) (\S+)\r\n\z/
      meth = $1
      path = $2
      version = $3
    else
      fail BadRequest, "invalid request line: #{line.inspect}"
    end

    # read headers
    headers = {}
    while (line = s.gets) != "\r\n"
      if line =~ /\A([^:]+):\s*(.+)\r\n\z/
        name = normalize_header_name($1)
        value = $2
        if headers[name]
          headers[name] += ", #{value}"
        else
          headers[name] = value
        end
      else
        fail BadRequest, "invalid header line: #{line.inspect}"
      end
    end
    return OpenStruct.new(meth: meth, path: path, version: version,
                          headers: headers, socket: s)
  rescue BadRequest => e
    @log.error e.message
    s.write "HTTP/1.0 400 Bad Request\r\n\r\n"
    fail "bad HTTP request"
  end

  def stats_body(request)
    "stats"
  end

  # 統計情報取得のリクエスト。
  def handle_stats(request)
    s = request.socket
    body = stats_body(request)

    s.write "HTTP/1.0 200 OK\r\n"
    s.write "Server: #{SERVER_NAME}\r\n"
    s.write "Content-Type: text/plain; charset=UTF-8\r\n"
    s.write "Content-Length: #{body.bytesize}\r\n"
    s.write "\r\n"

    s.write body
  ensure
    s.close
  end

  # 既にパブリッシングポイントが存在すれば nil を返す
  def open_publishing_point(path)
    # 先に取った人が優先なので、失敗するのがいいと思うが、前の接続が死
    # んでいるときはどうしよう？

    newpp = nil
    @lock.synchronize do
      if @publishing_points[path]
        fail AlreadyPublishing, "Publishing point already active."
      end
      @publishing_points[path] = newpp = PublishingPoint.new

      @log.info "publishing point #{path} created"
      @log.debug "publishing points: #{@publishing_points.inspect}"
    end

    yield newpp
  ensure
    if newpp
      p :close_newpp
      newpp.close
      remove_publishing_point(path)
    end
  end

  def remove_publishing_point(path)
    @log.info "removing point #{path}"
    @lock.synchronize do
      @publishing_points.delete(path)
      @log.debug "publishing points: #{@publishing_points.inspect}"
    end
  end

  def handle_post(request)
    @log.debug 'handle_post' if $DEBUG
    s = request.socket

    begin
      open_publishing_point(request.path) do |publishing_point|
        begin
          @log.info "publisher starts streaming to #{publishing_point}"
          if request.headers["Transfer-Encoding"] == "chunked"
            @log.debug("chunked stream")
            reader = Dechunker.new(s)
          else
            reader = NullReader.new(s)
          end
          publishing_point.start(reader)
        rescue => e
          @log.error e.to_s
          fail
        end
      end
    rescue EOFError => e
      # エンコーダーとの接続が切れた
      @log.info "EOFError: #{e.message}"
    rescue AlreadyPublishing => e
      @log.info "503 Service Unavailable"
      s.write("HTTP/1.0 503 Service Unavailable\r\n")
      s.write("Content-Length: #{e.message.bytesize}\r\n")
      s.write("Content-Type: text/plain\r\n")
      s.write("\r\n")
      s.write(e.message)
    end
  end

  def handle_get(request)
    publishing_point = nil
    @lock.synchronize do
      publishing_point = @publishing_points[request.path]
    end

    if publishing_point
      if publishing_point.header
        request.socket.write "HTTP/1.0 200 OK\r\n"
        request.socket.write "Content-Type: video/x-matroska\r\n"
        #request.socket.write "Server: #{SERVER_NAME}\r\n"
        request.socket.write "\r\n"
        publishing_point.add_subscriber(request.socket)
        # 以降、ソケットの扱いは読み込み側のスレッドにまかせる。
        request.socket = nil
      else
        request.socket.write "HTTP/1.0 503 Service Unavailable\r\n\r\n"
      end
    else
      request.socket.write "HTTP/1.0 404 Not Found\r\n\r\n"
    end
  end

  # リクエストを種類によって振り分ける。
  def handle_request(request)
    case request.meth
    when 'GET'
      if request.path == "/stats"
        handle_stats(request)
      else
        handle_get(request)
      end
    when 'POST'
      handle_post(request)
    else
      request.socket.write "HTTP/1.0 400 Bad Request\r\n\r\n"
    end
  end
end

Thread.abort_on_exception = true
HttpMatroskaServer.new.run
