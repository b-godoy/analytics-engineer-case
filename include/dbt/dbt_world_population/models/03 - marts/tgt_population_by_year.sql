{{
  config(
    materialized='table',
    tags=['population', 'mart']
  )
}}

select
    country,
    country_code,
    as_of_year,
    population
from {{ref('int_population_unpivoted')}}
where as_of_year >= 2010
order by country, as_of_year