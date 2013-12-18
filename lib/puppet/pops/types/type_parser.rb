# This class provides parsing of Type Specification from a string into the Type
# Model that is produced by the Puppet::Pops::Types::TypeFactory.
#
# The Type Specifications that are parsed are the same as the stringified forms
# of types produced by the {Puppet::Pops::Types::TypeCalculator TypeCalculator}.
#
# @api public
class Puppet::Pops::Types::TypeParser
  # @api private
  TYPES = Puppet::Pops::Types::TypeFactory

  # @api public
  def initialize
    @parser = Puppet::Pops::Parser::Parser.new()
    @type_transformer = Puppet::Pops::Visitor.new(nil, "interpret", 0, 0)
  end

  # Produces a *puppet type* based on the given string.
  #
  # @example
  #     parser.parse('Integer')
  #     parser.parse('Array[String]')
  #     parser.parse('Hash[Integer, Array[String]]')
  #
  # @param string [String] a string with the type expressed in stringified form as produced by the 
  #   {Puppet::Pops::Types::TypeCalculator#string TypeCalculator#string} method.
  # @return [Puppet::Pops::Types::PObjectType] a specialization of the PObjectType representing the type.
  #
  # @api public
  #
  def parse(string)
    # TODO: This state (@string) can be removed since the parse result of newer future parser
    # contains a Locator in its SourcePosAdapter and the Locator keeps the the string.
    # This way, there is no difference between a parsed "string" and something that has been parsed
    # earlier and fed to 'interpret'
    #
    @string = string
    model = @parser.parse_string(@string)
    if model
      interpret(model.current)
    else
      raise_invalid_type_specification_error
    end
  end

  # @api private
  def interpret(ast)
    result = @type_transformer.visit_this_0(self, ast)
    raise_invalid_type_specification_error unless result.is_a?(Puppet::Pops::Types::PAbstractType)
    result
  end

  # @api private
  def interpret_any(ast)
    @type_transformer.visit_this_0(self, ast)
  end

  # @api private
  def interpret_Object(o)
    raise_invalid_type_specification_error
  end

  # @api private
  def interpret_QualifiedName(o)
    o.value
  end

  # @api private
  def interpret_LiteralString(o)
    o.value
  end

  # @api private
  def interpret_String(o)
    o
  end

  # @api private
  def interpret_LiteralDefault(o)
    :default
  end

  def interpret_LiteralInteger(o)
    o.value
  end

  def interpret_LiteralFloat(o)
    o.value
  end

  # @api private
  def interpret_QualifiedReference(name_ast)
    case name_ast.value
    when "integer"
      TYPES.integer

    when "float"
      TYPES.float

    when "numeric"
        TYPES.numeric

    when "string"
      TYPES.string

    when "enum"
      TYPES.enum

    when "boolean"
      TYPES.boolean

    when "pattern"
      TYPES.pattern

    when "regexp"
      TYPES.regexp

    when "data"
      TYPES.data

    when "array"
      TYPES.array_of_data

    when "hash"
      TYPES.hash_of_data

    when "class"
      TYPES.host_class()

    when "resource"
      TYPES.resource()

    when "collection"
      TYPES.collection()

    when "literal"
      TYPES.literal()

    when "catalogentry"
      TYPES.catalog_entry()

    when "undef"
      # Should not be interpreted as Resource type
      TYPES.undef()

    when "object"
      TYPES.object()

    when "variant"
        TYPES.variant()

    when "ruby", "type"
      # should not be interpreted as Resource type
      # TODO: these should not be errors
      raise_unknown_type_error(name_ast)
    else
      TYPES.resource(name_ast.value)
    end
  end

  # @api private
  def interpret_AccessExpression(parameterized_ast)
    parameters = parameterized_ast.keys.collect { |param| interpret_any(param) }

    unless parameterized_ast.left_expr.is_a?(Puppet::Pops::Model::QualifiedReference)
      raise_invalid_type_specification_error
    end

    case parameterized_ast.left_expr.value
    when "array"
      if parameters.size != 1
        raise_invalid_parameters_error("Array", 1, parameters.size)
      end
      assert_type(parameters[0])
      TYPES.array_of(parameters[0])

    when "hash"
      if parameters.size == 1
        assert_type(parameters[0])
        TYPES.hash_of(parameters[0])
      elsif parameters.size != 2
        raise_invalid_parameters_error("Hash", "1 or 2", parameters.size)
      else
        assert_type(parameters[0])
        assert_type(parameters[1])
        TYPES.hash_of(parameters[1], parameters[0])
      end

    when "class"
      if parameters.size != 1
        raise_invalid_parameters_error("Class", 1, parameters.size)
      end
      TYPES.host_class(parameters[0])

    when "resource"
      if parameters.size == 1
        TYPES.resource(parameters[0])
      elsif parameters.size != 2
        raise_invalid_parameters_error("Resource", "1 or 2", parameters.size)
      else
        TYPES.resource(parameters[0], parameters[1])
      end

    when "regexp"
      # 1 parameter being a string, or regular expression
      raise_invalid_parameters_error("Regexp", "1", parameters.size) unless parameters.size == 1
      TYPES.regexp(parameters[0])

    when "enum"
      # 1..m parameters being strings
      raise_invalid_parameters_error("Enum", "1 or more", parameters.size) unless parameters.size > 1
      TYPES.enum(*parameters)

    when "pattern"
      # 1..m parameters being strings or regular expressions
      raise_invalid_parameters_error("Pattern", "1 or more", parameters.size) unless parameters.size > 1
      TYPES.pattern(*parameters)

    when "variant"
      # 1..m parameters being strings or regular expressions
      raise_invalid_parameters_error("Variant", "1 or more", parameters.size) unless parameters.size > 1
      TYPES.variant(*parameters)

    when "integer"
      if parameters.size == 1
        case parameters[0]
        when Integer
          TYPES.range(parameters[0], parameters[0])
        when :default
          TYPES.integer # unbound
        end
      elsif parameters.size != 2
        raise_invalid_parameters_error("Integer", "1 or 2", parameters.size)
     else
       TYPES.range(parameters[0] == :default ? nil : parameters[0], parameters[1] == :default ? nil : parameters[1])
     end

    when "float"
      if parameters.size == 1
        case parameters[0]
        when Integer, Float
          TYPES.float_range(parameters[0], parameters[0])
        when :default
          TYPES.float # unbound
        end
      elsif parameters.size != 2
        raise_invalid_parameters_error("Float", "1 or 2", parameters.size)
     else
       TYPES.float_range(parameters[0] == :default ? nil : parameters[0], parameters[1] == :default ? nil : parameters[1])
     end

    when "object", "collection", "data", "catalogentry", "boolean", "literal", "undef", "numeric", "pattern", "string"
      raise_unparameterized_type_error(parameterized_ast.left_expr)

    when "ruby", "type"
      # TODO: Add Stage, Node (they are not Resource Type)
      # should not be interpreted as Resource type
      raise_unknown_type_error(parameterized_ast.left_expr)

    else
      # It is a resource such a File['/tmp/foo']
      type_name = parameterized_ast.left_expr.value
      if parameters.size != 1
        raise_invalid_parameters_error(type_name.capitalize, 1, parameters.size)
      end
      TYPES.resource(type_name, parameters[0])
    end
  end

  private

  def assert_type(t)
    raise_invalid_type_specification_error unless t.is_a?(Puppet::Pops::Types::PObjectType)
  end

  def raise_invalid_type_specification_error
    raise Puppet::ParseError,
      "The expression <#{@string}> is not a valid type specification."
  end

  def raise_invalid_parameters_error(type, required, given)
    raise Puppet::ParseError,
      "Invalid number of type parameters specified: #{type} requires #{required}, #{given} provided"
  end
  def raise_unparameterized_type_error(ast)
    raise Puppet::ParseError, "Not a parameterized type <#{original_text_of(ast)}>"
  end

  def raise_unknown_type_error(ast)
    raise Puppet::ParseError, "Unknown type <#{original_text_of(ast)}>"
  end

  def original_text_of(ast)
    position = Puppet::Pops::Adapters::SourcePosAdapter.adapt(ast)
    position.extract_text_from_string(@string || position.locator.string)
  end
end
