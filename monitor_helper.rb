# モニターヘルパー
module MonitorHelper
  def self.included(klass)
    klass.extend ClassMethods
  end

  # クラスメソッド
  module ClassMethods
    # 指定されたメソッドを、実行する前に @lock をロックし、抜けた
    # 時にアンロックするように変更する。
    #
    # 例:
    #   class Foo
    #     include MonitorHelper
    #     def initialize
    #       @lock = Monitor.new
    #     end
    #     def bar
    #       # スレッド間で共有されるデータを参照する
    #     end
    #     make_safe :bar
    #   end
    def make_safe(method)
      imp = "_#{method}"
      instance_eval {
        alias_method(imp, method)
        define_method(method) do |*args, &block|
          # @lock という Monitor オブジェクトの存在を仮定している
          @lock.synchronize { send(imp, *args, &block) }
        end
      }
    end
  end
end
