SimpleItem = Struct.new(:sku, :warehouse, :condition, :source, :price, :count)

module Enumerable
  def min
    reduce(first) { |memo, item| item < memo ? item : memo }
  end
end

class Array
  def sample
    self[rand(size)]
  end
end
