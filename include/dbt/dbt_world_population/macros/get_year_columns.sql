{% macro get_year_columns() %}
    {% set query %}
        select string_agg(column_name, ', ') as columns_string
        from `bigquery-public-data.world_bank_global_population.INFORMATION_SCHEMA.COLUMNS`
        where table_name = 'population_by_country'
        and column_name like 'year_%'
    {% endset %}
    
    {% set results = run_query(query) %}
    
    {# first try with columns approach #}
    {% if execute %}
        {% set columns_string = results.columns['columns_string'].values()[0] %}
    {% else %}
        {% set columns_string = '' %}
    {% endif %}
    
    {{ return(columns_string) }}
{% endmacro %}