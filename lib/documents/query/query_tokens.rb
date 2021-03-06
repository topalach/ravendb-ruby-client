require 'stringio'
require 'constants/documents'
require 'database/exceptions'
require 'utilities/string_utility'

module RavenDB
  class QueryToken
    QueryKeywords = [
      QueryKeyword::As,
      QueryKeyword::Select,
      QueryKeyword::Where,
      QueryKeyword::Load,
      QueryKeyword::Group,
      QueryKeyword::Order,
      QueryKeyword::Include
    ]

    def write_to(writer)
      raise NotImplementedError, "You should implement write_to method"
    end

    protected
    def write_field(writer, field)
      is_keyword = QueryKeywords.include?(field)

      is_keyword && writer.append("''")
      writer.append(field)
      is_keyword && writer.append("''")
    end
  end

  class SimpleQueryToken
    def self.instance
      self.new
    end

    def write_to(writer)
      writer.append(token_text)
    end

    protected
    def token_text
      raise NotImplementedError, "You should implement token_text method"
    end
  end

  class CloseSubclauseToken < SimpleQueryToken
    protected
    def token_text
      ")"
    end
  end

  class DistinctToken < SimpleQueryToken
    protected
    def token_text
      QueryKeyword::Distinct
    end
  end

  class FieldsToFetchToken < QueryToken
    attr_reader :fields_to_fetch, :projections

    def self.create(fields_to_fetch, projections = [])
      self.new(fields_to_fetch, projections)
    end

    def initialize(fields_to_fetch, projections = [])
      super()

      raise ArgumentError,
        "Fields list can't be empty" if
        fields_to_fetch.empty?

      raise ArgumentError,
        "Length of projections must be the "\
        "same as length of fields to fetch." if
        (projections.empty? && projections.size != fields_to_fetch.size)

      @fields_to_fetch = fields_to_fetch
      @projections = projections
    end

    def write_to(writer)
      @fields_to_fetch.each_index do |index|
        field = @fields_to_fetch[index]
        projection = @projections[index]

        if index > 0
          writer.append(", ")
        end

        write_field(writer, field)

        unless projection.nil? || (projection == field)
          writer.append(" ")
          writer.append(QueryKeyword::As)
          writer.append(" ")
          writer.append(projection)
        end
      end
    end
  end

  class FromToken < QueryToken
    attr_reader :index_name, :collection_name, :is_dynamic

    WhiteSpaceChars = [
      " ", "\t", "\r", "\n", "\v"
    ]

    def self.create(index_name = nil, collection_name = nil)
      self.new(index_name, collection_name)
    end

    def initialize(index_name = nil, collection_name = nil)
      super()

      @collection_name = collection_name
      @index_name = index_name
      @is_dynamic = !collection_name.nil?
    end

    def write_to(writer)
      raise NotSupportedException,
        "Either IndexName or CollectionName must be specified" if
        (@collection_name.nil? && @index_name.nil?)

      if @is_dynamic
        writer
          .append(QueryKeyword::From)
          .append(' ')

        if WhiteSpaceChars.any? {|char| @collection_name.include?(char)}
          raise NotSupportedException,
            "Collection name cannot contain a quote, but was: #{@collection_name}" if
            @collection_name.include?('"')

          writer.append('"').append(@collection_name).append('"')
        else
          writer.append(@collection_name)
        end

        return
      end

      writer
        .append(QueryKeyword::From)
        .append(' ')
        .append(QueryKeyword::Index)
        .append(" '")
        .append(@index_name)
        .append("'")
    end
  end

  class GroupByCountToken < QueryToken
    def self.create(field_name = nil)
      self.new(field_name)
    end

    def initialize(field_name = nil)
      super()

      @field_name = field_name
    end

    def write_to(writer)
      writer.append("count()")

      if @field_name.nil?
        return
      end

      writer
        .append(" ")
        .append(QueryKeyword::As)
        .append(" ")
        .append(@field_name)
    end
  end

  class GroupByKeyToken < GroupByCountToken
    def self.create(field_name = nil, projected_name = nil)
      self.new(field_name, projected_name)
    end

    def initialize(field_name = nil, projected_name = nil)
      super(field_name)

      @projected_name = projected_name
    end

    def write_to(writer)
      write_field(writer, @field_name || "key()")

      if @projected_name.nil? || (@projected_name == @field_name)
        return
      end

      writer
        .append(" ")
        .append(QueryKeyword::As)
        .append(" ")
        .append(@projected_name)
    end
  end

  class GroupBySumToken < GroupByKeyToken
    def initialize(field_name = nil, projected_name = nil)
      super(field_name, projected_name)

      raise ArgumentError,
        "Field name can't be null" if
        field_name.nil?
    end

    def write_to(writer)
      writer
          .append("sum(")
          .append(@field_name)
          .append(")")

      if @projected_name.nil?
          return
      end

      writer
          .append(" ")
          .append(QueryKeyword::As)
          .append(" ")
          .append(@projected_name)
    end
  end

  class GroupByToken < GroupByCountToken
    def initialize(field_name = nil)
      super(field_name)

      raise ArgumentError,
        "Field name can't be null" if
        field_name.nil?
    end

    def write_to(writer)
      write_field(writer, @field_name)
    end
  end

  class IntersectMarkerToken < SimpleQueryToken
    protected
    def token_text
      ","
    end
  end

  class NegateToken < SimpleQueryToken
    protected
    def token_text
      QueryOperator::Not
    end
  end

  class OpenSubclauseToken < SimpleQueryToken
    protected
    def token_text
      "("
    end
  end

  class OrderByToken < QueryToken
    def self.random
      self.new("random()")
    end

    def self.score_ascending
      self.new("score()")
    end

    def self.score_descending
      self.new("score()", true)
    end

    def self.create_distance_ascending(field_name, latitude_or_shape_wkt_parameter_name, longitude_parameter_name = nil)
      expression = longitude_parameter_name.nil? ?
        "distance(#{field_name}, wkt($#{latitude_or_shape_wkt_parameter_name}))" :
        "distance(#{field_name}, point($#{latitude_or_shape_wkt_parameter_name}, $#{longitude_parameter_name}))"

      self.new(expression)
    end

    def self.create_distance_descending(field_name, latitude_or_shape_wkt_parameter_name, longitude_parameter_name = nil)
      expression = longitude_parameter_name.nil? ?
        "distance(#{field_name}, wkt($#{latitude_or_shape_wkt_parameter_name}))" :
        "distance(#{field_name}, point($#{latitude_or_shape_wkt_parameter_name}, $#{longitude_parameter_name}))"

      self.new(expression, true)
    end

    def self.create_random(seed)
      raise ArgumentError,
        "Seed can't be null" if
        seed.nil?

      self.new("random('#{seed.gsub("'", "''")}')")
    end

    def self.create_ascending(field_name, ordering = OrderingType::String)
      self.new(field_name, false, ordering)
    end

    def self.create_descending(field_name, ordering = OrderingType::String)
      self.new(field_name, true, ordering)
    end

    def initialize(field_name, descending = false, ordering = OrderingType::String)
      super()

      @field_name = field_name
      @descending = descending
      @ordering = ordering
    end

    def write_to(writer)
      write_field(writer, @field_name)

      if !@ordering.nil? && (OrderingType::String != @ordering)
        writer
          .append(" ")
          .append(QueryKeyword::As)
          .append(" ")
          .append(@ordering)
      end

      if @descending
        writer
          .append(" ")
          .append(QueryKeyword::Desc)
      end
    end
  end

  class QueryOperatorToken < QueryToken
    def self.and
      self.new(QueryOperator::And)
    end

    def self.or
      self.new(QueryOperator::Or)
    end

    def initialize(query_operator)
      @query_operator = query_operator
    end

    def write_to(writer)
      writer.append(@query_operator)
    end
  end

  class ShapeToken < QueryToken
    def self.circle(radius_parameter_name, latitute_parameter_name, longitude_parameter_name, radius_units = nil)
      expression = radius_units.nil? ?
        "circle($#{radius_parameter_name}, $#{latitute_parameter_name}, $#{longitude_parameter_name})" :
        "circle($#{radius_parameter_name}, $#{latitute_parameter_name}, $#{longitude_parameter_name}, '#{radius_units}')"

      self.new(expression)
    end

    def self.wkt(shape_wkt_parameter_name)
      self.new("wkt($#{shape_wkt_parameter_name})")
    end

    def initialize(shape)
      @shape = shape
    end

    def write_to(writer)
      writer.append(@shape)
    end
  end

  class TrueToken < SimpleQueryToken
    protected
    def token_text
      true.to_s
    end
  end

  class WhereToken < QueryToken
    attr_accessor :boost, :fuzzy, :proximity
    attr_reader :field_name, :where_operator, :search_operator,
                :parameter_name, :from_parameter_name, :to_parameter_name,
                :exact, :where_shape, :distance_error_pct

    def self.equals(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::Equals
      })
    end

    def self.not_equals(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::NotEquals
      })
    end

    def self.starts_with(field_name, parameter_name)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :where_operator => WhereOperator::StartsWith
      })
    end

    def self.ends_with(field_name, parameter_name)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :where_operator => WhereOperator::EndsWith
      })
    end

    def self.greater_than(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::GreaterThan
      })
    end

    def self.greater_than_or_equal(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::GreaterThanOrEqual
      })
    end

    def self.less_than(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::LessThan
      })
    end

    def self.less_than_or_equal(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::LessThanOrEqual
      })
    end

    def self.in(field_name, parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::In
      })
    end

    def self.all_in(field_name, parameter_name)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :where_operator => WhereOperator::AllIn
      })
    end

    def self.between(field_name, from_parameter_name, to_parameter_name, exact = false)
      self.new({
        :field_name => field_name,
        :from_parameter_name => from_parameter_name,
        :to_parameter_name => to_parameter_name,
        :exact => exact,
        :where_operator => WhereOperator::Between
      })
    end

    def self.search(field_name, parameter_name, op = SearchOperator::And)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :search_operator => op,
        :where_operator => WhereOperator::Search
      })
    end

    def self.lucene(field_name, parameter_name)
      self.new({
        :field_name => field_name,
        :parameter_name => parameter_name,
        :where_operator => WhereOperator::Lucene
      })
    end

    def self.exists(field_name)
      self.new({
        :field_name => field_name,
        :where_operator => WhereOperator::Exists
      })
    end

    def self.within(field_name, shape, distance_error_pct)
      self.new({
        :field_name => field_name,
        :where_shape => shape,
        :distance_error_pct => distance_error_pct,
        :where_operator => WhereOperator::Within
      })
    end

    def self.contains(field_name, shape, distance_error_pct)
      self.new({
        :field_name => field_name,
        :where_shape => shape,
        :distance_error_pct => distance_error_pct,
        :where_operator => WhereOperator::Contains
      })
    end

    def self.disjoint(field_name, shape, distance_error_pct)
      self.new({
        :field_name => field_name,
        :where_shape => shape,
        :distance_error_pct => distance_error_pct,
        :where_operator => WhereOperator::Disjoint
      })
    end

    def self.intersects(field_name, shape, distance_error_pct)
      self.new({
        :field_name => field_name,
        :where_shape => shape,
        :distance_error_pct => distance_error_pct,
        :where_operator => WhereOperator::Intersects
      })
    end

    def initialize(where_options)
      super()

      @boost = nil
      @fuzzy = nil
      @proximity = nil
      @field_name = where_options[:field_name]
      @where_operator = where_options[:where_operator]
      @search_operator = where_options[:search_operator] || nil
      @parameter_name = where_options[:parameter_name] || nil
      @from_parameter_name = where_options[:from_parameter_name] || nil
      @to_parameter_name = where_options[:to_parameter_name] || nil
      @exact = where_options[:exact] || false
      @distance_error_pct = where_options[:distance_error_pct] || nil
      @where_shape = where_options[:where_shape] || nil
    end

    def write_to(writer)
      unless @boost.nil?
        writer.append("boost(")
      end

      unless @fuzzy.nil?
        writer.append("fuzzy(")
      end

      unless @proximity.nil?
        writer.append("proximity(")
      end

      if @exact
        writer.append("exact(")
      end

      case @where_operator
        when WhereOperator::Search,
             WhereOperator::Lucene,
             WhereOperator::StartsWith,
             WhereOperator::EndsWith,
             WhereOperator::Exists,
             WhereOperator::Within,
             WhereOperator::Contains,
             WhereOperator::Disjoint,
             WhereOperator::Intersects
          writer
            .append(@where_operator)
            .append("(")
      end

      write_field(writer, @field_name)

      case @where_operator
        when WhereOperator::In
          writer
            .append(" ")
            .append(QueryKeyword::In)
            .append(" ($")
            .append(@parameter_name)
            .append(")")
        when WhereOperator::AllIn
          writer
            .append(" ")
            .append(QueryKeyword::All)
            .append(" ")
            .append(QueryKeyword::In)
            .append(" ($")
            .append(@parameter_name)
            .append(")")
        when WhereOperator::Between
          writer
            .append(" ")
            .append(QueryKeyword::Between)
            .append(" $")
            .append(@from_parameter_name)
            .append(" ")
            .append(QueryOperator::And)
            .append(" $")
            .append(@to_parameter_name)
        when WhereOperator::Equals
          writer
            .append(" = $")
            .append(@parameter_name)
        when WhereOperator::NotEquals
          writer
            .append(" != $")
            .append(@parameter_name)
        when WhereOperator::GreaterThan
          writer
            .append(" > $")
            .append(@parameter_name)
        when WhereOperator::GreaterThanOrEqual
          writer
            .append(" >= $")
            .append(@parameter_name)
        when WhereOperator::LessThan
          writer
            .append(" < $")
            .append(@parameter_name)
        when WhereOperator::LessThanOrEqual
          writer
            .append(" <= $")
            .append(@parameter_name)
        when WhereOperator::Search
          writer
            .append(", $")
            .append(@parameter_name)

          if @search_operator === SearchOperator::And
            writer
              .append(", ")
              .append(@search_operator)
          end

          writer.append(")")
        when WhereOperator::Lucene,
             WhereOperator::StartsWith,
             WhereOperator::EndsWith
          writer
            .append(", $")
            .append(@parameter_name)
            .append(")")
        when WhereOperator::Exists
          writer
            .append(")")
        when WhereOperator::Within,
             WhereOperator::Contains,
             WhereOperator::Disjoint,
             WhereOperator::Intersects
          writer
            .append(", ")

          @where_shape.write_to(writer)

          if (@distance_error_pct.to_f - SpatialConstants::DefaultDistanceErrorPct).abs > Float::EPSILON
            writer.append(", ")
            writer.append(@distance_error_pct.to_s)
          end

          writer
            .append(")")
        else
          raise IndexError, "Invalid where operator provided"
      end

      if @exact
        writer.append(")")
      end

      unless @proximity.nil?
        writer
          .append(", ")
          .append(@proximity.to_s)
          .append(")")
      end

      unless @fuzzy.nil?
        writer
          .append(", ")
          .append(@fuzzy.to_s)
          .append(")")
      end

      unless @boost.nil?
        writer
          .append(", ")
          .append(@boost.to_s)
          .append(")")
      end
    end
  end
end