# PVE Healthcheck

Ein rein lesendes Healthcheck-Skript für Proxmox-VE-Hosts. Es prüft typische Fehlerbilder rund um Cluster, HA, ZFS, Storage, iSCSI und relevante Kernelmeldungen, ohne Änderungen am Host vorzunehmen.

## Prüfungen

- Proxmox-Version, Kernel und Uptime
- fehlgeschlagene systemd-Dienste
- Clusterquorum und QDevice
- alle PVE-Cluster-Nodes und die aktuelle Quorum-Mitgliedschaft
- HA-Dienste, Autostart und Ressourcenstatus
- RAM- und Swap-Auslastung
- ZFS-ARC-Größe und explizites ARC-Limit
- Zustand aller importierten ZFS-Pools
- Status aller Proxmox-Storages
- aktuelle Linux-I/O-Pressure als Hinweis auf systemweite Storage-Stalls
- aktive und veraltete iSCSI-Einträge
- abgeschlossene und fehlgeschlagene `vzdump`-Backup-Tasks
- Neustarts und mögliche Ursachen aus dem Journal des vorherigen Boots; saubere
  Host-Shutdowns werden nur anhand von PID 1 beziehungsweise Kernelmeldungen erkannt
- zeitliche Korrelation fehlgeschlagener `vzdump`-Tasks mit nachfolgenden Reboots
- OOM-, i915-, Watchdog-, Kernel-Stall-, I/O- und Corosync-Meldungen

## Installation

```bash
wget https://raw.githubusercontent.com/rganter/pve-healthcheck/main/pve-healthcheck.sh
chmod +x pve-healthcheck.sh
```

Alternativ kann das Repository geklont werden:

```bash
git clone https://github.com/rganter/pve-healthcheck.git
cd pve-healthcheck
chmod +x pve-healthcheck.sh
```

## Verwendung

Als `root` auf dem zu prüfenden PVE-Host:

```bash
./pve-healthcheck.sh
```

Bei interaktiver Ausführung erscheint ein Menü. Dort kann entweder der
vollständige Healthcheck oder eine einzelne Prüfung ausgewählt werden. Für
Automatisierungen stehen dieselben Modi ohne Menü zur Verfügung:

```bash
./pve-healthcheck.sh --all
./pve-healthcheck.sh --check backups
./pve-healthcheck.sh --check storage
```

Wenn die Ein- oder Ausgabe nicht mit einem Terminal verbunden ist, führt das
Skript ohne weitere Rückfrage automatisch den vollständigen Healthcheck aus.

Standardmäßig werden für die Journalanalyse die letzten 24 Stunden betrachtet. Der Zeitraum lässt sich eingrenzen:

```bash
./pve-healthcheck.sh --hours 1
./pve-healthcheck.sh --hours 6
./pve-healthcheck.sh --hours 168
```

Farben deaktivieren, beispielsweise für eine Logdatei:

```bash
./pve-healthcheck.sh --no-color
```

Hilfe anzeigen:

```bash
./pve-healthcheck.sh --help
```

## Exit-Codes

| Code | Bedeutung |
|---:|---|
| `0` | keine Befunde |
| `1` | Warnungen vorhanden |
| `2` | kritische Befunde oder ungültiger Aufruf |

Die Exit-Codes können von Monitoring-Systemen oder Automatisierungen ausgewertet werden.

## Backup-Prüfung

Der vollständige Healthcheck zeigt für den gewählten Zeitraum die Anzahl aller
abgeschlossenen `vzdump`-Tasks sowie die Zahl der erfolgreichen und
fehlgeschlagenen Tasks. Der Menüpunkt **Backup details and error logs**
beziehungsweise `--check backups` listet zusätzlich die einzelnen Tasks auf
und gibt für fehlgeschlagene Backups das zugehörige Proxmox-Task-Log aus.

Beim vollständigen Check werden fehlgeschlagene Backups außerdem mit lokalen
Reboots korreliert, wenn der Task höchstens 15 Minuten vor dem neuen Boot begann.
Das weist auf einen zeitlichen Zusammenhang hin, behauptet aber nicht automatisch
eine eindeutige Ursache.

Der Zeitraum wird auch hier mit `--hours` festgelegt. Standard sind 24 Stunden.

## Sicherheit

Das Skript führt ausschließlich lesende Prüfungen aus. Es repariert, deaktiviert oder entfernt keine Dienste, Storages, iSCSI-Verbindungen oder Clusterressourcen.

## Voraussetzungen

- Proxmox VE
- Bash
- Ausführung als `root`
- optionale Werkzeuge wie `zpool`, `iscsiadm` und `ha-manager` werden nur geprüft, wenn sie installiert beziehungsweise relevant sind

## Lizenz

MIT – siehe [LICENSE](LICENSE).
