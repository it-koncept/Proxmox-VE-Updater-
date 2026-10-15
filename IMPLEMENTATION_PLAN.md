# Prioriteret implementeringsplan

## Fase 0 — Analyse uden kodeændringer
**Mål:** Forstå den faktiske kodebase før ændringer.
- Kontrollér Git-status, branch og lokale ændringer.
- Læs README, alle relevante scripts, konfigurationer og tests.
- Kortlæg CLI, tags, gæsteudvælgelse, pakkehåndtering og fejlflow.
- Identificér funktioner, der allerede opfylder kravene.
- Opret `docs/CURRENT_STATE.md` og en risikoliste.
- Fremlæg plan og vent på godkendelse.

**Accept:** Ingen produktionskode ændret; analyse og plan er dokumenteret.

## Fase 1 — Sikkert fundament (P0)
- Argument- og konfigurationsvalidering.
- Ensartet logging og exit codes.
- Låsning mod samtidige kørsler.
- Timeout-håndtering.
- Dry-run-design.
- Testharness og mocks af farlige kommandoer.

**Accept:** Testtilstand kan ikke nå reelle opdateringskommandoer; fejl kan testes deterministisk.

## Fase 2 — Opdateringsmotor (P0)
- Host-opdatering.
- LXC-opdatering.
- QEMU/KVM-opdatering.
- Bevar eksisterende tags og gæsteudvælgelse.
- Ensartede statusser: success, warning, skipped, failed.
- Fejl i repository-opdatering stopper opgraderingen.

**Accept:** Alle arbejdsgange har positive og negative tests; ingen gæst rapporteres som succes ved fejl.

## Fase 3 — Sundhed og rapportering (P1)
- Preflight: rettigheder, diskplads, repository-status og relevante sundhedstjek.
- Backupstatuskontrol.
- Genstartsdetektion uden automatisk genstart som standard.
- Postflight-kontrol.
- JSON-rapport.

**Accept:** Rapporten identificerer hver gæsts resultat, fejl og advarsler.

## Fase 4 — Planlagt drift og notifikationer (P1/P2)
- systemd service og timer.
- Dokumenteret konfiguration og sikker standardadfærd.
- Valgfrie notifikationer via konfigurerede integrationer.
- Sikring af, at automatiske kørsler følger godkendelses- og genstartspolitikker.

**Accept:** Manuel og planlagt kørsel virker; fejl er synlige i logs og rapporter.

## Fase 5 — Regression og release
- Kør hele mock-testpakken.
- Kør `bash -n` og ShellCheck.
- Gennemgå diff og dokumentation.
- Kontrollér installations- og opgraderingsvejledning.
- Dokumentér kendte begrænsninger og testresultater.

**Accept:** Ingen kendte kritiske fejl; alle ikke-kørte tests er tydeligt dokumenteret.

## Senere fase
- Cluster-aware vedligeholdelse.
- Webdashboard eller API.
- Avancerede backup- og rollback-workflows.

Disse funktioner må ikke snige sig ind i første release uden godkendelse.
