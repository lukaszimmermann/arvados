# Copyright (C) The Arvados Authors. All rights reserved.
#
# SPDX-License-Identifier: AGPL-3.0

require "arvados/keep"
require "arvados/collection"
require "uri"

class CollectionsController < ApplicationController
  include ActionController::Live

  skip_around_filter :require_thread_api_token, if: proc { |ctrl|
    Rails.configuration.anonymous_user_token and
    'show' == ctrl.action_name
  }
  skip_around_filter(:require_thread_api_token,
                     only: [:show_file, :show_file_links])
  skip_before_filter(:find_object_by_uuid,
                     only: [:provenance, :show_file, :show_file_links])
  # We depend on show_file to display the user agreement:
  skip_before_filter :check_user_agreements, only: :show_file
  skip_before_filter :check_user_profile, only: :show_file

  RELATION_LIMIT = 5

  def show_pane_list
    panes = %w(Files Upload Tags Provenance_graph Used_by Advanced)
    panes = panes - %w(Upload) unless (@object.editable? rescue false)
    panes
  end

  def set_persistent
    case params[:value]
    when 'persistent', 'cache'
      persist_links = Link.filter([['owner_uuid', '=', current_user.uuid],
                                   ['link_class', '=', 'resources'],
                                   ['name', '=', 'wants'],
                                   ['tail_uuid', '=', current_user.uuid],
                                   ['head_uuid', '=', @object.uuid]])
      logger.debug persist_links.inspect
    else
      return unprocessable "Invalid value #{value.inspect}"
    end
    if params[:value] == 'persistent'
      if not persist_links.any?
        Link.create(link_class: 'resources',
                    name: 'wants',
                    tail_uuid: current_user.uuid,
                    head_uuid: @object.uuid)
      end
    else
      persist_links.each do |link|
        link.destroy || raise
      end
    end

    respond_to do |f|
      f.json { render json: @object }
    end
  end

  def index
    # API server index doesn't return manifest_text by default, but our
    # callers want it unless otherwise specified.
    @select ||= Collection.columns.map(&:name)
    base_search = Collection.select(@select)
    if params[:search].andand.length.andand > 0
      tags = Link.where(any: ['contains', params[:search]])
      @objects = (base_search.where(uuid: tags.collect(&:head_uuid)) |
                      base_search.where(any: ['contains', params[:search]])).
        uniq { |c| c.uuid }
    else
      if params[:limit]
        limit = params[:limit].to_i
      else
        limit = 100
      end

      if params[:offset]
        offset = params[:offset].to_i
      else
        offset = 0
      end

      @objects = base_search.limit(limit).offset(offset)
    end
    @links = Link.where(head_uuid: @objects.collect(&:uuid))
    @collection_info = {}
    @objects.each do |c|
      @collection_info[c.uuid] = {
        tag_links: [],
        wanted: false,
        wanted_by_me: false,
        provenance: [],
        links: []
      }
    end
    @links.each do |link|
      @collection_info[link.head_uuid] ||= {}
      info = @collection_info[link.head_uuid]
      case link.link_class
      when 'tag'
        info[:tag_links] << link
      when 'resources'
        info[:wanted] = true
        info[:wanted_by_me] ||= link.tail_uuid == current_user.uuid
      when 'provenance'
        info[:provenance] << link.name
      end
      info[:links] << link
    end
    @request_url = request.url

    render_index
  end

  def show_file_links
    return show_file
  end

  def show_file
    # The order of searched tokens is important: because the anonymous user
    # token is passed along with every API request, we have to check it first.
    # Otherwise, it's impossible to know whether any other request succeeded
    # because of the reader token.
    coll = nil
    tokens = [(Rails.configuration.anonymous_user_token || nil),
              params[:reader_token],
              Thread.current[:arvados_api_token]].compact
    usable_token = find_usable_token(tokens) do
      coll = Collection.find(params[:uuid])
    end
    if usable_token.nil?
      # Response already rendered.
      return
    end

    opts = {}
    if usable_token == params[:reader_token]
      opts[:path_token] = usable_token
    elsif usable_token == Rails.configuration.anonymous_user_token
      # Don't pass a token at all
    else
      # We pass the current user's real token only if it's necessary
      # to read the collection.
      opts[:query_token] = usable_token
    end
    opts[:disposition] = params[:disposition] if params[:disposition]
    return redirect_to keep_web_url(params[:uuid], params[:file], opts)
  end

  def sharing_scopes
    ["GET /arvados/v1/collections/#{@object.uuid}", "GET /arvados/v1/collections/#{@object.uuid}/", "GET /arvados/v1/keep_services/accessible"]
  end

  def search_scopes
    begin
      ApiClientAuthorization.filter([['scopes', '=', sharing_scopes]]).results
    rescue ArvadosApiClient::AccessForbiddenException
      nil
    end
  end

  def find_object_by_uuid
    if not Keep::Locator.parse params[:id]
      super
    end
  end

  def show
    return super if !@object

    @logs = []

    if params["tab_pane"] == "Provenance_graph"
      @prov_svg = ProvenanceHelper::create_provenance_graph(@object.provenance, "provenance_svg",
                                                            {:request => request,
                                                             :direction => :top_down,
                                                             :combine_jobs => :script_only}) rescue nil
    end

    if current_user
      if Keep::Locator.parse params["uuid"]
        @same_pdh = Collection.filter([["portable_data_hash", "=", @object.portable_data_hash]]).limit(20)
        if @same_pdh.results.size == 1
          redirect_to collection_path(@same_pdh[0]["uuid"])
          return
        end
        owners = @same_pdh.map(&:owner_uuid).to_a.uniq
        preload_objects_for_dataclass Group, owners
        preload_objects_for_dataclass User, owners
        uuids = @same_pdh.map(&:uuid).to_a.uniq
        preload_links_for_objects uuids
        render 'hash_matches'
        return
      else
        if Job.api_exists?(:index)
          jobs_with = lambda do |conds|
            Job.limit(RELATION_LIMIT).where(conds)
              .results.sort_by { |j| j.finished_at || j.created_at }
          end
          @output_of = jobs_with.call(output: @object.portable_data_hash)
          @log_of = jobs_with.call(log: @object.portable_data_hash)
        end

        @project_links = Link.limit(RELATION_LIMIT).order("modified_at DESC")
          .where(head_uuid: @object.uuid, link_class: 'name').results
        project_hash = Group.where(uuid: @project_links.map(&:tail_uuid)).to_hash
        @projects = project_hash.values

        @permissions = Link.limit(RELATION_LIMIT).order("modified_at DESC")
          .where(head_uuid: @object.uuid, link_class: 'permission',
                 name: 'can_read').results
        @search_sharing = search_scopes

        if params["tab_pane"] == "Used_by"
          @used_by_svg = ProvenanceHelper::create_provenance_graph(@object.used_by, "used_by_svg",
                                                                   {:request => request,
                                                                    :direction => :top_down,
                                                                    :combine_jobs => :script_only,
                                                                    :pdata_only => true}) rescue nil
        end
      end
    end
    super
  end

  def sharing_popup
    @search_sharing = search_scopes
    render("sharing_popup.js", content_type: "text/javascript")
  end

  helper_method :download_link

  def download_link
    token = @search_sharing.first.api_token
    keep_web_url(@object.uuid, nil, {path_token: token})
  end

  def share
    ApiClientAuthorization.create(scopes: sharing_scopes)
    sharing_popup
  end

  def unshare
    search_scopes.each do |s|
      s.destroy
    end
    sharing_popup
  end

  def remove_selected_files
    uuids, source_paths = selected_collection_files params

    arv_coll = Arv::Collection.new(@object.manifest_text)
    source_paths[uuids[0]].each do |p|
      arv_coll.rm "."+p
    end

    if @object.update_attributes manifest_text: arv_coll.manifest_text
      show
    else
      self.render_error status: 422
    end
  end

  def update
    updated_attr = params[:collection].each.select {|a| a[0].andand.start_with? 'rename-file-path:'}

    if updated_attr.size > 0
      # Is it file rename?
      file_path = updated_attr[0][0].split('rename-file-path:')[-1]

      new_file_path = updated_attr[0][1]
      if new_file_path.start_with?('./')
        # looks good
      elsif new_file_path.start_with?('/')
        new_file_path = '.' + new_file_path
      else
        new_file_path = './' + new_file_path
      end

      arv_coll = Arv::Collection.new(@object.manifest_text)

      if arv_coll.exist?(new_file_path)
        @errors = 'Duplicate file path. Please use a different name.'
        self.render_error status: 422
      else
        arv_coll.rename "./"+file_path, new_file_path

        if @object.update_attributes manifest_text: arv_coll.manifest_text
          show
        else
          self.render_error status: 422
        end
      end
    else
      # Not a file rename; use default
      super
    end
  end

  def tags
    render
  end

  def save_tags
    tags_param = params['tag_data']
    if tags_param
      if tags_param.is_a?(String) && tags_param == "empty"
        tags = {}
      else
        tags = tags_param
      end
    end

    if tags
      if @object.update_attributes properties: tags
        @saved_tags = true
        render
      else
        self.render_error status: 422
      end
    end
  end

  protected

  def find_usable_token(token_list)
    # Iterate over every given token to make it the current token and
    # yield the given block.
    # If the block succeeds, return the token it used.
    # Otherwise, render an error response based on the most specific
    # error we encounter, and return nil.
    most_specific_error = [401]
    token_list.each do |api_token|
      begin
        # We can't load the corresponding user, because the token may not
        # be scoped for that.
        using_specific_api_token(api_token, load_user: false) do
          yield
          return api_token
        end
      rescue ArvadosApiClient::ApiError => error
        if error.api_status >= most_specific_error.first
          most_specific_error = [error.api_status, error]
        end
      end
    end
    case most_specific_error.shift
    when 401, 403
      redirect_to_login
    when 404
      render_not_found(*most_specific_error)
    end
    return nil
  end

  def keep_web_url(uuid_or_pdh, file, opts)
    munged_id = uuid_or_pdh.sub('+', '-')
    fmt = {uuid_or_pdh: munged_id}

    tmpl = Rails.configuration.keep_web_url
    if Rails.configuration.keep_web_download_url and
        (!tmpl or opts[:disposition] == 'attachment')
      # Prefer the attachment-only-host when we want an attachment
      # (and when there is no preview link configured)
      tmpl = Rails.configuration.keep_web_download_url
    elsif not Rails.configuration.trust_all_content
      check_uri = URI.parse(tmpl % fmt)
      if opts[:query_token] and
          not check_uri.host.start_with?(munged_id + "--") and
          not check_uri.host.start_with?(munged_id + ".")
        # We're about to pass a token in the query string, but
        # keep-web can't accept that safely at a single-origin URL
        # template (unless it's -attachment-only-host).
        tmpl = Rails.configuration.keep_web_download_url
        if not tmpl
          raise ArgumentError, "Download precluded by site configuration"
        end
        logger.warn("Using download link, even though inline content " \
                    "was requested: #{check_uri.to_s}")
      end
    end

    if tmpl == Rails.configuration.keep_web_download_url
      # This takes us to keep-web's -attachment-only-host so there is
      # no need to add ?disposition=attachment.
      opts.delete :disposition
    end

    uri = URI.parse(tmpl % fmt)
    uri.path += '/' unless uri.path.end_with? '/'
    if opts[:path_token]
      uri.path += 't=' + opts[:path_token] + '/'
    end
    uri.path += '_/'
    uri.path += URI.escape(file) if file

    query = Hash[URI.decode_www_form(uri.query || '')]
    { query_token: 'api_token',
      disposition: 'disposition' }.each do |opt, param|
      if opts.include? opt
        query[param] = opts[opt]
      end
    end
    unless query.empty?
      uri.query = URI.encode_www_form(query)
    end

    uri.to_s
  end
end
