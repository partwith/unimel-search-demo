module Nexus
  module Mappers
    class Base
      def call(raw)
        raise NotImplementedError
      end
    end
  end
end
