{{
  config(
    materialized='view',
    tags=['population', 'intermediate']
  )
}}

with unpivoted as (
    select
        country,
        country_code,
        cast(replace(year_col, 'year_', '') as int64) as as_of_year,
        cast(population as float64) as population
    from {{ref('stg_population_by_country')}}
    unpivot(
        population for year_col in ({{ get_year_columns() }})
    )
)

select
    country,
    country_code,
    as_of_year,
    population
from unpivoted
order by country, as_of_year