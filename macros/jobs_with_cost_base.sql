{#- macro to add cost related formula to base jobs table  -#}
{% macro jobs_with_cost_base(table_name, contains_query) -%}
{# More details about base table in https://cloud.google.com/bigquery/docs/information-schema-jobs -#}
WITH base AS (
  {% for project in var('input_gcp_projects').split(',') -%}
SELECT
  bi_engine_statistics,
  cache_hit,
  creation_time,
  TIMESTAMP_TRUNC(creation_time, HOUR) hour,
  destination_table,
  {% if contains_query -%}
  dml_statistics,
  {% endif -%}
  end_time,
  error_result,
  job_id,
  job_stages,
  job_type,
  labels,
  parent_job_id,
  priority,
  project_id,
  project_number,
  {% if contains_query -%}
  query,
  -- extract the dbt info from the query comment generated by dbt
  replace(replace(regexp_extract(query, r'^(\/\* \{+?[\w\W]+?\} \*\/)'), '/', ''), '*', '') dbt_info,
  {% endif -%}
  referenced_tables,
  reservation_id,
  start_time,
  state,
  statement_type,
  timeline,
  total_bytes_billed,
  total_bytes_processed,
  total_modified_partitions,
  total_slot_ms,
  transaction_id,
  user_email,
  query_info,
  transferred_bytes,
  materialized_view_statistics
FROM
  `{{ project | trim }}`.`region-{{ var('bq_region') }}`.`INFORMATION_SCHEMA`.`{{ table_name }}`
{#- Prevent to duplicate costs as script contains query #}
WHERE statement_type != 'SCRIPT'
{% if not loop.last %}UNION ALL{% endif %}
{% endfor %}
),
base_with_enriched_fields AS (
SELECT
  *,
  total_slot_ms / (1000 * 60 * 60 * 24) AS avg_slots,
  total_bytes_billed / POW(1024, 4) AS total_tb_billed,
  TIMESTAMP_DIFF(COALESCE(end_time, CURRENT_TIMESTAMP()), start_time, SECOND) AS total_time_seconds,
  {% if contains_query -%}
  IF(LENGTH(dbt_info) > 0, JSON_EXTRACT_SCALAR(dbt_info, '$.dbt_version'), NULL) AS dbt_version,
  IF(LENGTH(dbt_info) > 0, JSON_EXTRACT_SCALAR(dbt_info, '$.profile_name'), NULL) AS dbt_profile_name,
  IF(LENGTH(dbt_info) > 0, JSON_EXTRACT_SCALAR(dbt_info, '$.target_name'), NULL) AS dbt_target_name,
  IF(LENGTH(dbt_info) > 0, JSON_EXTRACT_SCALAR(dbt_info, '$.node_id'), NULL) AS dbt_model_name,
  {% endif -%}
  FROM base
),
base_with_all_pricing AS (
SELECT
  {% if contains_query -%}
  * EXCEPT(dbt_model_name),
  {%- else -%}
  *,
  {% endif -%}
    total_slot_ms / (1000 * 60 * 60) * {{ var('hourly_slot_price') }} AS flat_pricing_query_cost,
    total_tb_billed * {{ var('per_billed_tb_price') }} AS ondemand_query_cost,
    {% if contains_query -%}
    case
        when dbt_model_name like 'model.%' then 'model'
        when dbt_model_name like 'snapshot.%' then 'snapshot'
        when dbt_model_name like 'test.%' then 'test'
    end as dbt_execution_type,
    concat(split(dbt_model_name, '.')[safe_offset(1)], '.',split(dbt_model_name, '.')[safe_offset(2)]) as dbt_model_name
    {% endif -%}
FROM base_with_enriched_fields
)
SELECT
 *,
{% if var('use_flat_pricing') -%}
  flat_pricing_query_cost AS query_cost
{%- else -%}
  ondemand_query_cost AS query_cost
{%- endif %}
FROM base_with_all_pricing
{%- endmacro %}
