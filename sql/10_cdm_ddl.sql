-- OMOP CDM 5.4 tables populated by this pipeline, in the official DDL column order.
-- https://ohdsi.github.io/CommonDataModel/cdm54.html
-- (DuckDB does not enforce varchar lengths; QC reports values that would overflow.)

CREATE OR REPLACE TABLE location (
    location_id INTEGER NOT NULL, address_1 VARCHAR(50), address_2 VARCHAR(50),
    city VARCHAR(50), state VARCHAR(2), zip VARCHAR(9), county VARCHAR(20),
    location_source_value VARCHAR(50), country_concept_id INTEGER,
    country_source_value VARCHAR(80), latitude DOUBLE, longitude DOUBLE);

CREATE OR REPLACE TABLE care_site (
    care_site_id INTEGER NOT NULL, care_site_name VARCHAR(255),
    place_of_service_concept_id INTEGER, location_id INTEGER,
    care_site_source_value VARCHAR(50), place_of_service_source_value VARCHAR(50));

CREATE OR REPLACE TABLE provider (
    provider_id INTEGER NOT NULL, provider_name VARCHAR(255), npi VARCHAR(20),
    dea VARCHAR(20), specialty_concept_id INTEGER, care_site_id INTEGER,
    year_of_birth INTEGER, gender_concept_id INTEGER, provider_source_value VARCHAR(50),
    specialty_source_value VARCHAR(50), specialty_source_concept_id INTEGER,
    gender_source_value VARCHAR(50), gender_source_concept_id INTEGER);

CREATE OR REPLACE TABLE person (
    person_id INTEGER NOT NULL, gender_concept_id INTEGER NOT NULL,
    year_of_birth INTEGER NOT NULL, month_of_birth INTEGER, day_of_birth INTEGER,
    birth_datetime TIMESTAMP, race_concept_id INTEGER NOT NULL,
    ethnicity_concept_id INTEGER NOT NULL, location_id INTEGER, provider_id INTEGER,
    care_site_id INTEGER, person_source_value VARCHAR(50), gender_source_value VARCHAR(50),
    gender_source_concept_id INTEGER, race_source_value VARCHAR(50),
    race_source_concept_id INTEGER, ethnicity_source_value VARCHAR(50),
    ethnicity_source_concept_id INTEGER);

CREATE OR REPLACE TABLE observation_period (
    observation_period_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    observation_period_start_date DATE NOT NULL, observation_period_end_date DATE NOT NULL,
    period_type_concept_id INTEGER NOT NULL);

CREATE OR REPLACE TABLE death (
    person_id INTEGER NOT NULL, death_date DATE NOT NULL, death_datetime TIMESTAMP,
    death_type_concept_id INTEGER, cause_concept_id INTEGER, cause_source_value VARCHAR(50),
    cause_source_concept_id INTEGER);

CREATE OR REPLACE TABLE visit_occurrence (
    visit_occurrence_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    visit_concept_id INTEGER NOT NULL, visit_start_date DATE NOT NULL,
    visit_start_datetime TIMESTAMP, visit_end_date DATE NOT NULL,
    visit_end_datetime TIMESTAMP, visit_type_concept_id INTEGER NOT NULL,
    provider_id INTEGER, care_site_id INTEGER, visit_source_value VARCHAR(50),
    visit_source_concept_id INTEGER, admitted_from_concept_id INTEGER,
    admitted_from_source_value VARCHAR(50), discharged_to_concept_id INTEGER,
    discharged_to_source_value VARCHAR(50), preceding_visit_occurrence_id INTEGER);

CREATE OR REPLACE TABLE condition_occurrence (
    condition_occurrence_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    condition_concept_id INTEGER NOT NULL, condition_start_date DATE NOT NULL,
    condition_start_datetime TIMESTAMP, condition_end_date DATE,
    condition_end_datetime TIMESTAMP, condition_type_concept_id INTEGER NOT NULL,
    condition_status_concept_id INTEGER, stop_reason VARCHAR(20), provider_id INTEGER,
    visit_occurrence_id INTEGER, visit_detail_id INTEGER,
    condition_source_value VARCHAR(50), condition_source_concept_id INTEGER,
    condition_status_source_value VARCHAR(50));

CREATE OR REPLACE TABLE drug_exposure (
    drug_exposure_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    drug_concept_id INTEGER NOT NULL, drug_exposure_start_date DATE NOT NULL,
    drug_exposure_start_datetime TIMESTAMP, drug_exposure_end_date DATE NOT NULL,
    drug_exposure_end_datetime TIMESTAMP, verbatim_end_date DATE,
    drug_type_concept_id INTEGER NOT NULL, stop_reason VARCHAR(20), refills INTEGER,
    quantity DOUBLE, days_supply INTEGER, sig VARCHAR, route_concept_id INTEGER,
    lot_number VARCHAR(50), provider_id INTEGER, visit_occurrence_id INTEGER,
    visit_detail_id INTEGER, drug_source_value VARCHAR(50), drug_source_concept_id INTEGER,
    route_source_value VARCHAR(50), dose_unit_source_value VARCHAR(50));

CREATE OR REPLACE TABLE procedure_occurrence (
    procedure_occurrence_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    procedure_concept_id INTEGER NOT NULL, procedure_date DATE NOT NULL,
    procedure_datetime TIMESTAMP, procedure_end_date DATE, procedure_end_datetime TIMESTAMP,
    procedure_type_concept_id INTEGER NOT NULL, modifier_concept_id INTEGER,
    quantity INTEGER, provider_id INTEGER, visit_occurrence_id INTEGER,
    visit_detail_id INTEGER, procedure_source_value VARCHAR(50),
    procedure_source_concept_id INTEGER, modifier_source_value VARCHAR(50));

CREATE OR REPLACE TABLE device_exposure (
    device_exposure_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    device_concept_id INTEGER NOT NULL, device_exposure_start_date DATE NOT NULL,
    device_exposure_start_datetime TIMESTAMP, device_exposure_end_date DATE,
    device_exposure_end_datetime TIMESTAMP, device_type_concept_id INTEGER NOT NULL,
    unique_device_id VARCHAR(255), production_id VARCHAR(255), quantity INTEGER,
    provider_id INTEGER, visit_occurrence_id INTEGER, visit_detail_id INTEGER,
    device_source_value VARCHAR(50), device_source_concept_id INTEGER,
    unit_concept_id INTEGER, unit_source_value VARCHAR(50), unit_source_concept_id INTEGER);

CREATE OR REPLACE TABLE measurement (
    measurement_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    measurement_concept_id INTEGER NOT NULL, measurement_date DATE NOT NULL,
    measurement_datetime TIMESTAMP, measurement_time VARCHAR(10),
    measurement_type_concept_id INTEGER NOT NULL, operator_concept_id INTEGER,
    value_as_number DOUBLE, value_as_concept_id INTEGER, unit_concept_id INTEGER,
    range_low DOUBLE, range_high DOUBLE, provider_id INTEGER,
    visit_occurrence_id INTEGER, visit_detail_id INTEGER,
    measurement_source_value VARCHAR(50), measurement_source_concept_id INTEGER,
    unit_source_value VARCHAR(50), unit_source_concept_id INTEGER,
    value_source_value VARCHAR(50), measurement_event_id BIGINT,
    meas_event_field_concept_id INTEGER);

CREATE OR REPLACE TABLE observation (
    observation_id INTEGER NOT NULL, person_id INTEGER NOT NULL,
    observation_concept_id INTEGER NOT NULL, observation_date DATE NOT NULL,
    observation_datetime TIMESTAMP, observation_type_concept_id INTEGER NOT NULL,
    value_as_number DOUBLE, value_as_string VARCHAR(60), value_as_concept_id INTEGER,
    qualifier_concept_id INTEGER, unit_concept_id INTEGER, provider_id INTEGER,
    visit_occurrence_id INTEGER, visit_detail_id INTEGER,
    observation_source_value VARCHAR(50), observation_source_concept_id INTEGER,
    unit_source_value VARCHAR(50), qualifier_source_value VARCHAR(50),
    value_source_value VARCHAR(50), observation_event_id BIGINT,
    obs_event_field_concept_id INTEGER);

CREATE OR REPLACE TABLE cdm_source (
    cdm_source_name VARCHAR(255) NOT NULL, cdm_source_abbreviation VARCHAR(25) NOT NULL,
    cdm_holder VARCHAR(255) NOT NULL, source_description VARCHAR,
    source_documentation_reference VARCHAR(255), cdm_etl_reference VARCHAR(255),
    source_release_date DATE NOT NULL, cdm_release_date DATE NOT NULL,
    cdm_version VARCHAR(10), cdm_version_concept_id INTEGER NOT NULL,
    vocabulary_version VARCHAR(20) NOT NULL);
