# Proxmox VE Updater — Software Requirements Specification

- Version: 1.0
- Status: Udkast til implementering
- Repository: https://github.com/it-koncept/Proxmox-VE-Updater-

## 1. Formål
Videreudvikle det eksisterende Proxmox VE Updater-projekt til et robust, sikkert, modulært og veldokumenteret CLI-værktøj til vedligeholdelse af Proxmox VE-hosts, LXC-containere og QEMU/KVM-VM'er.

Den eksisterende kodebase er autoritativ. Funktioner må ikke fjernes eller ændres utilsigtet.

## 2. Fastlagte rammer
- Programmeringssprog: Bash.
- AI-runtime: Ollama med lokalt installeret Qwen-model. Det præcise model-ID skal verificeres med `ollama list`; brugerens oplyste navn er `Qwen3.5 Flash`.
- Udviklingsmiljø: Debian Linux.
- Brugerflade: CLI.
- Omfang: Proxmox-host, LXC og QEMU/KVM-VM'er.
- Drift: Manuel og planlagt.
- Backup: Kontrollér status for eksisterende backups. Automatisk backup er ikke et krav i første version.
- Notifikationer: Valgfrie.
- Tests: Mock-baserede; ingen reelle opdateringer under test.
- Cluster: Arkitekturen må gerne forberedes til senere udvidelse, men automatisk cluster-orkestrering er uden for første version.

## 3. Designprincipper
1. Sikkerhed og dataintegritet har højeste prioritet.
2. Bevar eksisterende adfærd, medmindre ændringen er godkendt.
3. Alle opdateringer skal kunne spores gennem logs og rapporter.
4. Risikofyldte handlinger kræver godkendelse eller eksplicit konfigureret politik.
5. Funktioner skal kunne testes uden systemændringer.
6. Koden skal være modulær, dokumenteret og vedligeholdelsesvenlig.
7. Afhængigheder skal begrænses.
8. Fejl skal håndteres eksplicit og må aldrig rapporteres som succes.

## 4. Funktionelle krav

### P0 — første brugbare version
- **FR-001:** Undersøg og bevar eksisterende funktioner, tags, CLI-adfærd og understøttede gæstetyper.
- **FR-002:** Opdatér Proxmox-hosten via en kontrolleret arbejdsgang.
- **FR-003:** Opdatér understøttede LXC-containere.
- **FR-004:** Opdatér understøttede QEMU/KVM-VM'er via understøttet kommunikationsmetode.
- **FR-005:** Tilbyd dry-run/forhåndsvisning uden installation, genstart eller ændring af gæstetilstand.
- **FR-006:** Log status, fejl og varighed pr. host, VM og container.
- **FR-007:** Kontrollér nødvendige rettigheder, diskplads, repository-status og relevante forudsætninger.

### P1 — næste trin
- **FR-008:** Understøt eksplicit valg og udelukkelse af gæster.
- **FR-009:** Detektér genstartsbehov, men genstart ikke automatisk uden særskilt godkendelse eller eksplicit politik.
- **FR-010:** Kontrollér backupstatus og advar ved manglende eller ukendt backupinformation.
- **FR-011:** Verificér gæsternes status efter opdatering.
- **FR-012:** Understøt planlagt kørsel via systemd timer; dokumentér eventuel cron-understøttelse.
- **FR-013:** Generér strukturerede rapporter, herunder JSON.

### P2 — valgfrie eller senere funktioner
- **FR-014:** Tilbyd valgfrie notifikationer.
- **FR-015:** Hold arkitekturen klar til senere cluster-understøttelse uden at implementere cluster-orkestrering i første version.

## 5. Sikkerhedskrav
- **SEC-001:** Ingen utilsigtede pakkeændringer, genstarter eller destruktive handlinger.
- **SEC-002:** Ingen automatisk restore eller sletning af backups.
- **SEC-003:** Hvis repository-opdatering fejler, må opgraderingen ikke fortsætte.
- **SEC-004:** Brug låsning mod samtidige kørsler.
- **SEC-005:** Brug timeouts, eksplicit fejlhåndtering og entydige exit codes.
- **SEC-006:** Log aldrig tokens, adgangskoder eller andre hemmeligheder.
- **SEC-007:** Valider konfiguration, tags, ID'er og brugerinput.
- **SEC-008:** Kontrollér nødvendige rettigheder før handlinger udføres.
- **SEC-009:** Ukendt distributionsversion eller utilstrækkelige forudsætninger skal håndteres sikkert.
- **SEC-010:** En fejl på én gæst skal registreres korrekt og må ikke skjules af efterfølgende succeser.
- **SEC-011:** Dry-run og testtilstand skal være sikre som standard.
- **SEC-012:** Mock-tests må aldrig udføre reelle opdateringer på hosten eller gæsterne.
- **SEC-013:** Host-/clusterstatus, herunder quorum hvor relevant, skal kontrolleres før risikofyldte handlinger.

## 6. Foreløbige CLI-kommandoer
Følgende er forslag og skal tilpasses eksisterende interface efter repository-analysen:
- `--help`
- `--version`
- `--check`
- `--dry-run`
- `--host`
- `--guests`
- `--all`
- `--list`
- `--report`
- `--test`

`--test` må kun køre testmiljøet og må aldrig være en alternativ indgang til rigtige opdateringer.

## 7. Statusmodel
Hver opgave/gæst skal som minimum kunne ende i en af disse tilstande:
- `success`
- `warning`
- `skipped`
- `failed`

Samlet exit code skal afspejle, om kørslen havde fejl. Manglende Guest Agent, timeout, stoppet gæst eller ikke-understøttet distribution må ikke rapporteres som succes.

## 8. Testkrav
Test mindst:
- Vellykket opdatering.
- Fejlet repository-opdatering; ingen efterfølgende opgradering.
- Manglende rettigheder.
- Manglende Guest Agent.
- Stoppet eller utilgængelig gæst.
- Timeout.
- Utilstrækkelig diskplads.
- Manglende backupinformation.
- Samtidige instanser.
- Fejl i en enkelt gæst.
- Gyldige og ugyldige tags.
- Dry-run uden sideeffekter.
- Gyldig JSON-rapport.
- Korrekte logs og exit codes.

Brug mockede systemkommandoer og isolerede fixtures. Kør `bash -n`, ShellCheck og automatiserede tests, når værktøjerne er tilgængelige. Dokumentér tests, der ikke kunne køres.

## 9. Definition of Done
En funktion er færdig, når:
1. Kravet er implementeret.
2. Fejlscenarier er håndteret.
3. Relevante tests er tilføjet og faktisk kørt.
4. Eksisterende funktioner er kontrolleret for regressioner.
5. Dokumentationen er opdateret.
6. Ingen utilsigtede produktionshandlinger er udført under test.
7. Resultat og begrænsninger er rapporteret ærligt.

## 10. Afgrænsning
Webdashboard, ekstern API, automatisk cluster-orkestrering og automatisk rollback er ikke del af første version. De skal have separate krav og accepttests, hvis de tilføjes senere.
