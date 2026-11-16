-- Stage: FHIR files the batch's sidecar lists that intake rejected (checksum mismatch, a
-- path outside the batch, …). They were not converted, so the OMOP output is incomplete.
INSERT INTO stg.qc
SELECT 'intake_rejected_files', 'fhir', getvariable('rejected_files'),
       CASE WHEN getvariable('rejected_files') = 0 THEN 'ok' ELSE 'fail' END,
       'FHIR files listed in the sidecar but rejected at intake (see intake/intake.tsv)';
