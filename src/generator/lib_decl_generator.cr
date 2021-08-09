module Generator
  class LibDeclGenerator < Base
    def filename : String
      "lib_#{@namespace.name.underscore}.cr"
    end

    def subject : String
      "Lib#{@namespace.name}"
    end

    def do_generate(io : IO)
      generate_library_links(io)
      io << "lib " << to_lib_namespace(@namespace) << LF
      generate_extra_gobj_fun(io)
      generate_flags(io)
      generate_enums(io)
      generate_interfaces(io)
      generate_structs(io)
      generate_unions(io)
      generate_objects(io)
      io << "# Module Functions\n"
      generate_c_functions(io, @namespace.functions, false)
      io << "end\n"
    rescue e : Error
      raise Error.new("failed to generate lib block for #{@namespace.name}: #{e.message}")
    end

    private def generate_extra_gobj_fun(io : IO)
      return if @namespace.name != "GObject"

      io << "fun g_object_get(object : Pointer(Void), property_name : Pointer(LibC::Char), ...)\n"
      io << "fun g_object_set(object : Pointer(Void), property_name : Pointer(LibC::Char), ...)\n"
    end

    private def generate_library_links(io : IO)
      @namespace.shared_libraries.each do |library|
        libname = library[/lib([^\/]+)\.(?:so|.+?\.dylib).*/, 1]

        io << "@[Link(\"" << libname << "\", pkg_config: \"" << libname << "\")]\n"
      end
    end

    private def generate_flags(io : IO)
      io << "# Flags\n"
      @namespace.flags.each do |flag|
        add_ignore_comment(io, flag.name)
        io << "type " << to_lib_type(flag, include_namespace: false) << " = " << to_lib_type(flag.storage_type) << LF
      end
      io.puts
    end

    private def generate_structs(io : IO)
      io << "# Structs\n\n"
      @namespace.structs.each do |struct_info|
        next if struct_info.gtype_struct?

        force_ignore = add_ignore_comment(io, struct_info.name)
        if struct_info.bytesize.zero?
          io << "# Struct with zero bytes\n"
          generate_void_alias(io, struct_info)
        else
          io << "struct " << to_type_name(struct_info.name) << " # #{struct_info.bytesize} bytes long\n"
          generate_fields(io, struct_info.fields)
          io << "end\n\n"
        end

        io << "# " << to_lib_type(struct_info) << " C Functions\n"
        if struct_info.bytesize.zero?
          io << "fun #{to_get_type_function(struct_info)} : LibC::SizeT\n"
        end
        generate_c_functions(io, struct_info.methods, force_ignore)
        io << LF
      end
    end

    private def generate_unions(io : IO)
      io << "# Unions\n"
      @namespace.unions.each do |union_info|
        if union_info.bytesize.zero?
          add_ignore_comment(io, union_info.name)
          io << "# Union with zero bytes\n"
          generate_void_alias(io, union_info)
          next
        end

        io << "union " << to_lib_type(union_info, include_namespace: false) << " # #{union_info.bytesize} bytes long\n"
        generate_fields(io, union_info.fields)
        io << "end\n"
      end
    end

    private def generate_enums(io : IO)
      io << "# Enums\n"
      @namespace.enums.each do |enum_info|
        add_ignore_comment(io, enum_info.name)
        io << "type " << to_lib_type(enum_info, include_namespace: false) << " = " << to_lib_type(enum_info.storage_type) << LF
      end
      io.puts
    end

    private def generate_interfaces(io : IO)
      io << "# Interfaces\n"
      @namespace.interfaces.each do |iface|
        force_ignore = add_ignore_comment(io, iface.name)
        generate_void_alias(io, iface)
        io << "# " << to_lib_type(iface) << " C Functions\n"
        generate_c_functions(io, iface.methods, force_ignore)
      end
      io.puts
    end

    private def generate_objects(io : IO)
      io << "# Objects\n"
      @namespace.objects.each do |obj_info|
        generate_obj(io, obj_info) unless obj_info.deprecated?
      end
    end

    private def generate_obj(io : IO, obj_info : ObjectInfo)
      obj_fields = obj_info.fields
      force_ignore = add_ignore_comment(io, obj_info.name)
      if obj_fields.empty?
        generate_void_alias(io, obj_info)
      else
        io << "struct " << to_lib_type(obj_info, include_namespace: false) << LF
        generate_fields(io, obj_fields)
        io << "end\n\n"
      end

      return if obj_info.methods.empty?
      io << "# " << to_lib_type(obj_info) << " C Functions\n"
      generate_c_functions(io, obj_info.methods, force_ignore)
      io << "\n\n"
    end

    private def generate_c_functions(io : IO, functions : Array(FunctionInfo), force_ignore : Bool)
      functions.each do |func|
        add_ignore_comment(io, func.symbol, force_ignore)
        generate_c_function(io, func)
      end
    end

    private def generate_fields(io : IO, fields : Array(FieldInfo))
      fields.each do |field|
        io << to_identifier(field.name) << " : " << to_lib_type(field.type_info) << LF
      end
    end

    private def generate_c_function(io : IO, func_info : FunctionInfo)
      symbol = func_info.symbol

      io << "fun " << symbol
      generate_c_function_args(io, func_info)
      io << " : " << to_lib_type(func_info.return_type) << LF
    end

    private def generate_c_function_args(io : IO, func_info : FunctionInfo)
      flags = func_info.flags

      if func_info.args.empty?
        io << "(self : Void*)" if flags.method?
        return
      end

      lib_args = [] of String
      lib_args << "self : Void*" if flags.method?
      func_info.args.each do |arg|
        lib_args << "#{to_identifier(arg.name)} : #{to_lib_type(arg.type_info)}"
      end

      io << "(" << lib_args.join(", ") << ")"
    end

    private def generate_void_alias(io : IO, info : BaseInfo)
      io << "type " << to_type_name(info.name) << " = Void\n"
    end

    private def add_ignore_comment(io : IO, subject : String, force_ignore = false) : Bool
      ignored = force_ignore || skip?(subject)
      io << "# IGNORED for binding\n" if ignored
      ignored
    end
  end
end
