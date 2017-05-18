# モニターヘルパー
module MonitorHelper
  def self.included(klass)
    klass.extend ClassMethods
  end

  # クラスメソッド
  module ClassMethods
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
