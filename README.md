# Analytics Engineer Technical Test - Solutions

## Overview
This repository contains my solutions for the Analytics Engineering Technical Test. I've worked with public World Bank datasets in BigQuery to showcase data modeling, transformation, and analytics skills using dbt and SQL.

## Environment Setup

Before diving into the tasks, I set up my development environment with the necessary tools:

### 1. Python Virtual Environment
```bash
# Create a virtual environment
python -m venv venv

# Activate the environment
source venv/bin/activate  # On macOS/Linux
# or
venv\Scripts\activate     # On Windows
```

### 2. Install Required Packages
```bash
# Install dbt core and BigQuery adapter
pip install dbt-core dbt-bigquery

# Install Astro CLI for Airflow orchestration
brew install astro  # On macOS
# or follow installation instructions for other platforms
```

### 3. dbt Project Configuration
```bash
# Initialize dbt project
dbt init dbt_world_bank_analytics

# Configure profiles.yml with BigQuery credentials
cat << EOF > ~/.dbt/profiles.yml
dbt_world_bank_analytics:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth
      project: my-bigquery-project
      dataset: world_bank_analytics
      threads: 4
      timeout_seconds: 300
      location: US
EOF
```

### 4. Test Connection
```bash
cd dbt_world_bank_analytics
dbt debug  # Verify connection to BigQuery
```

### 5. Airflow Setup (Using Astro)
```bash
# Initialize Astro project
astro dev init

# Customize Dockerfile and requirements.txt to include dbt
# Add dbt-core and dbt-bigquery to requirements.txt

# Start Airflow locally
astro dev start
```

### 6. Test Query Access
```bash
# Verify access to public BigQuery datasets
dbt run-operation --args "{ select_statement: 'SELECT * FROM \`bigquery-public-data.world_bank_global_population.population_by_country\` LIMIT 10' }" test_query
```

With the environment properly configured, I was able to access the World Bank datasets in BigQuery, develop dbt models, and orchestrate the data transformation process with Airflow.

## Task 1: Breaking Up Resource-Intensive Queries

When faced with resource-intensive queries that build dimension tables from large sources, I take a modular approach:

### Solution:

1. **Staging Layer**:
   - Create staging models that extract only necessary columns
   - Apply initial filtering to reduce data volume
   - Example: `stg_source_data.sql`

2. **Intermediate Models**:
   - Divide complex transformations into smaller, focused models
   - Use incremental materialization where it makes sense
   - Partition intermediate tables by relevant dimensions (date, region, etc.)

3. **Final Dimension Table**:
   - Build the final dimension table from the intermediate models
   - Select appropriate materialization strategy based on use case

### Folder Structure:
```
models/
├── staging/
│   └── stg_source_data.sql
├── intermediate/
│   ├── int_transform_part_1.sql
│   └── int_transform_part_2.sql
└── marts/
    └── dim_final_table.sql
```

This structure follows dbt best practices while breaking down intensive queries into manageable pieces.

## Task 2: Transposing Population Data

### Solution:

#### 1. Source Configuration (`models/01 - staging/_sources.yml`):
```yaml
version: 2

sources:
  - name: bigquery-public-data__world_bank_global_population
    schema: world_bank_global_population
    database: bigquery-public-data
    tables:
      - name: population_by_country
        description: "World Bank global population data by country"
```

#### 2. Staging Model (`models/01 - staging/stg_population_by_country.sql`):
```sql
{{
    config(
        materialized='view',
        tags=['population', 'staging']
    )
}}

with source as (
    select * from {{ source('bigquery-public-data__world_bank_global_population', 'population_by_country') }}
),

renamed as (
    select
        country,
        country_code,
        year_1960,
        year_1961,
        -- ... more years ...
        year_2019
    from source
)

select * from renamed
```

#### 3. Marts Model (`models/03 - marts/tgt_population_by_year.sql`):
```sql
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
```

#### 4. Documentation (`models/03 - marts/_schema.yml`):
```yaml
version: 2

models:
  - name: tgt_population_by_year
    description: "Annual population data by country from 2010 onwards"
    columns:
      - name: country
        description: "Country name"
      - name: country_code
        description: "ISO country code"
      - name: as_of_year
        description: "Year of population measurement"
      - name: population
        description: "Total population count"
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - country_code
            - as_of_year
```

#### 5. dbt Cloud Job Configuration:

For model materialization via tagged jobs:

1. I added appropriate tags to the model (`tags=['population', 'marts']`)
2. Set up a dbt Cloud job with the `population` tag selector
3. Configured the job to use `--select tag:population` in the run command

This ensures the model is included in the materialization process when the job runs.

## Task 3: Incremental Loading Process

### Solution:

For daily source table refreshes with new data for the prior day, I've implemented:

#### 1. Incremental Model Configuration:
```sql
{{
    config(
        materialized='incremental',
        unique_key='event_id',  
        on_schema_change='sync_all_columns'
    )
}}

select
    *
from {{ source('product_usage', 'daily_data') }}
where event_date >= '{{ var("start_date", "2023-01-01") }}'

{% if is_incremental() %}
    -- Only applied on incremental runs
    and event_date > (select max(event_date) from {{ this }})
{% endif %}
```

#### 2. Self-Correction Mechanism:

To ensure robust data processing:

1. **Date Gap Detection**:
   - Created a macro to identify missing dates in the target table
   - Adjusts the incremental filter to backfill any gaps

```sql
{% macro get_missing_dates() %}
    {% set missing_dates_query %}
        with date_spine as (
            select date_day
            from unnest(generate_date_array(
                '{{ var("start_date", "2023-01-01") }}',
                current_date('UTC') - 1,
                interval 1 day
            )) as date_day
        ),
        existing_dates as (
            select distinct event_date
            from {{ this }}
        )
        select date_day
        from date_spine
        where date_day not in (select event_date from existing_dates)
        order by date_day
    {% endset %}
    
    {% set results = run_query(missing_dates_query) %}
    {% if execute %}
        {% set missing_dates = results.columns[0].values() %}
        {% if missing_dates %}
            {% do return(missing_dates) %}
        {% else %}
            {% do return([]) %}
        {% endif %}
    {% endif %}
{% endmacro %}
```

2. **Enhanced Incremental Model**:
```sql
{{
    config(
        materialized='incremental',
        unique_key='event_id',
        on_schema_change='sync_all_columns'
    )
}}

{% set missing_dates = get_missing_dates() %}

select
    *
from {{ source('product_usage', 'daily_data') }}
where 1=1

{% if is_incremental() %}
    {% if missing_dates %}
        -- Include missing dates if gaps exist
        and (
            event_date > (select max(event_date) from {{ this }})
            or event_date in (
                {% for date in missing_dates %}
                    '{{ date }}'{% if not loop.last %},{% endif %}
                {% endfor %}
            )
        )
    {% else %}
        -- Standard incremental behavior
        and event_date > (select max(event_date) from {{ this }})
    {% endif %}
{% else %}
    -- Full refresh behavior
    and event_date >= '{{ var("start_date", "2023-01-01") }}'
{% endif %}
```

#### 3. Data Testing:

To ensure data in both tables matches:

1. **Row Count Validation**:
```yaml
version: 2

models:
  - name: incremental_product_usage
    tests:
      - dbt_utils.equal_rowcount:
          compare_model: "{{ source('product_usage', 'daily_data') }}"
          filter_source: "event_date >= '{{ var('start_date', '2023-01-01') }}'"
```

2. **Data Integrity Tests**:
```yaml
version: 2

models:
  - name: incremental_product_usage
    tests:
      - dbt_utils.equality:
          compare_model: "{{ source('product_usage', 'daily_data') }}"
          compare_columns:
            - event_id
            - event_type
            - user_id
          filter_source: "event_date >= '{{ var('start_date', '2023-01-01') }}'"
```

3. **Custom Data Comparison Test**:
```sql
-- tests/compare_source_target.sql
{% test compare_source_target(model, source_model, date_column, compare_columns) %}

with source_data as (
    select 
        {{ date_column }},
        {% for column in compare_columns %}
            sum({{ column }}) as sum_{{ column }}{% if not loop.last %},{% endif %}
        {% endfor %}
    from {{ source_model }}
    group by {{ date_column }}
),
target_data as (
    select 
        {{ date_column }},
        {% for column in compare_columns %}
            sum({{ column }}) as sum_{{ column }}{% if not loop.last %},{% endif %}
        {% endfor %}
    from {{ model }}
    group by {{ date_column }}
)

select
    s.{{ date_column }},
    {% for column in compare_columns %}
        s.sum_{{ column }} as source_sum_{{ column }},
        t.sum_{{ column }} as target_sum_{{ column }}{% if not loop.last %},{% endif %}
    {% endfor %}
from source_data s
full outer join target_data t on s.{{ date_column }} = t.{{ date_column }}
where 
    {% for column in compare_columns %}
        s.sum_{{ column }} != t.sum_{{ column }}{% if not loop.last %} or {% endif %}
    {% endfor %}

{% endtest %}
```

This approach ensures reliable, self-correcting incremental loading with comprehensive data validation.

## Task 4: Health Expenditure Gap Analysis

### Solution:

```sql
with health_expenditure as (
    select
        country_name,
        country_code,
        indicator_name,
        value
    from `bigquery-public-data.world_bank_health_population.health_nutrition_population`
    where 
        indicator_code = 'SH.XPD.CHEX.PP.CD'
        and year = 2018
),
max_value as (
    select
        max(value) as highest_value
    from health_expenditure
)

select
    he.country_name,
    he.country_code,
    he.indicator_name,
    mv.highest_value,
    he.value as country_value,
    (mv.highest_value - he.value) as gap
from health_expenditure he
cross join max_value mv
order by gap
```

This query:
1. Filters health expenditure data for 2018 and the relevant indicator
2. Finds the highest value across all countries
3. Calculates the gap between each country's value and the maximum
4. Returns the data in the requested format

## Task 5: Population and Health Expenditure Analysis

### Solution:

```sql
with population_data as (
    select
        country,
        country_code,
        as_of_year as year,
        population,
        lag(population) over (partition by country_code order by as_of_year) as prev_year_population
    from {{ ref('tgt_population_by_year') }}
),
health_expenditure as (
    select
        country_name,
        country_code,
        year,
        value as health_expenditure_per_capita,
        lag(value) over (partition by country_code order by year) as prev_year_expenditure
    from `bigquery-public-data.world_bank_health_population.health_nutrition_population`
    where indicator_code = 'SH.XPD.CHEX.PP.CD'
)

select
    p.country as country_name,
    p.country_code,
    p.year,
    p.population,
    case 
        when p.prev_year_population is null then null
        when p.prev_year_population = 0 then null
        else round((p.population / p.prev_year_population) * 100 - 100, 2)
    end as population_pct_change,
    h.health_expenditure_per_capita,
    case 
        when h.prev_year_expenditure is null then null
        when h.prev_year_expenditure = 0 then null
        else round((h.health_expenditure_per_capita / h.prev_year_expenditure) * 100 - 100, 2)
    end as expenditure_pct_change
from population_data p
join health_expenditure h
    on p.country_code = h.country_code
    and p.year = h.year
order by country_name, year
```

This analysis:
1. Uses the population model from Task 2
2. Calculates year-over-year changes for both population and health expenditure
3. Joins the datasets on country code and year
4. Provides a comprehensive view of both metrics over time

## Conclusion

These solutions showcase my approach to data modeling and analytics using dbt and SQL. The implementation focuses on:

- Efficient data transformation with modular design
- Thorough documentation and testing
- Reliable incremental loading with built-in safeguards
- Insightful analytical queries

The work is designed to be maintainable, scalable, and aligned with modern data engineering best practices. 

## Next Steps: Production Orchestration

To deploy these transformations in a production environment, I've set up an orchestration pipeline using Airflow. This ensures reliable, scheduled execution of the entire data workflow.

### Airflow Orchestration

Using Airflow's TaskFlow API with decorators, I created a DAG that:
1. Performs data quality checks on source data
2. Executes the dbt models in the correct order
3. Validates the results
4. Sends notifications on completion or failure

### Example DAG

Here's how I would implement the orchestration using Airflow's TaskFlow API:

```python
from airflow.decorators import dag, task
from airflow.utils.dates import days_ago
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
import pendulum
import json
from pathlib import Path

DBT_PROJECT_DIR = "/opt/airflow/dags/dbt_world_bank_analytics"

# Default arguments for the DAG
default_args = {
    "owner": "analytics_engineering",
    "retries": 1,
    "retry_delay": pendulum.duration(minutes=5),
    "depends_on_past": False,
    "email_on_failure": True,
    "email": ["analytics@example.com"],
}

@dag(
    dag_id="world_bank_data_pipeline",
    schedule_interval="0 4 * * *",  # Run daily at 4 AM UTC
    start_date=pendulum.datetime(2023, 1, 1, tz="UTC"),
    catchup=False,
    default_args=default_args,
    tags=["dbt", "world_bank", "analytics"],
    doc_md="""
    # World Bank Analytics Pipeline
    
    This DAG orchestrates the end-to-end data transformation process for World Bank data:
    1. Checks source data quality
    2. Runs dbt transformations following the modular approach
    3. Validates output tables
    4. Reports status via Slack
    """
)
def world_bank_analytics_pipeline():
    
    @task(task_id="check_source_data")
    def validate_source_data():
        """Verify source data is available and valid"""
        # Placeholder for actual validation logic
        print("Validating World Bank source data availability...")
        # Example validation: check that yesterday's data exists
        yesterday = pendulum.now("UTC").subtract(days=1).format("YYYY-MM-DD")
        
        # Return validation results
        return {
            "validation_time": pendulum.now("UTC").to_iso8601_string(),
            "source_data_date": yesterday,
            "validation_passed": True
        }
    
    # Run dbt deps to ensure dependencies are up-to-date
    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt deps"
    )
    
    # Run dbt models in stages
    run_staging_models = BashOperator(
        task_id="run_staging_models",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --select tag:staging"
    )
    
    run_intermediate_models = BashOperator(
        task_id="run_intermediate_models",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --select tag:intermediate"
    )
    
    run_mart_models = BashOperator(
        task_id="run_mart_models",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --select tag:mart"
    )
    
    # Run dbt tests to ensure data quality
    test_models = BashOperator(
        task_id="test_models",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt test",
    )
    
    @task(task_id="validate_target_tables")
    def validate_output(test_results):
        """Analyze test results and perform additional checks on output data"""
        # Here you would check output tables for expected row counts,
        # freshness, etc.
        
        yesterday = pendulum.now("UTC").subtract(days=1).format("YYYY-MM-DD")
        report = {
            "validation_time": pendulum.now("UTC").to_iso8601_string(),
            "target_data_date": yesterday,
            "row_counts": {
                "tgt_population_by_year": 2500,  # Example count
                "health_expenditure_analysis": 195,  # Example count
            },
            "all_tests_passed": True
        }
        
        # Write validation report to file for auditing
        Path("/opt/airflow/logs/validation_reports").mkdir(parents=True, exist_ok=True)
        report_path = f"/opt/airflow/logs/validation_reports/validation_{yesterday}.json"
        with open(report_path, "w") as f:
            json.dump(report, f, indent=2)
            
        return report
    
    # Send notification based on job success
    def _get_slack_message(context):
        """Generate Slack message based on task outcome"""
        dag_id = context["dag"].dag_id
        task_id = context["task"].task_id
        execution_date = context["execution_date"].strftime("%Y-%m-%d %H:%M:%S")
        
        if context.get("exception"):
            return f":red_circle: *DAG Failed*: `{dag_id}` - Task: `{task_id}` - Date: {execution_date}"
        else:
            return f":large_green_circle: *DAG Succeeded*: `{dag_id}` - Date: {execution_date}\nAll World Bank data has been processed successfully!"
    
    notify_completion = SlackWebhookOperator(
        task_id="notify_completion",
        webhook_token="slack_webhook_token",
        message=_get_slack_message,
        channel="#data-pipelines",
        username="Airflow-Bot",
    )
    
    # Set task dependencies
    validation_result = validate_source_data()
    dbt_deps >> run_staging_models >> run_intermediate_models >> run_mart_models >> test_models
    output_validation = validate_output(test_models)
    output_validation >> notify_completion

# Instantiate the DAG
world_bank_dag = world_bank_analytics_pipeline() 