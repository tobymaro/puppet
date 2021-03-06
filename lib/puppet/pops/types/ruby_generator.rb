module Puppet::Pops
module Types

# @api private
class RubyGenerator < TypeFormatter
  def remove_common_namespace(namespace_segments, name)
    segments = name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR)
    namespace_segments.size.times do |idx|
      break if segments.empty? || namespace_segments[idx] != segments[0]
      segments.shift
    end
    segments
  end

  def namespace_relative(namespace_segments, name)
    remove_common_namespace(namespace_segments, name).join(TypeFormatter::NAME_SEGMENT_SEPARATOR)
  end

  def create_class(obj)
    @dynamic_classes ||= Hash.new do |hash, key|
      cls = key.implementation_class(false)
      if cls.nil?
        rp = key.resolved_parent
        parent_class = rp.is_a?(PObjectType) ? rp.implementation_class : Object
        class_def = ''
        class_body(key, EMPTY_ARRAY, class_def)
        cls = Class.new(parent_class)
        cls.class_eval(class_def)
        cls.define_singleton_method(:_ptype) { return key }
        key.implementation_class = cls
      end
      hash[key] = cls
    end
    raise ArgumentError, "Expected a Puppet Type, got '#{obj.class.name}'" unless obj.is_a?(PAnyType)
    @dynamic_classes[obj]
  end

  def module_definition_from_typeset(typeset)
    module_definition(
      typeset.types.values,
      "# Generated by #{self.class.name} from TypeSet #{typeset.name} on #{Date.new}\n")
  end

  def module_definition(types, comment)
    object_types, aliased_types = types.partition { |type| type.is_a?(PObjectType) }
    impl_names = implementation_names(object_types)

    # extract common implementation module prefix
    common_prefix = []
    segmented_names = impl_names.map { |impl_name| impl_name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR) }
    segments = segmented_names[0]
    segments.size.times do |idx|
      segment = segments[idx]
      break unless segmented_names.all? { |sn| sn[idx] == segment }
      common_prefix << segment
    end

    # Create class definition of all contained types
    bld = ''
    start_module(common_prefix, comment, bld)
    class_names = []
    object_types.each_with_index do |type, index|
      class_names << class_definition(type, common_prefix, bld, impl_names[index])
      bld << "\n"
    end

    aliases = Hash[aliased_types.map { |type| [type.name, type.resolved_type] }]
    end_module(common_prefix, aliases, class_names, bld)
    bld
  end

  def start_module(common_prefix, comment, bld)
    bld << '# ' << comment << "\n"
    common_prefix.each { |cp| bld << 'module ' << cp << "\n" }
  end

  def end_module(common_prefix, aliases, class_names, bld)
    # Emit registration of contained type aliases
    unless aliases.empty?
      bld << "Puppet::Pops::Pcore.register_aliases({\n"
      aliases.each { |name, type| bld << "  '" << name << "' => " << TypeFormatter.string(type.to_s) << "\n" }
      bld.chomp!(",\n")
      bld << "})\n\n"
    end

    # Emit registration of contained types
    unless class_names.empty?
      bld << "Puppet::Pops::Pcore.register_implementations([\n"
      class_names.each { |class_name| bld << '  ' << class_name << ",\n" }
      bld.chomp!(",\n")
      bld << "])\n\n"
    end
    bld.chomp!("\n")

    common_prefix.size.times { bld << "end\n" }
  end

  def implementation_names(object_types)
    object_types.map do |type|
      ir = Loaders.implementation_registry
      impl_name = ir.module_name_for_type(type)
      raise Puppet::Error, "Unable to create an instance of #{type.name}. No mapping exists to runtime object" if impl_name.nil?
      impl_name[0]
    end
  end

  def class_definition(obj, namespace_segments, bld, class_name)
    module_segments = remove_common_namespace(namespace_segments, class_name)
    leaf_name = module_segments.pop
    module_segments.each { |segment| bld << 'module ' << segment << "\n" }
    bld << 'class ' << leaf_name
    segments = class_name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR)

    unless obj.parent.nil?
      ir = Loaders.implementation_registry
      parent_impl = ir.module_name_for_type(obj.parent)
      raise Puppet::Error, "Unable to create an instance of #{obj.parent.name}. No mapping exists to runtime object" if parent_impl.nil?
      bld << ' < ' << namespace_relative(segments, parent_impl[0])
    end

    bld << "\n"
    bld << "  def self._plocation\n"
    bld << "    loc = Puppet::Util.path_to_uri(\"\#{__FILE__}\")\n"
    bld << "    URI(\"#\{loc}?line=#\{__LINE__.to_i - 3}\")\n"
    bld << "  end\n"

    bld << "\n"
    bld << "  def self._ptype\n"
    bld << '    @_ptype ||= ' << namespace_relative(segments, obj.class.name) << ".new('" << obj.name << "', "
    bld << TypeFormatter.singleton.ruby('ref').indented(2).string(obj.i12n_hash(false)) << ")\n"
    bld << "  end\n"

    class_body(obj, segments, bld)

    bld << "end\n"
    module_segments.size.times { bld << "end\n" }
    module_segments << leaf_name
    module_segments.join(TypeFormatter::NAME_SEGMENT_SEPARATOR)
  end

  def class_body(obj, segments, bld)
    if obj.parent.nil?
      bld << "\n  include " << namespace_relative(segments, Puppet::Pops::Types::PuppetObject.name) << "\n\n" # marker interface
      bld << "  def self.ref(type_string)\n"
      bld << '    ' << namespace_relative(segments, Puppet::Pops::Types::PTypeReferenceType.name) << ".new(type_string)\n"
      bld << "  end\n"
    end

    # Output constants
    constants, others = obj.attributes(true).values.partition { |a| a.kind == PObjectType::ATTRIBUTE_KIND_CONSTANT }
    constants = constants.select { |ca| ca.container.equal?(obj) }
    unless constants.empty?
      constants.each { |ca| bld << "\n  def self." << ca.name << "\n    _ptype['" << ca.name << "'].value\n  end\n" }
      constants.each { |ca| bld << "\n  def " << ca.name << "\n    self.class." << ca.name << "\n  end\n" }
    end

    init_params = others.reject { |a| a.kind == PObjectType::ATTRIBUTE_KIND_DERIVED }
    opt, non_opt = init_params.partition { |ip| ip.value? }
    derived_attrs, obj_attrs = others.select { |a| a.container.equal?(obj) }.partition { |ip| ip.kind == PObjectType::ATTRIBUTE_KIND_DERIVED }

    include_type = obj.equality_include_type? && !(obj.parent.is_a?(PObjectType) && obj.parent.equality_include_type?)
    if obj.equality.nil?
      eq_names = obj_attrs.reject { |a| a.kind == PObjectType::ATTRIBUTE_KIND_CONSTANT }.map(&:name)
    else
      eq_names = obj.equality
    end

    unless obj.parent.is_a?(PObjectType) && obj_attrs.empty?
      # Output type safe hash constructor
      bld << "\n  def self.from_hash(i12n)\n"
      bld << '    from_asserted_hash(' << namespace_relative(segments, TypeAsserter.name) << '.assert_instance_of('
      bld << "'" << obj.label << " initializer', _ptype.i12n_type, i12n))\n  end\n\n  def self.from_asserted_hash(i12n)\n    new"
      unless non_opt.empty? && opt.empty?
        bld << "(\n"
        non_opt.each { |ip| bld << "      i12n['" << ip.name << "'],\n" }
        opt.each do |ip|
          if ip.value.nil?
            bld << "      i12n['" << ip.name << "'],\n"
          else
            bld << "      i12n.fetch('" << ip.name << "') { "
            default_string(bld, ip)
            bld << " },\n"
          end
        end
        bld.chomp!(",\n")
        bld << ').freeze'
      end
      bld << "\n  end\n"

      # Output type safe constructor
      bld << "\n  def self.create"
      if init_params.empty?
        bld << "\n    new"
      else
        bld << '('
        non_opt.each { |ip| bld << ip.name << ', ' }
        opt.each do |ip|
          bld << ip.name << ' = '
          default_string(bld, ip)
          bld << ', '
        end
        bld.chomp!(', ')
        bld << ")\n"
        bld << '    ta = ' << namespace_relative(segments, TypeAsserter.name) << "\n"
        bld << "    attrs = _ptype.attributes(true)\n"
        init_params.each do |a|
          bld << "    ta.assert_instance_of('" << a.container.name << '[' << a.name << ']'
          bld << "', attrs['" << a.name << "'].type, " << a.name << ")\n"
        end
        bld << '    new('
        non_opt.each { |a| bld << a.name << ', ' }
        opt.each { |a| bld << a.name << ', ' }
        bld.chomp!(', ')
        bld << ')'
      end
      bld << ".freeze\n  end\n"

      # Output attr_readers
      unless obj_attrs.empty?
        bld << "\n"
        obj_attrs.each { |a| bld << '  attr_reader :' << a.name << "\n" }
      end

      bld << "  attr_reader :hash\n" if obj.parent.nil?

      derived_attrs.each do |a|
        bld << "\n  def " << a.name << "\n"
        code_annotation = RubyMethod.annotate(a)
        ruby_body = code_annotation.nil? ? nil: code_annotation.body
        if ruby_body.nil?
          bld << "    raise Puppet::Error, \"no method is implemented for derived #{a.label}\"\n"
        else
          bld << '    ' << ruby_body << "\n"
        end
        bld << "  end\n"
      end

      if init_params.empty?
        bld << "\n  def initialize\n    @hash = " << obj.hash.to_s << "\n  end" if obj.parent.nil?
      else
        # Output initializer
        bld << "\n  def initialize"
        bld << '('
        non_opt.each { |ip| bld << ip.name << ', ' }
        opt.each do |ip|
          bld << ip.name << ' = '
          default_string(bld, ip)
          bld << ', '
        end
        bld.chomp!(', ')
        bld << ')'

        hash_participants = init_params.select { |ip| eq_names.include?(ip.name) }
        if obj.parent.nil?
          bld << "\n    @hash = "
          bld << obj.hash.to_s << "\n" if hash_participants.empty?
        else
          bld << "\n    super("
          super_args = (non_opt + opt).select { |ip| !ip.container.equal?(obj) }
          unless super_args.empty?
            super_args.each { |ip| bld << ip.name << ', ' }
            bld.chomp!(', ')
          end
          bld << ")\n"
          bld << '    @hash = @hash ^ ' unless hash_participants.empty?
        end
        unless hash_participants.empty?
          hash_participants.each { |a| bld << a.name << '.hash ^ ' if a.container.equal?(obj) }
          bld.chomp!(' ^ ')
          bld << "\n"
        end
        init_params.each { |a| bld << '    @' << a.name << ' = ' << a.name << "\n" if a.container.equal?(obj) }
        bld << "  end\n"
      end
    end

    if obj_attrs.empty?
      bld << "\n  def i12n_hash\n    {}\n  end\n" unless obj.parent.is_a?(PObjectType)
    else
      bld << "\n  def i12n_hash\n"
      bld << '    result = '
      bld << (obj.parent.nil? ? '{}' : 'super')
      bld << "\n"
      obj_attrs.each do |a|
        bld << "    result['" << a.name << "'] = @" << a.name
        if a.value?
          bld << ' unless '
          equals_default_string(bld, a)
        end
        bld << "\n"
      end
      bld << "    result\n  end\n"
    end

    content_participants = init_params.select { |a| content_participant?(a) }
    if content_participants.empty?
      unless obj.parent.is_a?(PObjectType)
        bld << "\n  def _pcontents\n  end\n"
        bld << "\n  def _pall_contents(path)\n  end\n"
      end
    else
      bld << "\n  def _pcontents\n"
      content_participants.each do |cp|
        if array_type?(cp.type)
          bld << '    @' << cp.name << ".each { |value| yield(value) }\n"
        else
          bld << '    yield(@' << cp.name << ') unless @' << cp.name  << ".nil?\n"
        end
      end
      bld << "  end\n\n  def _pall_contents(path, &block)\n    path << self\n"
      content_participants.each do |cp|
        if array_type?(cp.type)
          bld << '    @' << cp.name << ".each do |value|\n"
          bld << "      block.call(value, path)\n"
          bld << "      value._pall_contents(path, &block)\n"
        else
          bld << '    unless @' << cp.name << ".nil?\n"
          bld << '      block.call(@' << cp.name << ", path)\n"
          bld << '      @' << cp.name << "._pall_contents(path, &block)\n"
        end
        bld << "    end\n"
      end
      bld << "    path.pop\n  end\n"
    end

    unless obj.parent.is_a?(PObjectType)
      bld << "\n  def to_s\n"
      bld << '    ' << namespace_relative(segments, TypeFormatter.name) << ".string(self)\n"
      bld << "  end\n"
    end

    # Output function placeholders
    obj.functions(false).each_value do |func|
      code_annotation = RubyMethod.annotate(func)
      if code_annotation
        body = code_annotation.body
        params = code_annotation.parameters
        bld << "\n  def " << func.name
        unless params.nil? || params.empty?
          bld << '(' << params << ')'
        end
        bld << "\n    " << body << "\n"
      else
        bld << "\n  def " << func.name << "(*args)\n"
        bld << "    # Placeholder for #{func.type}\n"
        bld << "    raise Puppet::Error, \"no method is implemented for #{func.label}\"\n"
      end
      bld << "  end\n"
    end

    unless eq_names.empty? && !include_type
      bld << "\n  def eql?(o)\n"
      bld << "    super &&\n" unless obj.parent.nil?
      bld << "    o.instance_of?(self.class) &&\n" if include_type
      eq_names.each { |eqn| bld << '    @' << eqn << '.eql?(o.' <<  eqn << ") &&\n" }
      bld.chomp!(" &&\n")
      bld << "\n  end\n  alias == eql?\n"
    end
  end

  def content_participant?(a)
    a.kind != PObjectType::ATTRIBUTE_KIND_REFERENCE && obj_type?(a.type)
  end

  def obj_type?(t)
    case t
    when PObjectType
      true
    when POptionalType
      obj_type?(t.optional_type)
    when PNotUndefType
      obj_type?(t.type)
    when PArrayType
      obj_type?(t.element_type)
    when PVariantType
      t.types.all? { |v| obj_type?(v) }
    else
      false
    end
  end

  def array_type?(t)
    case t
    when PArrayType
      true
    when POptionalType
      array_type?(t.optional_type)
    when PNotUndefType
      array_type?(t.type)
    when PVariantType
      t.types.all? { |v| array_type?(v) }
    else
      false
    end
  end

  def default_string(bld, a)
    case a.value
    when nil, true, false, Numeric, String
      bld << a.value.inspect
    else
      bld << "_ptype['" << a.name << "'].value"
    end
  end

  def equals_default_string(bld, a)
    case a.value
    when nil, true, false, Numeric, String
      bld << '@' << a.name << ' == ' << a.value.inspect
    else
      bld << "_ptype['" << a.name << "'].default_value?(@" << a.name << ')'
    end
  end
end
end
end
