module Nexus
  module Harvesters
    class Base
      def each(from:)
        raise NotImplementedError
      end

      def deleted_ids(from:)
        raise NotImplementedError
      end

      def until
        raise NotImplementedError
      end
    end
  end
end
