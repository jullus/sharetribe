class LandingPageController < ActionController::Metal

  # Shorthand for accessing CustomLandingPage service namespace
  CLP = CustomLandingPage

  # Needed for rendering
  #
  # See Rendering Helpers: http://api.rubyonrails.org/classes/ActionController/Metal.html
  #
  include AbstractController::Rendering
  include ActionController::ConditionalGet
  include ActionView::Layouts
  append_view_path "#{Rails.root}/app/views"

  # Ensure ActiveSupport::Notifications events are fired
  include ActionController::Instrumentation

  # Include route helpers
  include Rails.application.routes.url_helpers

  # Adds helper_method
  include ActionController::Helpers

  include FeatureFlagHelper

  CACHE_TIME = APP_CONFIG[:clp_cache_time].to_i.seconds
  CACHE_HEADER = "X-CLP-Cache"
  FEATURE_FLAG = :landingpage_topbar

  FONT_PATH = APP_CONFIG[:font_proximanovasoft_url].present? ? APP_CONFIG[:font_proximanovasoft_url] : "/landing_page/fonts"

  helper_method :feature_flags

  def index
    cid = community(request).id
    default_locale = community(request).default_locale
    version = CLP::LandingPageStore.released_version(cid)
    locale_param = params[:locale]

    begin
      content = nil
      cache_meta = CLP::Caching.fetch_cache_meta(cid, version, locale_param)
      cache_hit = true

      if cache_meta.nil?
        cache_hit = false
        content = build_html(
          community_id: cid,
          default_locale: default_locale,
          locale_param: locale_param,
          version: version
        )
        cache_meta = CLP::Caching.cache_content!(
          cid, version, locale_param, content, CACHE_TIME)
      end

      if stale?(etag: cache_meta[:digest],
                last_modified: cache_meta[:last_modified],
                template: false,
                public: true)

        content = CLP::Caching.fetch_cached_content(cid, version, cache_meta[:digest])
        if content.nil?
          # This should not happen since html is cached longer than metadata
          cache_hit = false
          content = build_html(
            community_id: cid,
            default_locale: default_locale,
            locale_param: locale_param,
            version: version
          )
        end

        self.status = 200
        self.response_body = content
      end
      # There's an implicit else here because stale? has the
      # side-effect of setting response to HEAD 304 if we have a match
      # for conditional get.

      headers[CACHE_HEADER] = cache_hit ? "1" : "0"
      expires_in(CACHE_TIME, public: true)
    rescue CLP::LandingPageContentNotFound
      render_not_found()
    end
  end

  def preview
    cid = community(request).id
    default_locale = community(request).default_locale

    preview_version = parse_int(params[:preview_version])
    locale_param = params[:locale]

    begin
      structure = CLP::LandingPageStore.load_structure(cid, preview_version)

      # Uncomment to use static data instead of dynamic from DB
      # structure = JSON.parse(CustomLandingPage::ExampleData::DATA_STR)

      # Tell robots to not index and to not follow any links
      headers["X-Robots-Tag"] = "none"

      self.status = 200
      self.response_body = render_landing_page(
        default_locale: default_locale,
        locale_param: locale_param,
        structure: structure
      )
    rescue CLP::LandingPageContentNotFound
      render_not_found()
    end
  end


  private

  # Override basic instrumentation and provide additional info for
  # lograge to consume. These are pulled and logged in environment
  # configs.
  def append_info_to_payload(payload)
    super
    payload[:host] = request.host
    payload[:community_id] = community(request)&.id
    payload[:current_user_id] = nil
    payload[:request_uuid] = request.uuid
  end

  def initialize_i18n!(cid, locale)
    I18nHelper.initialize_community_backend!(cid, [locale])
  end

  def build_html(community_id:, default_locale:, locale_param:, version:)
    structure = CLP::LandingPageStore.load_structure(community_id, version)
    render_landing_page(
      default_locale: default_locale,
      structure: structure,
      locale_param: locale_param
    )
  end

  def build_denormalizer(cid:, default_locale:, locale_param:, landing_page_locale:, sitename:)
    search_path = ->(opts = {}) {
      PathHelpers.search_path(
        community_id: cid,
        logged_in: false,
        locale_param: locale_param,
        default_locale: default_locale,
        opts: opts
      )
    }

    # Application paths
    paths = { "search" => search_path.call(),
              "all_categories" => search_path.call(category: "all"),
              "signup" => sign_up_path(locale: locale_param),
              "login" => login_path(locale: locale_param),
              "about" => about_infos_path(locale: locale_param),
              "contact_us" => new_user_feedback_path(locale: locale_param),
              "post_a_new_listing" => new_listing_path(locale: locale_param),
              "how_to_use" => how_to_use_infos_path(locale: locale_param),
              "terms" => terms_infos_path(locale: locale_param),
              "privacy" => privacy_infos_path(locale: locale_param)
            }

    marketplace_data = CLP::MarketplaceDataStore.marketplace_data(cid, landing_page_locale)
    name_display_type = marketplace_data["name_display_type"]

    category_data = CLP::CategoryStore.categories(cid, landing_page_locale, search_path)

    CLP::Denormalizer.new(
      link_resolvers: {
        "path" => CLP::LinkResolver::PathResolver.new(paths),
        "marketplace_data" => CLP::LinkResolver::MarketplaceDataResolver.new(marketplace_data),
        "assets" => CLP::LinkResolver::AssetResolver.new(APP_CONFIG[:clp_asset_host], sitename),
        "translation" => CLP::LinkResolver::TranslationResolver.new(landing_page_locale),
        "category" => CLP::LinkResolver::CategoryResolver.new(category_data),
        "listing" => CLP::LinkResolver::ListingResolver.new(cid, landing_page_locale, locale_param, name_display_type)
      }
    )
  end

  def parse_int(int_str_or_nil)
    Integer(int_str_or_nil || "")
  rescue ArgumentError
    nil
  end

  def community(request)
    @current_community ||= request.env[:current_marketplace]
  end

  def community_customization(request, locale)
    community(request).community_customizations.where(locale: locale).first
  end

  def community_context(request)
    c = community(request)

    { favicon: c.favicon.url,
      apple_touch_icon: c.logo.url(:apple_touch) }
  end

  def render_landing_page(default_locale:, locale_param:, structure:)
    c = community(request)

    landing_page_locale, sitename = structure["settings"].values_at("locale", "sitename")
    topbar_locale = locale_param.present? ? locale_param : default_locale

    initialize_i18n!(c&.id, locale)

    props = topbar_props(c,
                         community_customization(request, landing_page_locale),
                         request.fullpath,
                         locale_param,
                         topbar_locale)
    marketplace_context = marketplace_context(c, topbar_locale, request)
    topbar_enabled = feature_enabled?(FEATURE_FLAG)

    google_maps_key = c&.google_maps_key

    denormalizer = build_denormalizer(
      cid: c&.id,
      locale_param: locale_param,
      default_locale: default_locale,
      landing_page_locale: landing_page_locale,
      sitename: sitename
    )

    render_to_string :landing_page,
           locals: { font_path: FONT_PATH,
                     landing_page_locale: landing_page_locale,
                     styles: landing_page_styles,
                     javascripts: {
                       location_search: location_search_js,
                       translations: js_translations(topbar_locale)
                     },
                     page: denormalizer.to_tree(structure, root: "page"),
                     sections: denormalizer.to_tree(structure, root: "composition"),
                     topbar_props: props,
                     topbar_props_path: ui_api_topbar_props_path(locale: topbar_locale),
                     marketplace_context: marketplace_context,
                     topbar_enabled: topbar_enabled,
                     google_maps_key: google_maps_key,
                     community_context: community_context(request)
                   }
  end

  def render_not_found(msg = "Not found")
    self.status = 404
    self.response_body = msg
  end

  def topbar_props(community, community_customization, request_path, locale_param, topbar_locale)
    # TopbarHelper pulls current lang from I18n
    I18n.locale = topbar_locale

    path =
      if locale_param.present?
        request_path.gsub(/^\/#{locale_param}/, "").gsub(/^\//, "")
      else
        request_path.gsub(/^\//, "")
      end

    TopbarHelper.topbar_props(
      community: community,
      path_after_locale_change: path,
      search_placeholder: community_customization&.search_placeholder,
      locale_param: locale_param)
  end

  def marketplace_context(community, locale, request)
    uri = Addressable::URI.parse(request.original_url)

    location = uri.path + (uri.query.present? ? "?#{uri.query}" : "")

    result = {
      # URL settings
      href: request.original_url,
      location: location,
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      pathname: uri.path,
      search: uri.query,

      # Locale settings
      i18nLocale: locale,
      i18nDefaultLocale: I18n.default_locale,
      httpAcceptLanguage: request.env["HTTP_ACCEPT_LANGUAGE"],

      # Extension(s)
      marketplaceId: community.id,
      loggedInUsername: nil
    }.merge(CommonStylesHelper.marketplace_colors(community))

    result
  end

  def landing_page_styles
    Rails.application.assets.find_asset("landing_page/styles.scss").to_s.html_safe
  end

  def location_search_js
    Rails.application.assets.find_asset("location_search.js").to_s.html_safe
  end

  def js_translations(topbar_locale)
    Rails.application.assets.find_asset("i18n/#{topbar_locale}.js").to_s.html_safe
  end
end

