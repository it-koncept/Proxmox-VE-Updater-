# Teststrategi

## Hovedregel
Tests må aldrig installere, fjerne eller opgradere pakker, genstarte systemer eller ændre tilstanden på rigtige VM'er eller containere.

## Testdesign
- Mock eksterne kommandoer ved at placere testimplementeringer tidligere i `PATH`.
- Brug midlertidige mapper til logs, konfiguration og rapporter.
- Brug fixtures for gæstelister, tags og kommandoresultater.
- Kontrollér både stdout/stderr, exit codes, logs og sideeffekter.
- Tilføj negative tests for hver kritisk arbejdsgang.
- Kør ikke tests som root på produktionssystemer.

## Påkrævede testscenarier
1. Repository-opdatering fejler: opgradering må ikke startes.
2. Manglende rettigheder: tydelig fejl før ændringer.
3. Guest Agent mangler: gæst rapporteres ikke som succes.
4. Gæst er stoppet: følg eksplicit politik; ingen utilsigtet opstart.
5. Timeout: kommando stoppes/håndteres, og resultat registreres.
6. Diskplads under grænsen: sikker afbrydelse.
7. Backupstatus ukendt eller gammel: advarsel eller stop efter konfiguration.
8. Låsen er optaget: anden instans afvises.
9. En gæst fejler, andre lykkes: samlet rapport viser begge resultater.
10. Ugyldigt tag/ID: input afvises.
11. Dry-run: ingen muterende kommandoer udføres.
12. JSON: rapporten kan parses og indeholder alle gæster.
13. Hemmeligheder: følsomme værdier må ikke forekomme i logs.
14. Testtilstand: mock-kommandoer bekræfter, at ingen reelle opdateringsværktøjer blev kaldt.

## Kontroller
Kør, når tilgængeligt:
```bash
bash -n updater.sh
shellcheck updater.sh lib/*.sh
./tests/run_tests.sh
```

Tilpas kommandoerne til den faktiske filstruktur. Hvis ShellCheck eller andre værktøjer ikke er installeret, dokumentér det; påstå ikke, at kontrollen er bestået.

## Testresultat
For hver test rapporteres:
- Navn og formål.
- Forventet resultat.
- Faktisk resultat.
- Exit code.
- Bestået/fejlet/ikke kørt.
