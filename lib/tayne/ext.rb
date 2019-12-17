class Integer
  def self.to_llvm
    LLVM::Int
  end
end

class Float
  def self.to_llvm
    LLVM::Float
  end
end

class StringType
  attr_reader :size

  def initialize(size)
    @size = size
  end

  def to_llvm
    LLVM::Array(LLVM::Int8, size)
  end
end

class ArrayType
  attr_reader :type, :size
  def initialize(type, size)
    @type, @size = type, size
  end

  def to_llvm
    LLVM::Array(LLVM::Int, size)
  end
end

class Array
  def self.to_llvm
    LLVM.Pointer(LLVM::Int.type)
  end
end

class StructType
  attr_reader :name
  def initialize(name)
    @name = name
  end
end
