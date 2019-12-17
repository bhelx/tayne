# typed: true
require 'parser/current'
require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'
require 'llvm/transforms/ipo'
require 'llvm/core/pass_manager'

module Tayne
  class Binding
    attr_reader :alloc, :type

    def initialize(alloc, type)
      @alloc, @type = alloc, type
    end
  end

  class Compiler
    class Context 
      attr_reader :builder
      attr_accessor :mod, :bindings

      def initialize(builder, mod)
        @mod = mod
        @builder = builder
        @bindings = {}
      end

      def add_binding(name, alloc, type=nil)
        @bindings[name] = Binding.new(alloc, type)
      end
    end

    def parse(code)
      Parser::CurrentRuby.parse(code)
    end

    def parset(node)
      AST.from_parser(node)
    end

    def label_types!(ast)
      ast.annotate_type!(AST::TypeContext.new)
    end

    def compile(code, run: false, debug: false)
      if debug
        puts "==" * 50
        puts "SOURCE CODE"
        puts "==" * 50
        puts code
        puts "==" * 50
        puts "AST"
        puts "==" * 50
      end

      wast = parse(code)

      if debug
        puts wast
        puts "==" * 50
        puts "LLVM IR"
        puts "==" * 50
      end

      ast = parset(wast)
      label_types!(ast)

      LLVM.init_jit
      builder = LLVM::Builder.new
      mod = LLVM::Module.parse_bitcode("kernel/kernel.bc")
      ctx = Context.new(builder, mod)

      ast.compile(ctx)

      ctx.mod.verify
      if debug
        puts ctx.mod.to_s

        puts "==" * 50
        puts "OPTIMIZED CODE"
        puts "==" * 50
      end

      # Optimize code
      passm = LLVM::PassManager.new
      passm.gdce!
      passm.mem2reg!
      passm.loop_unroll!
      passm.instcombine!
      passm.gvn!
      passm.adce!
      passm.simplifycfg!
      passm.indvars!
      passm.tailcallelim!
      passm.constprop!

      passm.run(ctx.mod)

      ctx.mod.verify
      puts ctx.mod.to_s

      if run
        puts "==" * 50
        puts "JIT COMPILE AND EXEC"
        puts "==" * 50

        jit = LLVM::JITCompiler.new(ctx.mod)
        puts jit.run_function(ctx.mod.functions["main"]).to_i
      end
    end
  end
end
