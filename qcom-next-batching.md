# qcom-next PR batching

How `qcom-next.yaml` promotion PRs are grouped and validated together.

Related files:

| File | Role |
| --- | --- |
| `qcom-next-batching.yaml` | Safety zone configuration (the source of truth) |
| `.github/workflows/qcom-next_batch_dispatch.yml` | Scheduled dispatcher |
| `.github/actions/qcom_next_batch/plan.py` | Batch planner |
| `.github/workflows/qcom-next_topic_update.yml` | Candidate build, test and publish |
| `.github/scripts/qcom_next_topics.py` | Per-PR topic diff and conflict blame |
| `qcom-next.conf` | Authoritative list of topic branches |

---

## Why batch at all

Every promotion PR bumps the `sha` and `tag` of one or more topic branches in
`qcom-next.yaml`. Validating each PR on its own means a full automerge, kernel
build and LAVA test run per topic. With ~49 topics that does not keep up.

Batching validates several PRs in a single pipeline run. The risk is that
merging unrelated topics together causes an automerge conflict, or that a
failure cannot be attributed to a single PR. Safety zones exist to keep that
risk bounded.

---

## How a batch is chosen

The dispatcher runs on a 30 minute schedule and can also be triggered manually.
For each open PR that modifies `qcom-next.yaml` it:

1. Works out which topic branches the PR actually promotes, by parsing
   `qcom-next.yaml` at the PR base and at the PR head and diffing the
   `sha`/`tag` of every topic. A PR that touches the file but changes no topic
   is ignored.
2. Drops PRs that are not ready: draft, unmergeable, carrying a skip label, or
   already dispatched.
3. Reads any `Depends-on:` trailers and locks each PR together with its
   prerequisites into a single indivisible unit.
4. Assigns each unit to a safety zone and groups units that share one.
5. Dispatches **one** batch as a run of `qcom-next_topic_update_manual.yml`.

### The rules

1. **Same zone only.** A PR is batchable only if *every* topic it promotes is in
   the same zone. A PR spanning two zones runs on its own.
2. **Solo zones never batch.** Topics in a zone marked `solo: true` are always
   validated alone.
3. **Wildcard zones batch with anything.** Topics in a zone marked
   `wildcard: true` may join a batch in *any* zone and do not constrain which
   zone their PR is anchored to. Wildcards are placed after the zoned batches
   are formed, and still respect every other rule. `tech/mm/camss` is the only
   wildcard today.
4. **Conflicting pairs never share a batch**, even inside the same zone.
5. **The same topic is never promoted twice in one batch.** Two PRs bumping the
   same topic would edit the same `sha`/`tag` lines, so the second merge would
   conflict. They are always split.
6. **Unknown topics run solo.** A topic absent from the config is never
   silently batched, so adding a topic to `qcom-next.conf` is safe by default.
7. **`Depends-on:` beats every rule above.** PRs linked by a dependency are
   always validated in the same batch, even across zones.

Zones are matched in file order and the first match wins, which is how
`tech/mm/camss` escapes the `tech/mm/*` red zone below it.

### Declaring a dependency

A promotion PR that cannot be validated on its own declares its prerequisites in
the PR body:

```
Depends-on: #412
Depends-on: #398, #401
```

Bare numbers, `#`-prefixed numbers and full pull request URLs are all accepted,
and several PRs may be listed on one line or across several lines.

The planner then guarantees:

- **One batch, any zone.** The dependency is pulled into the same batch as the
  PR that declares it, even when their topics belong to different safety zones,
  even when one of those zones is `solo`, and even when the resulting batch
  exceeds `max_batch_size`. The group is never split.
- **Transitive.** If #A depends on #B and #B depends on #C, all three go out
  together.
- **Pulled in regardless of filters.** A dependency is added to the batch even
  when `only_prs` did not name it.
- **All or nothing.** If any PR in the group is not dispatchable — draft,
  unmergeable, already dispatched, closed without merging, targeting another
  base branch, or not a promotion PR — the entire group is held back and the
  reason is listed under *Skipped PRs* in the run summary. Nothing is validated
  without its dependency.
- **Merged dependencies are ignored.** Once a dependency is merged it is part of
  the base branch, so the dependent PR is free to go out by itself.

A batch formed across zones by a dependency is reported with the zone `depends`.

### One pipeline at a time

The pipeline publishes to the shared `qcom-next` branch, so overlapping runs
would race. The planner refuses to dispatch while any workflow in
`block_on_workflows` has a run that is queued, waiting for environment
approval, or executing. The next scheduled run tries again.

Practical consequence: with a ~3 hour pipeline you get roughly one batch every
3.5 hours regardless of how often the cron fires.

### Dispatch is one-shot per PR

Every PR in a dispatched batch is labelled `qcom-next-dispatched` and is never
picked up again while that label is present. Remove the label by hand to
requeue a PR.

---

## How the zones were derived

Each topic branch was diffed against its merge-base with the baseline and the
resulting file sets were compared pairwise. Zones group topics whose changes do
not touch each other's files.

Four files are touched by many topics. Conflicts there are append-style list
edits that are cheap to resolve, so they are **tolerated inside a zone** and are
not treated as blocking:

| Contention hub | Topics touching it |
| --- | --- |
| `arch/arm64/boot/dts/qcom/Makefile` | 12 |
| `arch/arm64/configs/defconfig` | 10 |
| `MAINTAINERS` | 9 |
| `Documentation/devicetree/bindings/arm/qcom.yaml` | 7 |

Every entry under `conflicts` is a measured overlap on real source or `.dtsi`.

Current coverage: **49 topics, 33 batchable, 16 solo.** Every measured hard
overlap is prevented, either by the zone rule or by an explicit conflict; none
are unprotected.

File overlap is a floor, not the whole picture. A zone can still be marked solo
on judgement — see `multimedia` below, which is disjoint at file level but kept
unbatched because of size, directory adjacency and runtime coupling.

---

## Which topic branches batch together

### Batchable

These may share a batch **with other topics in the same group only**, up to the
stated limit — with one exception, the camera wildcard below.

#### `camera` — joins any batch

```
tech/mm/camss
```

`tech/mm/camss` is the one topic that may be batched with **any** other topic,
in any zone. It is exempt from the `tech/mm/*` red zone because the measurement
supports it: **zero file overlap with any batchable topic.** Its only file
overlap anywhere is with `tech/mm/gpu`, which is solo and so never batches.

It is adjacent to three batchable topics in `drivers/phy/qualcomm`
(`tech/bus/pci/all`, `tech/bus/usb/all`, `tech/storage/all`), but camss edits
the CSI PHY while those edit their own, with no shared file.

A camss PR rides along with whichever batch is already going out, so it
normally costs no extra pipeline run. It still obeys the host zone's batch
limit, the conflict list and the same-topic rule, and it never joins a solo
batch. If no batch is available it runs on its own.

#### `dt-soc` — up to 4 per batch

Per-SoC devicetree. Each topic owns its own `arch/arm64/boot/dts/qcom` files.

```
tech/all/dt/qcs6490    tech/all/dt/eliza        tech/all/dt/glymur
tech/all/dt/qcs9100    tech/all/dt/hamoa        tech/all/dt/kaanapali
tech/all/dt/qcs8300    tech/all/dt/pakala
tech/all/dt/qcs615
```

Exception: `glymur` + `kaanapali` never share a batch (both edit
`glymur.dtsi`).

#### `bsp` — up to 3 per batch

```
tech/bsp/clk    tech/bsp/ec              tech/bsp/sched
tech/bsp/devfreq    tech/bsp/interconnect
```

`tech/bsp/soc-infra` is **excluded** and runs solo.

#### `networking` — up to 3 per batch

```
tech/net/ath    tech/net/eth    tech/net/bluetooth
```

All three can go in one batch. `tech/net/eth` has no measured overlap with any
topic in the tree.

#### `power` — up to 3 per batch

```
tech/pm/power    tech/pm/thermal    tech/pmic/all
```

#### `security` — up to 3 per batch

```
tech/security/crypto    tech/security/firmware-smc    tech/security/optee-next
```

Exception: `firmware-smc` + `optee-next` never share a batch (both edit
`qcom_scm.c`). `crypto` can pair with either.

#### `storage-mem` — up to 2 per batch

```
tech/storage/all    tech/storage/nvmem    tech/mem/all
```

#### `bus` — up to 2 per batch

```
tech/bus/pci/all    tech/bus/usb/all
```

#### `debug` — up to 2 per batch

```
tech/debug/hwtracing    tech/debug/rdbg
```

#### `platform-services` — up to 2 per batch

```
tech/mproc/all    tech/virt/gunyah
```

### Solo — never batched

#### `tech/mm/*` — the multimedia red zone

```
tech/mm/audio/all    tech/mm/fastrpc    tech/mm/phy
tech/mm/drm          tech/mm/gpu        tech/mm/video
```

These are **never batched, not even with each other.** `tech/mm/camss` is the
one exception and is covered by the `camera` wildcard zone above.

They are disjoint at file level — no two of the non-GPU topics share a single
file, and none share a `Kconfig` or `Makefile` — so this is a deliberate
judgement call rather than a measured conflict:

- **Size.** `drm` (109 files), `video` (69), `audio/all` (43) and `camss` (39)
  are the largest topics in the tree after `gpu` and `overlay/dt`. A batch of
  three would be ~200 changed files, making it the most expensive bisect
  available when something fails.
- **Adjacency.** `camss` and `drm` both edit `drivers/phy/qualcomm` (3 files
  each, CSI versus DSI/DP); `camss` and `video` both edit the media bindings.
  Adjacent edits to shared PHY plumbing can break each other even with no
  shared file.
- **Runtime coupling.** DPU, CAMSS, IRIS and LPASS share SMMU contexts, clocks
  and interconnect bandwidth. Disjoint diffs do not imply independence at
  runtime, and a display or camera regression cannot be attributed to a single
  PR inside a batch.

`tech/mm/gpu` must stay solo regardless of any future change here: it sits 1877
commits and 7824 files ahead of the baseline, roughly 20x the next largest
topic, and overlaps `drm`, `audio/all`, `camss`, `fastrpc` and `video`.

#### Other solo topics

| Topic | Why |
| --- | --- |
| `tech/bsp/soc-infra` | Broad `drivers/soc/qcom` and firmware changes (51 files); also carries remoteproc |
| `tech/all/config` | Owns `defconfig`, the second most contended file in the tree |
| `tech/all/workaround` | Deliberately patches files owned by other topics (IOMMU, PCI quirks, SCM, DT) |
| `tech/overlay/dt` | 75 files spanning the per-SoC DT topics |
| `tech/all/hawi` | Whole-SoC enablement: DT + drivers + defconfig |
| `tech/all/maili` | Whole-SoC enablement |
| `tech/all/shikra` | Whole-SoC enablement; overlaps pci, crypto, fastrpc, audio, unoq, nord |
| `tech/hwe/unoq` | Pre-silicon enablement |
| `early/hwe/nord` | Pre-silicon enablement; 53 files overlapping 10+ topics |
| `tech/noup/debug/all` | Never-upstreamed debug carries; shares qcom firmware Kconfig/Makefile |

### Pairs that never share a batch

Two are inside a single zone, so they are the cases the zone rule alone would
not catch:

| Pair | Shared file |
| --- | --- |
| `tech/security/firmware-smc` + `tech/security/optee-next` | `drivers/firmware/qcom/qcom_scm.c` |
| `tech/all/dt/glymur` + `tech/all/dt/kaanapali` | `arch/arm64/boot/dts/qcom/glymur.dtsi` |

The rest are cross-zone and therefore already prevented by rule 1. They are
recorded so they stay correct if zones are ever widened or merged:

| Pair | Shared file |
| --- | --- |
| `tech/bus/usb/all` + `tech/all/dt/qcs6490` | `kodiak.dtsi`, `qcs6490-rb3gen2.dts` |
| `tech/net/bluetooth` + `tech/all/dt/qcs6490` | `kodiak.dtsi`, `qcs6490-rb3gen2.dts` |
| `tech/bus/usb/all` + `tech/net/bluetooth` | `kodiak.dtsi`, `qcs6490-rb3gen2.dts` |
| `tech/mem/all` + `tech/all/dt/qcs6490` | `kodiak.dtsi` |
| `tech/mem/all` + `tech/net/bluetooth` | `kodiak.dtsi` |
| `tech/bus/usb/all` + `tech/mem/all` | `kodiak.dtsi` |
| `tech/bus/pci/all` + `tech/net/ath` | `ath11k/pci.c`, `ath12k/pci.c` |
| `tech/bus/pci/all` + `tech/net/bluetooth` | `hci_qca.c`, `pwrseq-pcie-m2.c` |
| `tech/bsp/clk` + `tech/bus/usb/all` | `drivers/usb/dwc3/dwc3-qcom.c` |
| `tech/bsp/sched` + `tech/pm/power` | `include/linux/cpufreq.h` |
| `tech/net/bluetooth` + `tech/pm/power` | `pwrseq-qcom-wcn.c` |
| `tech/storage/all` + `tech/all/dt/hamoa` | `hamoa.dtsi` |

---

## When a topic branch fails to merge

A batch can still hit a conflict that no amount of zoning predicts: a topic
branch may simply not merge into the integration branch. The candidate build
handles that by **quarantining the responsible PR and continuing with the
rest**, rather than failing the whole batch.

automerge is invoked with **neither `--pass` nor `--interactive`**, which gives
the behaviour we want:

- Without `--interactive`, a conflicting merge first gets a chance to be
  resolved from the rerere cache. Only if that fails is the merge aborted.
- Without `--pass`, an unresolved conflict aborts the merge and exits non-zero
  rather than skipping the topic. A topic can therefore never be silently
  missing from a candidate that `qcom-next.yaml` claims is complete.

Because it stops at the first conflicting topic, a batch with N conflicting PRs
needs N+1 attempts; `max_quarantine_attempts` defaults to 5, enough for a full
batch of the largest zone.

The build then does the following.

1. While merging the batch, it records which topics each PR promotes, by
   diffing `qcom-next.yaml` before and after each PR merge.
2. After automerge, it identifies the conflicting topic from the
   `Merge failed, <topic> <url> <branch>` line in `merge.log`, and maps it back
   to the PR that promoted it. It also reads `topic_conflict`, so the logic
   still works if `--pass` is ever reinstated.
3. Each blamed PR is dropped from the batch and the candidate is **rebuilt from
   scratch** with the survivors — kernel-config is reset to base, the remaining
   PRs are re-merged, and automerge runs again.
4. The loop repeats until the candidate is clean, bounded by
   `max_quarantine_attempts` (default 3). Every PR blamed in a round is dropped
   in that round, so one attempt usually clears several conflicts.
5. Dropped PRs get a comment naming the conflicting topic and the
   `qcom-next-conflict` label. That label is in `skip_labels`, so the dispatcher
   will not pick the PR up again until the topic branch is rebased and the
   label is removed.
6. The surviving PRs carry on through build, test and publish as normal.

### Outcomes

| Situation | Result |
| --- | --- |
| One topic conflicts | That PR is dropped and blocked; the rest of the batch continues and publishes |
| Several topics conflict | All blamed PRs are dropped in one round; survivors continue |
| Every PR in the batch conflicts | Run fails — nothing left to validate. All PRs are blocked |
| A conflicting topic that **no PR in the batch promoted** | Run fails deliberately. Dropping a PR cannot fix it, and continuing would publish a tree missing that topic |
| automerge fails with **no conflicting topic reported** | Run fails. A bad tag, unreachable sha or fetch error is not something dropping a PR can fix |
| Still conflicting after `max_quarantine_attempts` | Run fails |

Every one of these paths reports the dropped PRs, so a PR that conflicted is
always labelled and told why, even when the run as a whole fails.

A conflicting topic that no PR touched means a topic already pinned in
`qcom-next.yaml` no longer merges against the current baseline. That is a
tree-level problem, not a PR problem, and needs a human.

---

## Worked examples

**Four DT PRs queued** — `pakala`, `eliza`, `qcs615`, `qcs9100`:
one batch of four.

**Five DT PRs queued** — one batch of four, one of one. `dt-soc` caps at 4.

**`glymur` and `kaanapali` queued together** — split into two batches. A third
compatible DT PR joins whichever batch is still open.

**`firmware-smc`, `optee-next`, `crypto` queued** — two batches:
`firmware-smc` + `crypto`, then `optee-next`.

**`drm` and `video` queued** — two separate batches. Multimedia is never
batched, including with itself.

**`camss` queued alongside three DT PRs** — one batch of four. The wildcard
fills the last `dt-soc` slot and costs no extra pipeline run.

**`camss` queued alongside a full batch of four DT PRs** — two batches. The host
batch is at its limit, so camss runs on its own.

**Two PRs both promoting `tech/net/eth`** — two batches. The same topic is never
promoted twice in one batch.

**A batch of four where one topic branch will not merge** — the responsible PR
is dropped and labelled `qcom-next-conflict`, the candidate is rebuilt from the
other three, and those three publish normally.

**One PR promoting `tech/net/eth` and `tech/mm/drm`** — runs solo. The topics
span `networking` and `multimedia`.

**A bulk rebase PR touching 40 topics** — runs solo, because the topics span
many zones. This is the common case for "Update to 7.x" PRs.

---

## Operating it

### Manual trigger

Run **qcom-next batch dispatch** from the Actions tab:

| Input | Purpose |
| --- | --- |
| `dry_run` | Plan and report without dispatching |
| `max_dispatches` | Dispatch more than one batch in this run |
| `only_prs` | Restrict planning to specific PR numbers |
| `base_branch` | Scan a base other than the repository default |
| `ignore_in_flight` | Dispatch even if a pipeline is still running |

### Running it from a non-default branch

GitHub only offers `workflow_dispatch` for workflows that exist **on the
default branch**. So this workflow has to be merged to `main` before it can be
dispatched at all — a copy on a feature branch alone is not dispatchable.

Once it is on `main`, you can dispatch it against any branch, and GitHub uses
**that branch's** copy of the workflow. That is the normal way to test a change
to the dispatcher. Two things follow:

- The dispatcher passes `--ref $GITHUB_REF_NAME` when it starts a batch, so a
  run launched from branch `X` also runs the topic update from branch `X`. The
  target workflow still has to exist on `main` to be dispatchable.
- Planning still defaults to the repository default branch. If the PRs you want
  to test target somewhere else, set `base_branch`. A base that does not exist
  fails the run rather than quietly reporting no work.

When testing from a branch, use `dry_run: true` first. A real dispatch builds a
candidate and publishes to the shared `qcom-next` branch, and it labels the PRs
it picks up.

Every run uploads a `qcom-next-batch-plan` artifact containing `batches.json`
and `summary.md`, and writes the plan to the run summary. Use `dry_run` to see
what would happen without starting anything.

### Common tasks

**Stop a PR from being batched** — add the `do-not-batch` label (also `wip`,
`hold`).

**Requeue a PR** — remove the `qcom-next-dispatched` label.

**Requeue a PR that hit a merge conflict** — rebase the topic branch, then
remove the `qcom-next-conflict` label.

**Force a PR to run on its own** — move its topic into a `solo: true` zone, or
dispatch `qcom-next_topic_update_manual.yml` directly with just that PR.

**Let another topic batch with anything** — give it a zone with
`wildcard: true`, placed before any broader glob that would also match it. Only
do this for a topic measured to have no file overlap with batchable topics.

**Add a new topic** — add it to `qcom-next.conf`, then classify it in
`qcom-next-batching.yaml`. Until it is classified it runs solo, which is safe
but slow.

**Make batches bigger** — raise `max_batch_size` on a zone. Larger batches mean
fewer pipeline runs but harder failure attribution.

---

## Known limitations

- **Merge conflicts are attributed, test failures are not.** A topic branch
  that fails to merge is traced to its PR and quarantined automatically. A PR
  that merges cleanly but breaks the *build or tests* is not isolated: the whole
  batch fails together and the PRs stay labelled, so requeue them individually
  by removing the label.

- **Throughput is bounded by the pipeline, not the cron.** One batch at a time
  means a backlog of solo topics drains slowly.

- **`Depends-on:` bypasses the safety zones by design.** A dependency group is
  validated as one batch even when its topics are known to overlap, so failure
  attribution inside such a batch is weaker than for a zoned batch. Declare a
  dependency only when the PRs genuinely cannot be validated apart.

- **A blocked dependency stalls its dependents.** While a prerequisite is draft,
  unmergeable or already dispatched, every PR depending on it waits. Check the
  *Skipped PRs* list in the dispatcher summary if a PR is not going out.

- **Five topics currently carry no work.** `tech/debug/rdbg`, `tech/mm/phy`,
  `tech/storage/nvmem`, `tech/virt/gunyah` and `tech/mproc/all` are ancestors
  of the baseline, so promoting them is a no-op. Their overlap could not be
  measured and their zone placement is provisional; re-measure once they land
  commits.

- **Overlap data is a snapshot.** Zones reflect the topic branches at the time
  of measurement. Re-run the overlap analysis after a major rebase, especially
  before raising any `max_batch_size`.
