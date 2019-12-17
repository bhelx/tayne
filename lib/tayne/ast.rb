# typed: true
module Tayne
  IGNORE_CALLS = %i(require extend).freeze
  BINARY_OPS = %i(+ - * / != == < <= > >=).freeze

  module AST

    class TypeContext
      attr_reader :var_bindings
      attr_reader :func_bindings
      attr_accessor :sig

      def initialize
        @var_bindings = {}
        @func_bindings = {}
        @sig = nil
      end

      # clear the pending signature when we fetch it
      def sig
        s = @sig
        @sig = nil
        s
      end
    end

    def self.from_parser(node)
      case node.type
      when :send
        a, b = node.children
        # skip requires
        if a.nil? && IGNORE_CALLS.include?(b)
          nil
        else
          Send.from_parser(node)
        end
      when :lvar
        LVar.new(node)
      when :lvasgn
        LVaSgn.new(node)
      when :int
        Int.new(node)
      when :float
        Float.new(node)
      when :sym
        Sym.new(node)
      when :str
        Str.new(node)
      when :const
        Const.new(node)
      when :pair
        Pair.new(node)
      when :hash
        Hsh.new(node)
      when :array
        Ary.new(node)
      when :true, :false
        Bool.new(node)
      when :begin
        Begin.new(node)
      when :def
        Def.new(node)
      when :if
        If.new(node)
      when :while
        While.new(node)
      when :module
        Mod.new(node)
      when :block
        Block.from_parser(node)
      else
        require'pry';binding.pry;
        raise ArgumentError, "from_parser doesn't know what to do with #{node}"
      end
    end

    class Node
      attr_reader :node, :type

      def initialize(node)
        @node = node
        @type = nil
      end

      def annotate_type!(_ctx)
      end
    end

    class Block < Node
      def self.from_parser(node)
        m, args, body = node.children
        m = AST.from_parser(m)
        if m.is_a?(SendToSelf) && m.name == 'sig'
          Sig.new(node)
        else
          #raise ArgumentError, ""
          require'pry';binding.pry;
        end
      end
    end

    # Not a Node because it's a temporary
    # object and is not used in compiled
    # output either
    class CompiledSig
      attr_reader :params, :returns

      def initialize(params, returns)
        @params, @returns = params, returns
        @params = @params.transform_keys { |k| k.to_s }
      end
    end

    class Sig < Block
      attr_reader :body

      def initialize(node)
        super node
        m, _args, body = node.children
        @body = AST.from_parser(body)
      end

      def annotate_type!(ctx)
        compiled_sig = if body.is_a?(SendToReceiver)
                         # Example: { params(a: Integer).returns(Integer }
                         if body.meth == 'returns'
                           params = body.recv.args.first.to_ruby
                           returns = body.args.first.to_ruby
                           CompiledSig.new(params, returns)
                         end
                       elsif body.is_a?(SendToSelf)
                         # Example: { returns(Integer }
                         if body.name == 'returns'
                           returns = body.args.first.to_ruby
                           CompiledSig.new({}, returns)
                         end
                       end

        # Pop sig onto context for next
        # method to pickup
        ctx.sig = compiled_sig
        nil
      end

      def compile(_ctx)
      end
    end

    class Mod < Node
      attr_reader :name, :expressions

      def initialize(node)
        super node
        name, *exprs = node.children
        @name = name.children.last.to_s
        @expressions = exprs.map do |n|
          AST.from_parser n
        end.compact # we're just skipping stuff we don't support
      end

      def annotate_type!(ctx)
        expressions.each { |e| e.annotate_type!(ctx) }
        @type = expressions.last.type
      end

      def compile(ctx)
        # # Make a new LLVM module
        # ctx.mod = LLVM::Module.new(name)
        #
        # We're mapping and returning the
        # last value as the block's "return" value
        expressions.map do |expr|
          expr.compile(ctx)
        end.last
      end
    end

    class Begin < Node
      attr_reader :expressions

      def initialize(node)
        super node
        @expressions = node.children.map do |n|
          AST.from_parser n
        end.compact # we're just skipping stuff we don't support
      end

      def annotate_type!(ctx)
        expressions.each { |e| e.annotate_type!(ctx) }
        @type = expressions.last.type
      end

      def compile(ctx)
        # We're mapping and returning the
        # last value as the block's "return" value
        expressions.map do |expr|
          expr.compile(ctx)
        end.last
      end
    end

    class Def < Node
      attr_reader :proto, :body

      def initialize(node)
        super node
        name, args, body = node.children
        @proto = DefProto.new(name, args)
        @body = AST.from_parser(body)
      end

      def name
        proto.name.to_s
      end

      def annotate_type!(ctx)
        @type = proto.annotate_type!(ctx)
        ctx.func_bindings[name] = proto.sig
        proto.sig.params.each do |k, v|
          ctx.var_bindings[k] = v
        end
        @body.annotate_type!(ctx)
        # clear the variable types
        ctx.var_bindings.clear
        @type
      end

      def compile(ctx)
        if was = ctx.mod.functions.named(name)
          raise ArgumentError, "Already defined function named #{name}"
        else
          # clear variable bindings
          ctx.bindings.clear

          # sets the types
          proto.compile(ctx)

          ll_args = proto.args.map do |a|
            proto.sig.params[a].to_llvm
          end

          ll_ret = proto.sig.returns.to_llvm

          function = ctx.mod.functions.add(name, ll_args, ll_ret)
          function.linkage = :external

          # Set the name of each argument from the ast
          proto.args.each_with_index do |arg, idx|
            function.params[idx].name = arg
          end

          # Create our "entry" basic block
          block = LLVM::BasicBlock.create(function, "entry")
          ctx.builder.position_at_end(block)

          # Create allocas for the arguments
          function.params.each do |param|
            type = proto.sig.params[param.name].to_llvm
            is_ptr = type.respond_to?(:kind) && type.kind == :pointer
            if is_ptr
              # TODO
              #require'pry';binding.pry;
              ctx.add_binding(param.name, param, type)
            else
              alloc = ctx.builder.alloca param, param.name
              ctx.builder.store param, alloc
              # Add arguments to variable symbol table.
              ctx.add_binding(param.name, alloc, type)
            end
          end

          ret = body.compile(ctx)
          ctx.builder.ret(ret)

          function.verify
          function
        end
      end
    end

    class DefProto
      attr_reader :name, :args, :sig

      def initialize(name, args)
        @name = name
        @args = args.children.map do |a|
          a.children.first.to_s
        end
      end

      def annotate_type!(ctx)
        @sig = ctx.sig
        @type = sig.returns
      end

      def compile(ctx)
      end
    end

    class While < Node
      attr_reader :cond, :body

      def initialize(node)
        super node
        cond, body = node.children
        @cond = AST.from_parser(cond)
        @body = AST.from_parser(body)
      end

      def annotate_type!(ctx)
        cond.annotate_type!(ctx)
        @type = body.annotate_type!(ctx)
      end

      def compile(ctx)
        func = ctx.builder.insert_block.parent

        cond_bb = func.basic_blocks.append "cond"

        ctx.builder.br(cond_bb)

        ctx.builder.position_at_end(cond_bb)
        cond_value = cond.compile(ctx)

        loop_bb = func.basic_blocks.append "loop"
        ctx.builder.position_at_end(loop_bb)

        loop_val = body.compile(ctx)
        ctx.builder.br(cond_bb)

        after_bb = func.basic_blocks.append "afterloop" 
        ctx.builder.position_at_end(cond_bb)
        ctx.builder.cond(cond_value, loop_bb, after_bb)
        ctx.builder.position_at_end(after_bb)
      end
    end

    class If < Node
      attr_reader :cond, :cons, :alt

      def initialize(node)
        super node
        cond, cons, alt = node.children
        @cond = AST.from_parser(cond)
        @cons = AST.from_parser(cons)
        @alt = nil
        if alt
          @alt = AST.from_parser(alt)
        end
      end

      def annotate_type!(ctx)
        cond.annotate_type!(ctx)
        cons.annotate_type!(ctx)
        alt.annotate_type!(ctx) if alt
        # TODO need a different way to find type?
        @type = cons.type
      end

      def compile(ctx)
        condition_value = @cond.compile(ctx)

        func = ctx.builder.insert_block.parent

        # Create blocks for the then and else cases.
        # "merge" them in the "phi" node
        then_block = func.basic_blocks.append "then"
        else_block = func.basic_blocks.append "else"
        merge_block = func.basic_blocks.append "merge"

        #build condition (does not automatically make the control flow merge after it)
        ctx.builder.cond(condition_value, then_block, else_block)

        # Emit then value
        ctx.builder.position_at_end then_block
        cons && then_value = cons.compile(ctx)

        # and create explicit br==branch to the merge (note that this transfers control only, not the value)
        ctx.builder.br merge_block
        # code of 'Then' can change the current block, update then_block for the PHI.
        then_block = ctx.builder.insert_block

        # Emit else block.
        #needed??    theFunction->getBasicBlockList().push_back(else_block)
        ctx.builder.position_at_end else_block
        alt && else_value = alt.compile(ctx)

        # code of 'Else' can change the current block, update else_block for the PHI.
        else_block = ctx.builder.insert_block

        # need to create an explicit branch to the merge block
        ctx.builder.br merge_block

        # Emit merge block.
        ctx.builder.position_at_end(merge_block)

        ctx.builder.phi(LLVM::Int, {then_block => then_value, else_block => else_value}, "iftmp")
     end
    end

    class Send < Node
      def self.from_parser(node)
        c = node.children
        if c[0].is_a?(Parser::AST::Node) && c[1].is_a?(Symbol) && c[2].is_a?(Parser::AST::Node)
         if BINARY_OPS.include?(c[1])
           BinaryOp.new(node)
         else
           SendToReceiver.new(node)
         end
        elsif c[0].is_a?(NilClass) && c[1].is_a?(Symbol)
           SendToSelf.new(node)
        else
          require'pry';binding.pry;
          raise ArgumentError, "Not sure what to do with send node #{node.inspect}"
        end
      end
    end

    class BinaryOp < Send
      attr_reader :lhs, :rhs, :op

      def initialize(node)
        super node
        lhs, @op, rhs = node.children
        @lhs = AST.from_parser(lhs)
        @rhs = AST.from_parser(rhs)
      end

      def annotate_type!(ctx)
        lhs.annotate_type!(ctx)
        rhs.annotate_type!(ctx)
        # TODO should check both types?
        @type = rhs.type
      end

      def compile(ctx)
        ll_type = type.to_llvm
        instr, sym = case op
                     when :+ 
                       if ll_type == LLVM::Int32
                         :add
                       elsif ll_type == LLVM::Float
                         :fadd
                       end
                     when :-
                       if ll_type == LLVM::Int32
                         :sub
                       elsif ll_type == LLVM::Float
                         :fsub
                       end
                     when :*
                       if ll_type == LLVM::Int32
                         :mul
                       elsif ll_type == LLVM::Float
                         :fmul
                       end
                     when :/
                       if ll_type == LLVM::Int32
                         :sdiv
                       elsif ll_type == LLVM::Float
                         :fdiv
                       end
                     when :== then [:icmp, :eq]
                     when :!= then [:icmp, :ne]
                     when :< then [:icmp, :slt]
                     when :<= then [:icmp, :sle]
                     when :> then [:icmp, :sgt]
                     when :>= then [:icmp, :sge]
                     else
                       raise ArgumentError, "Don't know about binary op #{@op}"
                     end

        x = lhs.compile(ctx)
        y = rhs.compile(ctx)

        if instr.nil?
          require'pry';binding.pry;
        end

        if instr == :icmp
          ctx.builder.icmp(sym, x, y)
        else
          ctx.builder.send(instr, x, y)
        end
      end
    end

    class SendToReceiver < Send
      attr_reader :recv, :meth, :args

      def initialize(node)
        super node
        recv, meth, *args = node.children
        @recv = AST.from_parser(recv)
        @meth = meth.to_s
        @args = args.map { |n| AST.from_parser n }
      end

      def annotate_type!(ctx)
        args.each do |arg|
          arg.annotate_type!(ctx)
        end
        t = recv.annotate_type!(ctx)
        # get inner type (example: array's element type)
        if t.respond_to? :type
          @type = t.type
        else
          @type = t
        end
      end

      def compile(ctx)
        obj = recv.compile(ctx)
        if recv.type.is_a?(ArrayType) || recv.type == Array
          if meth == "[]"
            # let's assume only only one idx
            idx = args.first.compile(ctx)
            ctx.builder.load ctx.builder.gep(obj, [LLVM::Int(0), idx])
          elsif meth == "[]="
            #require'pry';binding.pry;
            idx, *compiled_args = args.map { |a| a.compile(ctx) }
            ptr = ctx.builder.gep(obj, [LLVM::Int(0), idx])
            ctx.builder.store compiled_args.first, ptr
            ctx.builder.load ptr
          end
        else
          # TODO need to implement other reciever types
          require'pry';binding.pry;
        end
      end
    end

    class SendToSelf < Send
      attr_reader :name, :args

      def initialize(node)
        super node
        _nil, name, *args = node.children
        @name = name.to_s
        @args = args.map { |n| AST.from_parser n }
      end

      def annotate_type!(ctx)
        @args.each do |arg|
          arg.annotate_type!(ctx)
        end
        # TODO this is a hack
        if name == "puts" || name == "printf" || name == "sleep" || name == "usleep"
          @type = Integer
        elsif name == "clock"
          @type = ::Float
        else
          if name == 'debugger'
            require'pry';binding.pry;
            @type = Integer
          else
            if ctx.func_bindings[name].nil?
              require'pry';binding.pry;
            end
            # Assuming this is a defined method
            @type = ctx.func_bindings[name].returns
          end
        end
      end

      def compile(ctx)
        if name == 'debugger'
          require'pry';binding.pry;
        else
          func = ctx.mod.functions[name]
          raise ArgumentError, "Unknown function referenced: #{name}" unless func
          # Check for varargs instead of by name
          if func.params.size != args.length && name != "printf"
            raise ArgumentError, "Incorrect number of arguments"
          end
          compiled_args = args.map do |a|
            cmpld = a.compile(ctx)
            # we need to cast strings?
            # TODO should do this in puts probably
            if a.type.is_a? StringType
              zero = LLVM.Int(0)
              ctx.builder.gep cmpld, [zero, zero], 'cast210'
            else
              cmpld
            end
          end
          # Call puts function to write out the string to stdout.
          ctx.builder.call(func, *compiled_args, "calltmp")
        end
      end
    end

    class LVaSgn < Node
      attr_reader :name, :expr

      def initialize(node)
        super node
        @name = node.children.first.to_s
        @expr = AST.from_parser(node.children.last)
      end

      def annotate_type!(ctx)
        # Need to set the type of the expression and
        # register this left-hand-side variable type
        @type = ctx.var_bindings[name] = expr.annotate_type!(ctx)
      end

      def compile(ctx)
        result = expr.compile(ctx)

        alloc = if b = ctx.bindings[name]
          b.alloc
        else
          # Allocate the variable
          ctx.builder.alloca result, name
        end

        # Store the result
        ctx.builder.store result, alloc
        # Add to variable symbol table.
        ctx.add_binding(name, alloc)

        return alloc if returns_ptr?
        ctx.builder.load alloc
      end

      def returns_ptr?
        # LLVM type from bad bool annotate_type
        ![Integer, Float, LLVM::Int1, Array].include? type
      end
    end

    class LVar < Node
      attr_reader :name

      def initialize(node)
        super node
        @name = node.children.first.to_s
      end

      def annotate_type!(ctx)
        # Need to get type from some context
        @type = ctx.var_bindings[name]
      end

      def compile(ctx)
        if name == "debugger"
          require'pry';binding.pry;
        else
          alloc = ctx.bindings[name].alloc
          return alloc if returns_ptr?
          ctx.builder.load alloc
        end
      end

      def returns_ptr?
        # LLVM type from bad bool annotate_type
        ![::Integer, ::Float, ::LLVM::Int1].include? type
      end
    end

    class Lit < Node
    end

    class Int < Lit
      attr_reader :val

      def initialize(node)
        super node
        @val = node.children.first
      end

      def annotate_type!(_ctx)
        @type = Integer
      end

      def compile(_ctx)
        LLVM::Int(val)
      end
    end

    class Float < Lit
      def annotate_type!(_ctx)
        @type = ::Float
      end

      def compile(_ctx)
        LLVM::Float(node.children.first)
      end
    end

    class Pair < Lit
      attr_reader :left, :right
      def initialize(node)
        super node
        @left = AST.from_parser(node.children.first)
        @right = AST.from_parser(node.children.last)
      end
    end

    class Const < Lit
      attr_reader :name

      def initialize(node)
        super node
        @name = node.children.last
      end

      def annotate_type!(_ctx)
        # TODO ?
      end

      def to_ruby
        Kernel.const_get name
      end
    end

    class Sym < Lit
      attr_reader :val

      def initialize(node)
        super node
        @val = node.children.first
      end
    end

    class Str < Lit
      attr_reader :val

      def initialize(node)
        super node
        @val = node.children.first
      end

      def annotate_type!(_ctx)
        @type = StringType.new @val.size
      end

      def compile(ctx)
        LLVM::ConstantArray.string(val)
      end
    end

    class Hsh < Lit
      attr_reader :pairs

      def initialize(node)
        super node
        @pairs = node.children.map do |c|
          Pair.new(c)
        end
      end

      def to_ruby
        @pairs.map do |p|
          [
            p.left.val,
            p.right.to_ruby
          ]
        end.to_h
      end
    end

    class Ary < Lit
      attr_reader :elements

      def initialize(node)
        super node
        @elements = node.children.map do |el|
          AST.from_parser el
        end
      end

      def annotate_type!(ctx)
        @elements.each { |el| el.annotate_type!(ctx) }
        @type = ArrayType.new(elements.first&.type, elements.count)
      end

      def compile(ctx)
        llvm_els = @elements.map { |el| el.compile(ctx) }
        LLVM::ConstantArray.const(type.type.to_llvm, llvm_els)
      end
    end

    class Bool < Lit
      def annotate_type!(_ctx)
        @type = LLVM::Int1
      end

      def compile(_ctx)
        if node.type == :true
          ::LLVM::TRUE
        elsif node.type == :false
          ::LLVM::FALSE
        else
          raise ArgumentError, "Don't know what to do with bool value #{node}"
        end
      end
    end
  end
end
