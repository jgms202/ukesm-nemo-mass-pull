# ukesm-nemo-mass-pull

These scripts pull monthly UKESM1.1 NEMO ocean output from the Met Office MASS archive (`moose:/crum/<suite>/onm.nc.file`) on the Met Office HPC with Slurm. Each file is reduced to the needed variables and saved locally. They cover the NEMO data used in the SPG–SAI project.

## Files

| File | What it does | Edit? |
|---|---|---|
| `tasks.txt` | The list of pulls, one per line: `suite  stream  year-start  year-end`. | **Yes**: choose the suites, streams and years here |
| `submit.sh` | Submits every line of `tasks.txt` as a Slurm array, throttled to 3 concurrent MASS streams. | No |
| `pull_nemo.sbatch` | The Slurm job. Each array task reads one line of `tasks.txt` and runs the worker. | Only the partition, time limit or memory |
| `pull_nemo_mass.sh` | The worker. It runs `moo get` one year at a time, keeps the chosen variables with `ncks`, deletes the raw file, and skips months already on disk. | Variables (`WANT_VARS`), output location (`DATA_ROOT`) |

## What to change

- **Suite ID / experiment:** edit the `suite` column of `tasks.txt`. To skip a line, comment it out with `#`.
- **Time length:** edit the `year-start` and `year-end` columns. Years are inclusive and the files are monthly.
- **Variables:** edit the stream's `WANT_VARS` line in the `case` block of `pull_nemo_mass.sh`. To add a new stream, add one line to that block.
- **Output location:** set `export DATA_ROOT=...` before submitting. The default is `/data/users/$USER/SPG_SAI`, and files go to `$DATA_ROOT/UKESM1.1/<suite>/`.

| Stream | NEMO file | Variables kept | Output suffix |
|---|---|---|---|
| `grid-T` | grid-T | `thetao so somxl010 mlotst zos sos` (3D T/S, MLD, SSH, SSS) | `grid-T_ext` |
| `diaptr` | diaptr | `zomsfatl sophtadv_atlantic` (native AMOC, Atlantic heat transport) | `diaptr_ext` |
| `vo` | grid-V | `vo` (used for BSF) | `grid-V_ext` |
| `mld` | grid-T | `somxl010`, stripped on the MASS side (small transfer) | `mld_ext` |
| `tau-U` / `tau-V` | grid-U / grid-V | `tauuo` / `tauvo`, stripped on the MASS side | `tauuo_ext` / `tauvo_ext` |

## Suites in `tasks.txt`

| Experiment | r2 | r3 | r12 | Years | Streams |
|---|---|---|---|---|---|
| G6-1.5K-SAI | u-dp583 | u-dp690 | u-dp691 | 2034–2084 | grid-T, diaptr, vo, mld, tau-U/V (tau 2035–2054 only) |
| SSP2-4.5 | u-dp902 | u-dp903 | u-dp904 | 2015–2100 | diaptr |
| G6-1.5K-HiLLA | u-ds275 | u-ds286 | u-ds287 | 2034–2084 | diaptr |

The remaining ocean fields for SSP2-4.5 and HiLLA came from the CMIP6-format UKESM1-1 output, not from MASS.

## Run

Run these on a Met Office HPC login node that has `moo` access:

```bash
./submit.sh --dry-run        # 1. ALWAYS first: checks what is on MASS, retrieves nothing
grep -h "on MASS\|to retrieve\|WARNING" logs/*.out
./submit.sh                  # 2. the real pull

ARRAY=0-5 ./submit.sh        # run only task lines 0-5 (0-based, comments not counted)
MAXPAR=2  ./submit.sh        # fewer concurrent MASS streams (keep it at 3 or fewer)

# Standalone, a single suite/stream with no Slurm:
bash pull_nemo_mass.sh --suite u-dp583 --stream diaptr --year-start 2034 --year-end 2084 --dry-run
```

Re-running is safe: months already on disk are skipped. Logs go to `logs/`, plus `$DATA_ROOT/logs/pull_nemo_<id>_<stream>.log` for each suite and stream.

A grid-T pull moves about 166 GB from tape per 51-year suite but keeps only about 20 GB, because MASS can't subset whole files. Expect it to take many hours.
