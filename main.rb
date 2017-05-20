require 'logger'
require 'monitor'
require 'ostruct'
require 'shellwords'
require 'socket'
require 'stringio'
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
    begin
      loop do
        client = @socket.accept
        p client
        @log.info "connection accepted #{addr_format(client.peeraddr)}" # FIXME: 例外上がる可能性アリ

        # 終了したワーカースレッドを threads から削除する
        threads = threads.select(&:alive?)

        threads << Thread.start(client) do |sock|
          begin
            peeraddr = sock.peeraddr # コネクションリセットされると取れなくなるので
            @log.info "thread #{Thread.current} started"
            req = Timeout.timeout(30) do
              read_http_request(sock)
            end
            sock = nil
            handle_request(req)
            @log.info "done serving #{addr_format(peeraddr)}"
          rescue => e
            @log.error "#{e.class}"
            @log.error "#{e.message}"
            if $DEBUG
              e.backtrace.each do |line|
                @log.error "#{line}"
              end
            end
          ensure
            @log.debug("closing socket")
            req.socket.close if req && req.socket
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
        point.close
      end
    end
  end

  # String → String
  # "content-type" → "Content-Type" etc.
  def normalize_header_name(name)
    name.split('-').map(&:capitalize).join('-')
  end

  # IO → OpenStruct(meth:String, path:String, query:String, version:String, headers:Hash, socket:IO)
  def read_http_request(s)
    if (line = s.gets) =~ /\A([A-Z]+) (\S+) (\S+)\r\n\z/
      meth = $1
      path, query = $2.split('?', 2)
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
    return OpenStruct.new(meth: meth, path: path, query: query, version: version,
                          headers: headers, socket: s)
  rescue BadRequest => e
    @log.error e.message
    s.write "HTTP/1.0 400 Bad Request\r\n\r\n"
    fail "bad HTTP request"
  end

  def stats_body(request)
    buf = ""
    s = StringIO.new(buf)
    @lock.synchronize do
      s.write "#{@publishing_points.size} publishing points:\n"
      @publishing_points.each do |path, pp|
        s.write "%-10s %p\n" % [path, pp]
      end
      s.write "\n"
    end
    return buf
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

  # 与えられたパスでパブリッシングポイントを作成し、与えられたブロック
  # に渡す。ブロックが終了するとパブリッシングポイントは削除される。
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

  # パブリッシングポイントを削除する。
  def remove_publishing_point(path)
    @log.info "removing point #{path}"
    @lock.synchronize do
      unless @publishing_points[path]
        @log.error("publishing point #{path} does not exist!")
      end
      @publishing_points.delete(path)
      @log.debug "publishing points: #{@publishing_points.inspect}"
    end
  end

  # エンコーダーによる POST リクエストを処理する。
  def handle_post(req)
    @log.debug 'handle_post' if $DEBUG

    open_publishing_point(req.path) do |publishing_point|
      @log.info "publisher starts streaming to #{publishing_point}"
      if req.headers["Transfer-Encoding"] == "chunked"
        @log.debug("chunked stream")
        reader = Dechunker.new(req.socket)
      else
        reader = NullReader.new(req.socket)
      end
      publishing_point.start(reader)
    end
  rescue EOFError => e
    # エンコーダーとの接続が切れた
    @log.info "EOFError: #{e.message}"
  rescue AlreadyPublishing => e
    @log.info "503 Service Unavailable"
    req.socket.write("HTTP/1.0 503 Service Unavailable\r\n")
    req.socket.write("Content-Length: #{e.message.bytesize}\r\n")
    req.socket.write("Content-Type: text/plain\r\n")
    req.socket.write("\r\n")
    req.socket.write(e.message)
  end

  # プレーヤーによる視聴要求を処理する。
  def handle_get(req)
    publishing_point = @lock.synchronize do
      @publishing_points[req.path]
    end

    if publishing_point
      if publishing_point.ready?
        req.socket.write "HTTP/1.0 200 OK\r\n"
        req.socket.write "Content-Type: video/x-matroska\r\n"
        req.socket.write "Server: #{SERVER_NAME}\r\n"
        req.socket.write "\r\n"
        publishing_point.add_subscriber(req.socket)
        # 以降、ソケットの扱いは読み込み側のスレッドにまかせる。
        req.socket = nil
      else
        # まだエンコーダーがヘッダーを送りきっていない。
        @log.debug("publishing point not ready")
        req.socket.write "HTTP/1.0 503 Service Unavailable\r\n\r\n"
      end
    else
      req.socket.write "HTTP/1.0 404 Not Found\r\n\r\n"
    end
  end

  # リクエストを種類によって振り分ける。
  def handle_request(request)
    case request.meth
    when 'GET'
      if request.path == "/stats"
        # 統計情報の要求。
        handle_stats(request)
      else
        # 視聴要求。
        handle_get(request)
      end
    when 'POST'
      # 出版要求。
      handle_post(request)
    else
      @log.error("unrecognised request: #{request.meth} #{request.path} ...")
      request.socket.write "HTTP/1.0 400 Bad Request\r\n\r\n"
    end
  end
end

Thread.abort_on_exception = true if $DEBUG
HttpMatroskaServer.new.run
