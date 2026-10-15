# Instruktioner til kodningsagenten

- Læs `SPEC.md`, `IMPLEMENTATION_PLAN.md`, `ARCHITECTURE.md` og `TESTING.md` før implementering.
- Start med analyse uden kodeændringer.
- Undersøg den faktiske kodebase; antag ikke, at foreslået struktur allerede findes.
- Bevar eksisterende funktionalitet og CLI-kompatibilitet.
- Implementér én lille opgave ad gangen.
- Stop og bed om godkendelse før større ændringer eller risikofyldte handlinger.
- Mock alle opdaterings-, genstarts- og destruktive kommandoer i tests.
- Testtilstand må ikke kunne nå reelle opdateringskommandoer.
- Kør tests og statisk kontrol, og rapportér kun resultater, der faktisk er verificeret.
- Opfind ikke API'er, Proxmox-funktioner eller testresultater.
- Undgå `eval`, ukontrolleret shell-expansion og hemmeligheder i logs.
- Opdatér dokumentation sammen med kode.
- Ingen automatisk genstart, restore eller backup-sletning uden særskilt godkendelse og eksplicit politik.
- Cluster-orkestrering og webdashboard er uden for første version.
