require 'active_support/core_ext/object/deep_dup'
require 'net/http'
require 'database/exceptions'
require 'documents/conventions'
require 'constants/documents'
require 'database/commands'
require 'documents/document_query'
require 'utilities/type_utilities'
require 'utilities/observable'

module RavenDB
  class DocumentSession
    include Observable

    attr_reader :number_of_requests_in_session

    def initialize(db_name, document_store, id, request_executor)
      @advanced = nil
      @database = db_name
      @document_store = document_store
      @session_id = id
      @request_executor = request_executor
      @documents_by_id = {}
      @included_raw_entities_by_id = {}
      @deleted_documents = Set.new([])
      @raw_entities_and_metadata = {}
      @known_missing_ids = Set.new([])
      @defer_commands = Set.new([])
      @attached_queries = {}
      @number_of_requests_in_session = 0

      on(RavenServerEvent::EVENT_QUERY_INITIALIZED) {|query|
        attach_query(query)
      }
    end

    def conventions
      @document_store.conventions
    end

    def advanced
      if !@advanced
        @advanced = AdvancedSessionOperations.new(self, @request_executor)
        @advanced.on(RavenServerEvent::EVENT_QUERY_INITIALIZED) {|query|
          attach_query(query)
        }
      end

      @advanced
    end

    def load(id_or_ids, options = nil)
      includes = nil
      ids = id_or_ids
      nested_object_types = {}
      loading_one_doc = !id_or_ids.is_a?(Array)

      if loading_one_doc
        ids = [id_or_ids]
      end

      if options.is_a?(Hash)
        includes = options[:includes] || nil
        nested_object_types = options[:nested_object_types] || {}
      end

      ids_of_non_existing_documents  = Set.new(ids)

      if !includes.nil? && !includes.is_a?(Array)
        if includes.is_a?(String)
          includes = [includes]
        else
          includes = nil
        end
      end

      if includes.nil?
        ids_of_non_existing_documents
          .to_a
          .keep_if{|id| @included_raw_entities_by_id.key?(id)}
          .each do |id|
          make_document(@included_raw_entities_by_id[id], nil, nested_object_types)
          @included_raw_entities_by_id.delete(id)
        end

        ids_of_non_existing_documents = Set.new(
          ids.deep_dup
          .delete_if{|id| @documents_by_id.key?(id)}
        )
      end

      ids_of_non_existing_documents = Set.new(
        ids_of_non_existing_documents.to_a
        .delete_if{|id| @known_missing_ids.include?(id)}
      )

      if !ids_of_non_existing_documents.empty?
        fetch_documents(ids_of_non_existing_documents.to_a, includes, nested_object_types)
      end

      results = ids.map {|id| (!@known_missing_ids.include?(id) &&
          @documents_by_id.key?(id)) ? @documents_by_id[id] : nil
      }

      if loading_one_doc
        return results.first
      end

      results
    end

    def delete(document_or_id, options = nil)
      id = nil
      info = nil
      document = nil
      expected_change_vector = nil

      raise RuntimeError,
        'Invalid argument passed. Should be document model instance or document id string' unless
        (document_or_id.is_a?(String) || TypeUtilities::is_document?(document_or_id))

      if options.is_a?(Hash)
        expected_change_vector = options[:expected_change_vector] || nil
      end

      if document_or_id.is_a?(String)
        id = document_or_id

        if @documents_by_id.key?(id) && is_document_changed(@documents_by_id[id])
          raise RuntimeError,
            "Can't delete changed document using identifier. Pass document instance instead"
        end
      else
        document = document_or_id
        info = @raw_entities_and_metadata[document]
        id = conventions.get_id_from_document(document)
      end

      if document.nil?
        @defer_commands.add(DeleteCommandData.new(id, expected_change_vector))
      else
        raise RuntimeError,
          "Document is not associated with the session, cannot delete unknown document instance" unless
          @raw_entities_and_metadata.key?(document)

        id = info[:id]
        original_metadata = info[:original_metadata]

        raise RuntimeError,
          "Document is marked as read only and cannot be deleted" if
          original_metadata.key?('Raven-Read-Only')

        unless expected_change_vector.nil?
          info[:expected_change_vector] = expected_change_vector
          @raw_entities_and_metadata[document] = info
        end

        @deleted_documents.add(document)
      end

      @known_missing_ids.add(id)
      @included_raw_entities_by_id.delete(id)

      document || nil
    end

    def store(document, id = nil, options = nil)
      change_vector = nil

      if options.is_a?(Hash)
        change_vector = options[:expected_change_vector]
      end

      document = check_document_and_metadata_before_store(document)
      check_result = check_association_and_change_vectore_before_store(document, id, change_vector)
      document = check_result[:document]
      is_new_document = check_result[:is_new]

      if is_new_document
        original_metadata = document.instance_variable_get('@metadata').deep_dup
        document = prepare_document_id_before_store(document, id)
        id = conventions.get_id_from_document(document)

        @defer_commands.each {|command| raise RuntimeError,
          "Can't store document, there is a deferred command registered "\
          "for this document in the session. Document id: #{id}" if
          id == command.document_id
        }

        raise RuntimeError,
          "Can't store object, it was already deleted in this "\
          "session. Document id: #{id}" if
          @deleted_documents.include?(document)

        on_document_fetched({
          :document => document,
          :metadata => document.instance_variable_get('@metadata'),
          :original_metadata => original_metadata,
          :raw_entity => conventions.convert_to_raw_entity(document)
        })
      end

      document
    end

    def save_changes
      changes = SaveChangesData.new(@defer_commands.to_a, @defer_commands.size)

      @defer_commands.clear
      prepare_delete_commands(changes)
      prepare_update_commands(changes)

      if !changes.commands_count
        return nil
      end

      results = @request_executor.execute(changes.create_batch_command)

      if !results
        raise RuntimeError.new, "Cannot call Save Changes after the document store was disposed."
      end

      process_batch_command_results(results, changes)
    end

    def query(options = nil)
      document_query = DocumentQuery.create(self, @request_executor, options)

      emit(RavenServerEvent::EVENT_QUERY_INITIALIZED, document_query)

      document_query
    end

    protected
    def attach_query(query)
      if @attached_queries.key?(query)
        raise RuntimeError, 'Query is already attached to session'
      end

      query.on(RavenServerEvent::EVENT_DOCUMENTS_QUERIED) {
        increment_requests_count
      }

      query.on(RavenServerEvent::EVENT_DOCUMENT_FETCHED) {|conversion_result|
        on_document_fetched(conversion_result)
      }

      query.on(RavenServerEvent::EVENT_INCLUDES_FETCHED) {|includes|
        on_includes_fetched(includes)
      }

      @attached_queries[query] = true
    end

    def increment_requests_count
      max_requests = DocumentConventions::MaxNumberOfRequestPerSession

      @number_of_requests_in_session = @number_of_requests_in_session + 1

      raise RuntimeError,
          "The maximum number of requests (#{max_requests}) allowed for this session has been reached. Raven limits the number "\
"of remote calls that a session is allowed to make as an early warning system. Sessions are expected to "\
"be short lived, and Raven provides facilities like batch saves (call save_changes only once) "\
"You can increase the limit by setting RavenDB::DocumentConventions::"\
"MaxNumberOfRequestPerSession, but it is advisable "\
"that you'll look into reducing the number of remote calls first, "\
"since that will speed up your application significantly and result in a"\
"more responsive application." unless @number_of_requests_in_session <= max_requests
    end

    def fetch_documents(ids, includes = nil, nested_object_types = {})
      response_results = []
      response_includes = []
      increment_requests_count

      response = @request_executor.execute(GetDocumentCommand.new(ids, includes))

      if response
        response_results = conventions.try_fetch_results(response)
        response_includes = conventions.try_fetch_includes(response)
      end

      response_results.map.with_index do |result, index|
        if !result
            @known_missing_ids.add(ids[index])
            return nil
        end

        make_document(result, nil, nested_object_types)
      end

      if !response_includes.empty?
        on_includes_fetched(response_includes)
      end
    end

    def check_document_and_metadata_before_store(document = nil)
      if !TypeUtilities::is_document?(document)
        raise RuntimeError, 'Invalid argument passed. Should be an document'
      end

      if !@raw_entities_and_metadata.key?(document)
        document.instance_variable_set('@metadata', conventions.build_default_metadata(document))
      end

      document
    end

    def check_association_and_change_vectore_before_store(document, id = nil, change_vector = nil)
      is_new = !@raw_entities_and_metadata.key?(document)

      if !is_new
        document_id = id
        info = @raw_entities_and_metadata[document]
        metadata = document.instance_variable_get('@metadata')
        check_mode = ConcurrencyCheckMode::Forced

        if document_id.nil?
          document_id = conventions.get_id_from_document(document)
        end

        if change_vector.nil?
          check_mode = ConcurrencyCheckMode::Disabled
        else
          info[:change_vector] = metadata['@change-vector'] = change_vector

          if !document_id.nil?
            check_mode = ConcurrencyCheckMode::Auto
          end
        end

        info[:concurrency_check_mode] = check_mode
        @raw_entities_and_metadata[document] = info
      end

      {:document => document, :is_new => is_new}
    end

    def prepare_document_id_before_store(document, id = nil)
      store = @document_store
      document_id = id

      if document_id.nil?
        document_id = conventions.get_id_from_document(document)
      end

      if !document_id.nil?
        conventions.set_id_on_document(document, document_id)
      end

      if !document_id.nil? && !document_id.end_with?('/') && @documents_by_id.key?(document_id)
        if !@documents_by_id[document_id].eql?(document)
          raise NonUniqueObjectException, "Attempted to associate a different object with id #{document_id}"
        end
      end

      if document_id.nil? || document_id.end_with?('/')
        document_type = conventions.get_type_from_document(document)
        document_id = store.generate_id(conventions.get_collection_name(document_type), @database)
        conventions.set_id_on_document(document, document_id)
      end

      document
    end

    def prepare_update_commands(changes)
      @raw_entities_and_metadata.each do |document, info|
        if !is_document_changed(document)
          return nil
        end

        id = info[:id]
        change_vector = nil
        raw_entity = conventions.convert_to_raw_entity(document)

        if (DocumentConventions::DefaultUseOptimisticConcurrency &&
          (ConcurrencyCheckMode::Disabled != info[:concurrency_check_mode])) ||
          (ConcurrencyCheckMode::Forced == info[:concurrency_check_mode])
          change_vector = info[:change_vector] ||
              info[:metadata]['@change-vector'] ||
              conventions.empty_change_vector
        end

        @documents_by_id.delete(id)
        changes.add_document(document)
        changes.add_command(PutCommandData.new(id, raw_entity.deep_dup, change_vector))
      end
    end

    def prepare_delete_commands(changes)
      @deleted_documents.each do |document|
        change_vector = nil
        existing_document = document
        document_id = conventions.get_id_from_document(document)

        if @raw_entities_and_metadata.key?(document)
          info = @raw_entities_and_metadata[document]

          if @documents_by_id.key?(info[:id])
            document_id = info[:id]
            existing_document = @documents_by_id[document_id]
            @documents_by_id.delete(document_id)
          end

          if info.key?(:expected_change_vector)
            change_vector = info[:expected_change_vector]
          elsif DocumentConventions::DefaultUseOptimisticConcurrency
            change_vector = info[:change_vector] || info[:metadata]["@change-vector"]
          end

          @raw_entities_and_metadata.delete(document)
        end

        changes.add_document(existing_document)
        changes.add_command(DeleteCommandData.new(document_id, change_vector))
      end
    end

    def process_batch_command_results(results, changes)
      ((changes.deferred_commands_count)..(results.size - 1)).each do |index|
        command_result = results[index]

        if Net::HTTP::Put::METHOD.capitalize == command_result["Type"]
          document = changes.get_document(index - changes.deferred_commands_count)

          if @raw_entities_and_metadata.key?(document)
            metadata = TypeUtilities::omit_keys(command_result, ["Type"])
            info = @raw_entities_and_metadata[document]

            info = info.merge({
              :change_vector => command_result['@change-vector'],
              :metadata => metadata,
              :original_value => conventions.convert_to_raw_entity(document).deep_dup,
              :original_metadata => metadata.deep_dup
            })

            @documents_by_id[command_result["@id"]] = document
            @raw_entities_and_metadata[document] = info
          end
        end
      end
    end

    def is_document_changed(document)
      if !@raw_entities_and_metadata.key?(document)
        return false
      end

      info = @raw_entities_and_metadata[document]
      (info[:original_metadata] != info[:metadata]) ||
          (info[:original_value] != conventions.convert_to_raw_entity(document))
    end

    def make_document(command_result, document_type = nil, nested_object_types = nil)
      conversion_result = conventions.convert_to_document(command_result, document_type, nested_object_types)

      on_document_fetched(conversion_result)
      conversion_result[:document]
    end

    def on_includes_fetched(includes)
      if includes.is_a?(Array) && !includes.empty?
        includes.each do |include|
          document_id = include['@metadata']['@id']

          if !@included_raw_entities_by_id.key?(document_id)
            @included_raw_entities_by_id[document_id] = include
          end
        end
      end
    end

    def on_document_fetched(conversion_result = nil)
      if conversion_result.nil?
        return nil
      end

      document = conversion_result[:document]
      document_id = conventions.get_id_from_document(document) ||
        conversion_result[:original_metadata]['@id'] || conversion_result[:metadata]['@id']

      if !document_id
        return nil
      end

      @known_missing_ids.delete(document_id)

      if @documents_by_id.key?(document_id)
        return nil
      end

      original_value_source = conversion_result[:raw_entity]

      if !original_value_source
        original_value_source = conventions.convert_to_raw_entity(document)
      end

      @documents_by_id[document_id] = document
      @raw_entities_and_metadata[document] = {
        :original_value => original_value_source.deep_dup,
        :original_metadata => conversion_result[:original_metadata],
        :metadata => conversion_result[:metadata],
        :change_vector => conversion_result[:metadata]['@change-vector'] || nil,
        :id => document_id,
        :concurrency_check_mode => ConcurrencyCheckMode::Auto,
        :document_type => conversion_result[:document_type]
      }
    end
  end

  class AdvancedSessionOperations
    include Observable

    def initialize(document_session, request_executor)
      @session = document_session
      @request_executor = request_executor
    end

    def raw_query(query, params = {}, options = nil)
      document_query = RawDocumentQuery.create(@session, @request_executor, options)
      document_query.raw_query(query)

      if params.is_a?(Hash) && !params.empty?
        params.each {|param, value| document_query.add_parameter(param, value)}
      end

      emit(RavenServerEvent::EVENT_QUERY_INITIALIZED, document_query)

      document_query
    end
  end
end