-- Stage: no subject list was given (run without a sidecar), so persons are not reconciled.
INSERT INTO stg.qc
SELECT 'sidecar_subjects', 'person', 0, 'warn',
       'no subject list given: persons were not reconciled with a sidecar';
