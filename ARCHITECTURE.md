# Foreslået arkitektur

Dette er en målskitse, ikke en ordre om at flytte alle eksisterende filer. Undersøg først det nuværende repository.

```text
proxmox-ve-updater/
├── updater.sh
├── lib/
│   ├── common.sh
│   ├── config.sh
│   ├── logging.sh
│   ├── preflight.sh
│   ├── host_update.sh
│   ├── lxc_update.sh
│   ├── vm_update.sh
│   ├── backup_check.sh
│   ├── reboot_check.sh
│   ├── postflight.sh
│   └── report.sh
├── config/
│   └── updater.conf.example
├── tests/
│   ├── run_tests.sh
│   ├── mocks/
│   └── cases/
├── docs/
│   ├── CURRENT_STATE.md
│   ├── REQUIREMENTS.md
│   ├── TESTING.md
│   └── ARCHITECTURE.md
├── systemd/
│   ├── proxmox-updater.service
│   └── proxmox-updater.timer
├── SPEC.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Ansvarsfordeling
- `updater.sh`: CLI, argumenter og hovedflow.
- `common.sh`: fælles hjælpefunktioner og statuskonstanter.
- `config.sh`: indlæsning og validering af konfiguration.
- `logging.sh`: konsol- og fillogning uden hemmeligheder.
- `preflight.sh`: forudsætnings- og sundhedskontrol.
- `host_update.sh`: hostens opdateringsworkflow.
- `lxc_update.sh`: LXC-workflow.
- `vm_update.sh`: QEMU/VM-workflow og Guest Agent-kontrol.
- `backup_check.sh`: kontrol af tilgængelig backupinformation.
- `reboot_check.sh`: detektion af genstartsbehov.
- `postflight.sh`: kontrol efter opdatering.
- `report.sh`: samlet status og JSON-rapport.
- `tests/`: mock-baserede tests uden reelle systemændringer.

## Arkitekturprincipper
- Bash-only i første version; undgå unødvendige sprog og services.
- Hold eksisterende struktur, hvis den allerede er passende.
- Brug arrays og sikre quoting-mønstre til shell-argumenter.
- Undgå `eval` og ukontrolleret dynamisk shell-kode.
- Behandl gæstenavne, tags og input som data, ikke som kommandoer.
- Hold logik og eksterne systemkommandoer adskilt, så kommandoerne kan mockes.
- Brug én fælles statusmodel og rapportformat.
- Hold cluster-orkestrering uden for første version.
