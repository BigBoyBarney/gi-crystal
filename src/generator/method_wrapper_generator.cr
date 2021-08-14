module Generator
  class MethodWrapperGenerator < Base
    @method_info : FunctionInfo
    @method_args : Array(ArgInfo)?
    @method_identifier : String?

    def initialize(@method_info : FunctionInfo)
      super(@method_info.namespace)
    end

    def do_generate(io : IO)
      symbol = @method_info.symbol
      generate_gi_flags_comments(io)
      generate_method_declaration(io)
      generate_method_wrapper_impl(io)
      io << "end\n"
      generate_method_splat_overload(io)
    rescue e : Error
      raise Error.new("Error generating binding for #{symbol}: #{e.message}")
    end

    def filename : String?
    end

    def subject : String
      @method_info.symbol
    end

    private def constructor?
      @method_info.flags.constructor?
    end

    private def generate_gi_flags_comments(io : IO)
      tags = [] of String
      args = @method_info.args
      io << "# Kind: " << @method_info.flags.to_s << LF
      args.each do |arg|
        tags << "(#{arg.direction.to_s.downcase})" unless arg.direction.in?
        tags << "(transfer #{arg.ownership_transfer.to_s.downcase})" unless arg.ownership_transfer.none?
        tags << "(nullable)" if arg.nullable?
        tags << "(caller-allocates)" if arg.caller_allocates?
        tags << "(optional)" if arg.optional?
        arg_type = arg.type_info
        if arg_type.tag.array?
          tags << String.build do |s|
            s << "(array"
            s << " length=" << args[arg_type.array_length].name if arg_type.array_length >= 0
            s << " fixed-size=" << arg_type.array_fixed_size if arg_type.array_fixed_size > 0
            s << " zero-terminated=1" if arg_type.array_zero_terminated?
            s << " element-type #{arg_type.param_type.tag}"
            s << ")"
          end
        end

        io << "# " << arg.name << ": " << tags.join(" ") << LF if tags.any?
        tags.clear
      end
      io << "# Returns: (transfer " << @method_info.caller_owns.to_s.downcase << ")\n" unless @method_info.caller_owns.none?
    end

    private def method_identifier : String
      @method_identifier ||= begin
        identifier = to_identifier(@method_info.name)
        identifier = if constructor?
                       if identifier == "new"
                         "initialize"
                       else
                         "self.#{identifier[4..]}"
                       end
                     elsif @method_info.args.empty? && identifier.starts_with?("get_") && identifier.size > 4
                       identifier[4..]
                     elsif @method_info.args.size == 1 && identifier.starts_with?("set_") && identifier.size > 4
                       "#{identifier[4..]}="
                     else
                       identifier
                     end
        # No flags means static methods
        identifier = "self.#{identifier}" if @method_info.flags.none?
        identifier
      end
    end

    private def generate_method_declaration(io : IO)
      io << "[@Deprecated]\n" if @method_info.deprecated?
      io << "def " << method_identifier
      generate_method_wrapper_args(io) if @method_info.args.any?
      io << " : " << to_crystal_type(@method_info.return_type, include_namespace: true) unless constructor?
      io << LF
    end

    private def method_args
      @method_args ||= begin
        args = @method_info.args.dup
        args_to_remove = [] of ArgInfo
        args.each do |arg|
          type_info = arg.type_info
          iface = type_info.interface
          if iface && Config.for(arg.namespace.name).ignore?(iface.name)
            Log.warn { "method using ignored type #{to_crystal_type(iface, true)} on arguments" }
          end
          args_to_remove << args[type_info.array_length] if type_info.array_length >= 0
        end
        args -= args_to_remove
      end
    end

    private def generate_method_wrapper_args(io : IO)
      io << "("
      io << method_args.map do |arg|
        null_mark = "?" if arg.nullable?
        "#{to_crystal_arg_decl(arg.name)} : #{to_crystal_type(arg.type_info)}#{null_mark}"
      end.join(", ")
      io << ")"
    end

    def generate_method_wrapper_impl(io : IO)
      args = @method_info.args
      return_type_info = @method_info.return_type

      if args.any?
        generate_lenght_param_impl(io)
        generate_nullable_and_arrays_param_impl(io)
      end

      generate_return_variable(io)
      generate_lib_call(io)
      if constructor?
        call = method_identifier
        call = "new" if method_identifier != "initialize"
        io << call << "(_ptr, GICrystal::Transfer::Full)\n"
      else
        generate_return_value(io)
      end
    end

    def generate_lenght_param_impl(io : IO)
      args = @method_info.args
      args.each do |arg|
        arg_type = arg.type_info
        if arg_type.array_length >= 0
          io << to_identifier(args[arg_type.array_length].name) << " = " << to_identifier(arg.name)
          io << (arg.nullable? ? ".try(&.size) || 0" : ".size") << LF
        end
      end
    end

    def generate_nullable_and_arrays_param_impl(io : IO)
      args = @method_info.args
      args.each do |arg|
        if arg.nullable?
          arg_name = to_identifier(arg.name)
          io << arg_name << " = if " << arg_name << ".nil?\n"
          io << to_lib_type(arg.type_info) << ".null\n"
          io << "else\n"
          if arg.type_info.array?
            io << arg_name << ".to_a.map(&.to_unsafe).to_unsafe\n"
          else
            io << arg_name << ".to_unsafe\n"
          end
          io << "end\n"
        end
      end
    end

    def generate_return_variable(io : IO)
      flags = @method_info.flags
      return_type_info = @method_info.return_type
      if flags.constructor?
        io << "_ptr = "
      elsif !return_type_info.void?
        io << "_retval = "
      end
    end

    def generate_lib_call(io : IO)
      args = @method_info.args
      flags = @method_info.flags

      io << to_lib_type(@method_info, include_namespace: true) << "("
      call_args = [] of String
      call_args << "self" if flags.method?

      @method_info.args.each do |arg|
        call_args << to_identifier(arg.name)
      end
      call_args.join(", ", io)
      io << ")"
      io << ".as(Pointer(Void))" if flags.constructor?
      io << LF
    end

    def generate_return_value(io : IO)
      ret_type = @method_info.return_type
      return if ret_type.tag.void? && !ret_type.pointer?

      expr = convert_to_crystal("_retval", ret_type, @method_info.caller_owns)
      io << expr << LF if expr != "_retval"
    end

    # If the method only receive a array as argument, create a splat overload, so if
    # `def foo(bar : Enumerable(String))` exists, `def foo(*bar : String)` will also be generated.
    def generate_method_splat_overload(io : IO)
      return if method_args.size != 1
      arg = method_args.first

      return unless arg.type_info.tag.array?
      return if method_identifier.ends_with?("=")

      io << "def " << method_identifier << "(*" << to_identifier(arg.name) << ")\n"
      io << method_identifier << "(" << to_identifier(arg.name) << ")\n"
      io << "end\n"
    end
  end
end
