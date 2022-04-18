require "./field_info"
require "./function_info"
require "./property_info"
require "./signal_info"

module GObjectIntrospection
  class ObjectInfo < RegisteredTypeInfo
    include FieldInfoContainer
    include FunctionInfoContainer
    include PropertyInfoContainer
    include SignalInfoContainer

    @interfaces : Array(InterfaceInfo)?
    @properties : Array(PropertyInfo)?
    @signals : Array(SignalInfo)?

    def parent : ObjectInfo?
      ptr = LibGIRepository.g_object_info_get_parent(self)
      ObjectInfo.new(ptr) if ptr
    end

    def unref_function : String
      func = LibGIRepository.g_object_info_get_unref_function(self)
      func.null? ? "g_object_unref" : String.new(func)
    end

    def ref_function : String
      func = LibGIRepository.g_object_info_get_ref_function(self)
      return "g_object_ref_sink" if func.null?

      ref_func = String.new(func)
      # FIXME: g_param_spec_ref_sink seems bad or I'm doing something wrong.
      ref_func == "g_param_spec_ref_sink" ? "g_param_spec_ref" : ref_func
    end

    def class_struct : StructInfo
      ptr = LibGIRepository.g_object_info_get_class_struct(self)
      return Repository.default.find_by_name("GObject", "ObjectClass").as(StructInfo) if ptr.null?

      StructInfo.new(ptr)
    end

    def initially_unowned? : Bool
      parent = LibGIRepository.g_object_info_get_parent(self)
      return false if parent.null?

      while !parent.null?
        type_name = LibGIRepository.g_object_info_get_type_name(parent)
        if LibC.strcmp(type_name, "GInitiallyUnowned").zero?
          return true
        else
          new_parent = LibGIRepository.g_object_info_get_parent(parent)
          LibGIRepository.g_base_info_unref(parent)
          parent = new_parent
        end
      end
      false
    ensure
      LibGIRepository.g_base_info_unref(parent) if parent
    end

    def methods : Array(FunctionInfo)
      methods(->LibGIRepository.g_object_info_get_n_methods, ->LibGIRepository.g_object_info_get_method)
    end

    def fields : Array(FieldInfo)
      fields(->LibGIRepository.g_object_info_get_n_fields, ->LibGIRepository.g_object_info_get_field)
    end

    def properties : Array(PropertyInfo)
      properties(->LibGIRepository.g_object_info_get_n_properties, ->LibGIRepository.g_object_info_get_property)
    end

    def signals : Array(SignalInfo)
      signals(->LibGIRepository.g_object_info_get_n_signals, ->LibGIRepository.g_object_info_get_signal)
    end

    def interfaces : Array(InterfaceInfo)
      @interfaces ||= begin
        n = LibGIRepository.g_object_info_get_n_interfaces(self)
        Array.new(n) do |i|
          ptr = LibGIRepository.g_object_info_get_interface(self, i)
          InterfaceInfo.new(ptr)
        end
      end
    end
  end
end
