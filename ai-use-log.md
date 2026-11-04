# AI Use Log

Running record to support the AI Use Declaration required by the CA brief (section 11).

**AI tool:** Claude Code (Anthropic), used inside VS Code.

**Responsibility:** I remain responsible for understanding, verifying and being able to explain everything submitted.

| Date | Activity | What the AI was used for | How I reviewed / tested / verified |
|---|---|---|---|
| 2026-10-29 | Setup | Read the CA brief; inspected the environment (Git, MariaDB 10.4.32, MongoDB, Docker) | Reviewed the findings report |
| 2026-11-02 | Setup | Renamed the case study to MikePay; initialised Git; created `.gitignore`, folder structure and starter READMEs | Reviewed the files and commit before the push |
| 2026-11-03 | Portfolio 1 | Proposed the MikePay design; wrote the schema, trigger, sample-data, verification and constraint-test SQL; wrote the ER diagram generator script and the normalisation explanation | Ran every script on MariaDB 10.4.32 and kept the real output in `evidence/`; investigated a warning and a jumbled output file and fixed both; viewed the rendered diagram against the schema |
| 2026-11-04 | Portfolio 2 | Designed the bulk dataset and the six query experiments; wrote the data generator, verification SQL and benchmark harness; drafted the README | Ran the load, integrity checks and benchmarks on MariaDB 10.4.32 and kept the real output; found and fixed a script error, meaningless sub-millisecond ratios and a wrong assumption in experiment E5, then re-ran everything; corrected two README claims the evidence did not support |
