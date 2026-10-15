# CURRENT_STATE — Fase A-analyse

Dato: 2026-10-15. Analyse uden kodeændringer. Alle fund er verificeret med kommandoer.

## 1. Repository-tilstand

| Sted | Status |
|---|---|
| `/home/hermes/Proxmox-VE-Updater` | Kun dokumentation (SPEC, PLAN, ARK, TESTING, AGENTS, README, QWEN_PROMPT). **Ikke en git-repo.** |
| `github.com/it-koncept/Proxmox-VE-Updater-` | Autoritativ repo. `main` @ `c00aaec`, working tree clean (klon: `~/.hermes/cache/scratch/pvupd`). |
| `prod-node:/root/update-vms.sh` (<lan-ip>) | md5 `eee67b2574231ac59b4b9465a7882608` = **identisk med repo-HEAD**. `update-vms.sh.v1.bak` ligger også på hosten. |

Repræsentation af repo: `update-vms.sh` (131 linjer), `README.md`, `CHANGELOG.md`, `LICENSE`, `.gitignore` (ignorerer `mockbin/`, `*.bak`, `v1.sh`). **Ingen tests, ingen lib/, ingen config-fil, ingen systemd-filer.**

## 2. Eksisterende funktionalitet (update-vms.sh v2)

- Gæster på lokal node via `pvesh get /cluster/resources --type vm` + jq-filter på node.
- Tag-styring (eksakt match pr. `;`-separeret tag, case-insensitive): `apt` → noninteractive apt-get update && upgrade (confdef/confold), `yum` → dnf ellers yum, `windows` → skip.
- Kun kørende gæster; numerisk VMID-validering; malformed-entry-guard.
- `flock`-lås (`/var/lock/update-vms.lock`), `qm guest exec --timeout` (std 1800 s, `QEMU_EXEC_TIMEOUT`), `PVE_NODE`-override.
- Pr. gæst: rc-tjek (`pct exec` rc / `qm guest exec` `.exitcode` via jq), fejl-log med output-tail, OK/FAIL/SKIP-tælling, exit ≠ 0 ved fejl.
- `--dry-run`: printer kun kommandoer, ingen udførsel.
- Ingen cron-entry er faktisk installeret på prod-node (README foreslår det); ingen systemd timer.

## 3. Krav-kortning

### Allerede opfyldt (delvist eller fuldt)
| Krav | Status | Bemærkning |
|---|---|---|
| FR-003 LXC | ✅ | `pct exec`, men ingen timeout på pct-siden |
| FR-004 QEMU | ⚠️ | Mekanisme OK (`qm guest exec` + timeout), men **alle 4 QEMU-VMs (102,104,130,147) har `agent` IKKE konfigureret** → yum-gæsterne 102/104 fejler altid |
| FR-005 dry-run | ✅ | Ingen sideeffekter; validerer dog ingen præmisser |
| FR-006 log | ⚠️ | Tidsstemplede linjer + pr. gæst rc; ingen logfil som standard, ingen varighed pr. gæst |
| FR-007 præmisser | ⚠️ | Kun VMID + running; ingen rod-/diskplads-/repo-tjek |
| FR-012 planlagt | ⚠️ | Kun cron-dokumentation; intet installeret, ingen timer |
| SEC-003 repo-fejl stopper upgrade | ✅ | `apt-get update && upgrade` er &&-kædet i gæsten |
| SEC-004 lås | ✅ | flock -n |
| SEC-005 exit codes | ⚠️ | OK for gæster; mangler pipefail/pvesh-fejlhåndtering, pct-timeout |
| SEC-007 validering | ⚠️ | VMID + tags OK; ingen konfig-validering (ingen konfig findes) |
| SEC-010 fejl skjules ikke | ✅ | FAIL-tæller + non-zero exit |
| SEC-011 dry-run sikker | ✅ | |

### Manglende krav
FR-002 (host-opdatering), FR-008 (inkluder/ekskluder gæster), FR-009 (genstartsdetektion), FR-010 (backupstatus), FR-011 (postflight), FR-013 (JSON-rapport), FR-014 (notifikationer), FR-015 (cluster-forberedelse).
SEC-008 (rod-tjek), SEC-009 (distribution/forudsætninger), SEC-012 (testsuite — mockbin/ blev slettet fra repo i `c00aaec`), SEC-013 (værtsstatus).
CLI fra SPEC §6 (`--check --list --report --host --guests --all --test --version`) findes ikke; kun `--dry-run`.

## 4. Sikkerhedsrisici og fejlscenarier (verificeret)

1. **Stille succes ved pvesh/jq-fejl:** hvis `pvesh` fejler eller `jq` mangler, bliver input tomt/all-felter tomme → alle gæster "skipped" → exit 0 = falsk succes. (SEC-010-brist i praksis.)
2. **Ingen rod-tjek:** kørt som ikke-root fejler pct/qm per gæst, låsefil kan være utilgængelig; scriptet fortsætter.
3. **Ingen timeout på `pct exec`:** en hængende LXC-kommando blokerer låsen på ubestemt tid.
4. **QEMU-gæster uden Guest Agent** (102, 104, 130, 147 — `qm config` bekræftet): rapporteres som failed (korrekt), men betyder at yum-workflowen aldrig virker på denne fleet i dag.
5. **Ingen diskplads-tjek** i gæst før upgrade — risk for proppet root-FS under apt.
6. **Ingen logfil/rotation som standard**; cron-eksemplet append'er uendeligt.
7. **`set -u` uden `pipefail`:** brud i `pvesh | jq`-pipeline registreres ikke.
8. **Backup:** storage `Backup` er **PBS** (ikke dir) — backupstatus skal læses via PBS/job-API; mange gæster er kun dækket af ugentligt all=1-job (sun 01:00, keep-last 14); dagligt job (23:30) dækker kun 146,1136,141,147,150.

## 5. Ollama / model

- `ollama` er **ikke installeret** på denne udviklermaskine, ej heller på prod-node.
- <lan-ip>:11434 og :1919 svarer ikke pt.
- LXC 155 `<internal-service>` på prod-node er **stopped**.
- Model-ID `Qwen3.5 Flash` kan **ikke verificeres** (`ollama list` utilgængeligt). Kravet om AI-runtime har desuden intet funktionelt krav i SPEC.md — afgrænsning mangler.

## 6. Værktøjer

- Udviklermaskine: `bash -n` ✅ (scriptet passerer), **shellcheck ikke installeret**, pytest/ctest irrelevant.
- prod-node: jq 1.6 ✅, ingen shellcheck, PVE 8.4.21, kernel 6.8.12-20-pve.
- Mocks: tidligere `mockbin/` (pvesh, pct) findes lokalt i scratch men er gitignored — genoprettes som `tests/mocks/`.

## 6b. Brugerbeslutninger (2026-10-15, efter Fase A)

1. **Arbejdssted:** GitHub-repo'et er klonet til `/home/hermes/Proxmox-VE-Updater`; dokumenterne ligger i repoet som untracked filer og committes som første Fase B-opgave.
2. **QEMU/Guest Agent:** 102/104/130/147 aktiveres IKKE nu. QEMU-workflow må kun rapportere `skipped`/`failed` ved manglende agent — aldrig succes. Fokus: LXC/apt.
3. **Ollama:** udgår helt. Ingen AI-del i værktøjet; model-kravet i SPEC §2 slettes fra scope.
4. **Host-opdatering (FR-002):** kun via eksplicit flag + interaktiv bekræftelse; `dist-upgrade`; aldrig automatisk/timer-kørsel uden `--yes`-lignende eksplicit politik.
5. **CLI/drift:** bagudkompatibel entrypoint (`update-vms.sh --dry-run` skal fortsat virke); systemd service/timer leveres som filer + dokumentation, installeres IKKE på prod-node uden særskilt godkendelse.

## 7. Konklusion

Deployet kode = repo-HEAD = v2. Basis-gæsteopdatering virker for LXC/apt; QEMU-delen er død på denne fleet pga. manglende Guest Agent. Hele P1/P2-sættet (rapport, backup-tjek, preflight, validering, tests, CLI-omfang) mangler. Største strukturelle brist: ingen tests overhovedet og ingen adskillelse af kommandoafvikling fra logik.

## 8. Status efter Fase B (opdateret 2026-10-15)

Fase B (B1–B8) er gennemført på branch `feat/fase-b-hardening` (ikke pushet, ikke deployet):

| Fase | Levering | Commit |
|---|---|---|
| B1 | Dokumenter i git + CURRENT_STATE | `59b52d2` |
| B2 | Mock-testsuite (PATH-shadowing, call-log) | `a46f95c` |
| B3 | v3-hårdning: preflight, pvesh-fejl, timeout, exitkoder | `5335d33` |
| B4 | v3.1 CLI: `--version/--list/--check/--only/--exclude` | `f4559a1` |
| B5 | v3.2 sikkerheds-præflight: disk, agent, backup-dækning | `c44c9a3` |
| B6 | v3.3 JSON-rapport, logfil, statusmodel | `49f09fc` |
| B7 | v3.4 `--host` med politik-gates + kvorum-fix | `3c71ae8`, `7cb835c` |
| B8 | systemd service/timer + logrotate + driftsdok | denne commit |

Tests: 63/63 bestået (mock-baseret), ShellCheck ren, `systemd-analyze verify` grön.
**Deployet 2026-10-15:** `prod-node:/root/update-vms.sh` = v3.4.0 (v2 backup:
`/root/update-vms.sh.v2.bak`, md5 `eee67b2574231ac59b4b9465a7882608`).
Deploy-anledning: v2 ignorerede ukendte flags — `--help` på v2 udløste en
**faktisk opdateringskørsel** på prod-node (107/157/159 opgraderet, alle rene
bagefter; CT 141 halvsønder af ældre afbrudt dist-upgrade (bullseye→trixie),
repareret ved at færdiggøre dist-upgraden, godkendt af bruger).
Resterende beslutninger: push til GitHub, evt. QEMU-agenter, CT 122/123
(Debian 9 stretch EOL — kan ikke opgraderes som de er).
