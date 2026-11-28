# LAVA testcase verdicts

The shared test workflow keeps queue/completion monitoring separate from the
functional verdict. After the submitted job completes, lava_results.py collects
all suites and testcase pages, retains the raw responses, and exports functional
results in the existing list of name/result objects.

Any testcase fail/error/unknown status, empty expected suite, missing published
testcase, malformed/incomplete fetch or unexpected pagination destination fails
the GitHub test job. Expected publications come from the test definitions at the
exact revision submitted to LAVA, using explicit --expected-testcase-id declarations. Legacy definitions without
that contract retain suite-level completeness checks, their filenames are not
assumed to be testcase names.
An unavailable definition source is an evidence failure, never a passing job.

The collector uses Python 3 and PyYAML already required by job rendering on the
CI host. Nothing is installed on the DUT. Collection has a 180-second deadline,
30-second maximum per request and a 100-page ceiling. Raw evidence remains under
lava-results/evidence and is uploaded even when result validation fails.

Example from the kernel-config workspace:

```sh
python3 scripts/lava_results.py --job-id 12345 \
    --definition ../job_render/renders/lava_job_definition.yaml \
    --output-dir lava-results/evidence --export lava-results/Tests-kbdev-target.json
```

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
