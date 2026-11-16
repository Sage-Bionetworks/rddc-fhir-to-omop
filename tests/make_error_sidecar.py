"""Write tests/data/batch/_sidecar.errors.json: the test sidecar with one wrong checksum.

Observation.ndjson.gz gets a wrong md5, so intake rejects it; the converter then reports
intake_rejected_files as a QC failure (`make nf-test-errors`). Rerun after regenerating
_sidecar.json:  python3 -I tests/make_error_sidecar.py
"""

import json
from pathlib import Path

batch = Path(__file__).resolve().parent / "data" / "batch"
doc = json.loads((batch / "_sidecar.json").read_text())
doc["@id"] = "urn:uuid:5e1d0c2a-0000-4000-8000-000000000002"
hit = [x for x in doc["distribution"] if x.get("contentUrl") == "fhir/Observation.ndjson.gz"]
assert len(hit) == 1, "Observation.ndjson.gz not found in the sidecar"
hit[0]["md5"] = "0" * 32
(batch / "_sidecar.errors.json").write_text(json.dumps(doc, indent=2) + "\n")
print(f"wrote {batch / '_sidecar.errors.json'}")
