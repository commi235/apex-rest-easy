create or replace package body mtag_github_rest_connector
as

  gc_scope constant varchar2(129) := $$plsql_unit || '.';

  gc_per_page_param_name   varchar2(8) := 'per_page';
  gc_per_page_maximum      pls_integer := 20;
  gc_page_param_name       varchar2(4) := 'page';
  gc_link_header_name      varchar2(4) := 'Link';

  type t_pagination_info is
    record
    (
      prev_query_string varchar2(32767) := null
    , next_query_string varchar2(32767) := null
    , has_next_page     boolean         := false
    , has_prev_page     boolean         := false
    , row_count         number          := 0
    );

  function get_row_count
  (
    p_response in clob
  ) return number
  as
    l_return number;
  begin
    apex_debug.enter( p_routine_name => gc_scope || 'get_row_count' );

    select count(*)
      into l_return
      from json_table( p_response 
                     , '$'
                       columns
                         nested path '$[*]' 
                          columns (
                            elem varchar2(4000) format json path '$'
                          )
                     )
    ;

    apex_debug.trace( p_message => 'Exit get_row_count. return=%s ', p0 => l_return );
    return l_return;
  end get_row_count;

  procedure pagination_info
  (
    p_response_headers in         apex_web_service.header_table
  , p_response         in         clob
  , p_pagination_info  out nocopy t_pagination_info
  )
  as
    l_link_header_value varchar2(32767);
    l_link_header_found boolean := false;

    l_link_header_parts apex_t_varchar2;
    l_cur_header_parts  apex_t_varchar2;
  begin
    apex_debug.enter( p_routine_name => gc_scope || 'pagination_info' );

    for i in 1 .. p_response_headers.count loop
      if p_response_headers( i ).name = gc_link_header_name then
        apex_debug.message( p_message => 'Found link header. Value=%s', p0 => p_response_headers( i ).value );
        l_link_header_value := p_response_headers( i ).value;
        l_link_header_found := true;
      end if;
    end loop;

    if l_link_header_found then
      l_link_header_parts := apex_string.split( p_str => l_link_header_value, p_sep => ',' );

      for i in 1..l_link_header_parts.count loop
        l_cur_header_parts := apex_string.split( p_str => l_link_header_parts( i ), p_sep => ';' );
        case trim( both from l_cur_header_parts( 2 ) )
          when 'rel="prev"' then
            apex_debug.message( p_message => 'Found prev link. Value=%s', p0 => regexp_replace( l_cur_header_parts( 1 ), '.*\?(\S*)>.*', '\1' ) );
            p_pagination_info.prev_query_string := regexp_replace( l_cur_header_parts( 1 ), '.*\?(\S*)>.*', '\1' );
            p_pagination_info.has_prev_page     := true;
          when 'rel="next"' then
            apex_debug.message( p_message => 'Found next link. Value=%s', p0 => regexp_replace( l_cur_header_parts( 1 ), '.*\?(\S*)>.*', '\1' ) );
            p_pagination_info.next_query_string := regexp_replace( l_cur_header_parts( 1 ), '.*\?(\S*)>.*', '\1' );
            p_pagination_info.has_next_page     := true;
          else
            null;
        end case;
      end loop;
    end if;

    p_pagination_info.row_count := get_row_count( p_response => p_response );

    apex_debug.trace( p_message => 'End pagination_info' );
  end pagination_info;

  procedure capabilities_web_source
  (
    p_plugin in            apex_plugin.t_plugin
  , p_result in out nocopy apex_plugin.t_web_source_capabilities
  )
  as
  begin
    -- Github User Repos has capabilities for
    -- Pagination and Sorting and Filtering.
    -- We will only enable Pagination for now.
    p_result.pagination := true;
    p_result.order_by   := false;
    p_result.filtering  := false;
  end capabilities_web_source;

  procedure fetch_web_source
  (
    p_plugin     in            apex_plugin.t_plugin
  , p_web_source in            apex_plugin.t_web_source
  , p_params     in            apex_plugin.t_web_source_fetch_params
  , p_result     in out nocopy apex_plugin.t_web_source_fetch_result
  )
  as
    l_web_source_operation apex_plugin.t_web_source_operation;
    l_time_budget          number;
    l_start_page_id        pls_integer;
    l_continue_fetch       boolean     := true;
    l_page_to_fetch        pls_integer := 0;

    l_page_size            pls_integer;
    l_requested_page       pls_integer;
    l_query_string         varchar2(32767);
    l_pagination_info      t_pagination_info;
    l_response_row_count   pls_integer := 0;
    l_pagination_size      pls_integer;
  begin
    apex_debug.enter( p_routine_name => gc_scope || 'fetch_web_source' );

    apex_plugin_util.debug_web_source
    (
      p_plugin     => p_plugin
    , p_web_source => p_web_source
    );

    l_web_source_operation :=
      apex_plugin_util.get_web_source_operation
      (
        p_web_source   => p_web_source
      , p_db_operation => apex_plugin.c_db_operation_fetch_rows
      , p_perform_init => true
      );

    apex_debug.info( p_message => 'Original Query String is: %s', p0 => l_web_source_operation.query_string );

    l_page_size    := coalesce( p_params.fixed_page_size, gc_per_page_maximum );
    l_query_string := l_web_source_operation.query_string;

    p_result.responses := apex_t_clob();

    l_pagination_size :=
      case when p_params.fetch_all_rows then 100
           else least( coalesce( p_params.max_rows, gc_per_page_maximum ), gc_per_page_maximum )
      end;

    l_start_page_id :=
      case when p_params.fetch_all_rows then 1
           else floor( ( p_params.first_row - 1 ) / l_pagination_size ) + 1
      end;

    while l_continue_fetch and coalesce( l_time_budget, 1 ) > 0 loop
      p_result.responses.extend( 1 );
      l_page_to_fetch := l_page_to_fetch + 1;

      -- On first fetch we do not have any pagination info
      -- Therefore setting query string with pagination size and start page
      if l_pagination_info.next_query_string is null then
        l_web_source_operation.query_string :=
          l_query_string || gc_per_page_param_name || '=' || l_pagination_size || '&'
                         || gc_page_param_name || '=' || l_start_page_id
        ;
      else
        -- if pagination info received we get full query string already.
        -- Github gives us this in the result headers, so using it instead of building on our own
        l_web_source_operation.query_string := l_query_string;
      end if;

      apex_debug.info( p_message => 'New Query String is: %s', p0 => l_web_source_operation.query_string );

      apex_plugin_util.make_rest_request
      (
        p_web_source_operation => l_web_source_operation
      , p_bypass_cache         => false
      , p_time_budget          => l_time_budget
      , p_response             => p_result.responses( l_page_to_fetch )
      , p_response_parameters  => p_result.out_parameters
      );

      pagination_info
      (
        p_response_headers => apex_web_service.g_headers
      , p_response         => p_result.responses( l_page_to_fetch )
      , p_pagination_info  => l_pagination_info
      );

      -- For every page we add derived row count to total row count
      l_response_row_count := l_response_row_count + l_pagination_info.row_count;

      l_continue_fetch := p_params.fetch_all_rows and l_pagination_info.has_next_page;

      if l_continue_fetch then
        -- Github hands back prev/next links in a header variable
        -- We already extracted it and derived the next link
        l_query_string := l_pagination_info.next_query_string;
      end if;

    end loop;
    
    -- If all fetched there is nothing more (obviously...)
    -- and we started with the first record.
    -- Otherwise our pagination info tells us if more data available.
    if p_params.fetch_all_rows then
      p_result.has_more_rows      := false;
      p_result.response_first_row := 1;
    else
      p_result.has_more_rows      := l_pagination_info.has_next_page;
      p_result.response_first_row := ( l_start_page_id - 1 ) * l_page_size + 1;
    end if;

    -- Derived by counting array in response
    -- should always be available
    p_result.response_row_count := l_response_row_count;
  end fetch_web_source;

  procedure discover
  (
    p_plugin         in            apex_plugin.t_plugin
  , p_web_source     in            apex_plugin.t_web_source
  , p_params         in            apex_plugin.t_web_source_discover_params
  , p_result         in out nocopy apex_plugin.t_web_source_discover_result
  )
  as
    l_web_source_operation          apex_plugin.t_web_source_operation;
    l_in_parameters                 apex_plugin.t_web_source_parameters;
    l_dummy_parameters              apex_plugin.t_web_source_parameters;

    -- Using 20 result per page as default
    l_per_page_value        pls_integer := gc_per_page_maximum;
    l_per_page_found        boolean     := false;
    l_per_page_idx          pls_integer;
    l_time_budget           number;
  begin

    l_web_source_operation :=
      apex_plugin_util.get_web_source_operation
      (
        p_web_source   => p_web_source
      , p_db_operation => apex_plugin.c_db_operation_fetch_rows
      , p_perform_init => true
      );
    
    for i in 1 .. l_web_source_operation.parameters.count loop
      l_in_parameters( l_in_parameters.count + 1 ) := l_web_source_operation.parameters( i );
      if l_web_source_operation.parameters( i ).name = gc_per_page_param_name then
        l_per_page_value := coalesce( l_web_source_operation.parameters( i ).value, l_per_page_value );
        l_per_page_found := true;
      end if;
    end loop;

    if not l_per_page_found then
      l_per_page_idx := l_in_parameters.count + 1;
      l_in_parameters( l_per_page_idx ).name       := gc_per_page_param_name;
      l_in_parameters( l_per_page_idx ).param_type := apex_plugin.c_web_src_param_query;
    end if;

    l_web_source_operation.query_string := gc_per_page_param_name || '=' || sys.utl_url.escape( l_per_page_value );

    apex_plugin_util.make_rest_request
    (
      p_web_source_operation => l_web_source_operation
    , p_bypass_cache         => false
    , p_response             => p_result.sample_response
    , p_response_parameters  => l_dummy_parameters
    , p_time_budget          => l_time_budget
    );

    p_result.response_headers := apex_web_service.g_headers;
    p_result.parameters       := l_in_parameters;

  end discover;

end mtag_github_rest_connector;
/
