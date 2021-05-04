create or replace package mtag_github_rest_connector
as

  procedure capabilities_web_source
  (
    p_plugin in            apex_plugin.t_plugin
  , p_result in out nocopy apex_plugin.t_web_source_capabilities
  );

  procedure fetch_web_source
  (
    p_plugin     in            apex_plugin.t_plugin
  , p_web_source in            apex_plugin.t_web_source
  , p_params     in            apex_plugin.t_web_source_fetch_params
  , p_result     in out nocopy apex_plugin.t_web_source_fetch_result
  );

  procedure discover
  (
    p_plugin         in            apex_plugin.t_plugin
  , p_web_source     in            apex_plugin.t_web_source
  , p_params         in            apex_plugin.t_web_source_discover_params
  , p_result         in out nocopy apex_plugin.t_web_source_discover_result
  );
  
end mtag_github_rest_connector;
/
