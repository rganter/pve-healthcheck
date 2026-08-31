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

## Reboot-Prüfung

Die Ursachenanalyse liest die letzten 15 Minuten des vorherigen Boots. Hinweise
auf ein unsauber geschlossenes Journal werden in den ersten fünf Minuten des
Folgeboots gesucht. Falls das vorherige Journal in diesem Zeitfenster keine
Einträge enthält, verwendet das Skript ersatzweise dessen letzte 500 Meldungen.
Dadurch bleiben auch lange beziehungsweise große Journale schnell, ohne längere
Ausfallzeiten aus der Analyse auszuschließen.

## Ausgaben richtig interpretieren

### Treffer sind nicht automatisch Vorfälle

Eine Meldung wie

```text
[WARN] Corosync link / token loss: N matching message(s) in the last 24 hour(s)
```

bedeutet N passende Journalzeilen, nicht zwingend N Cluster-Ausfälle. Ein
einziger Linkverlust erzeugt üblicherweise mehrere Meldungen, beispielsweise
`link ... is down`, `Token has not been received` und `A processor failed`.
Zeitstempel und Belegzeilen müssen deshalb gemeinsam betrachtet werden.

### Jeder Node zeigt seine lokale Sicht

Der Healthcheck liest ausschließlich lokale Daten. Ein abgestürzter Node kann
seinen eigenen Verbindungsverlust häufig nicht mehr protokollieren. Ein anderer
Cluster-Node sieht dagegen den tatsächlichen Corosync-Link- oder Tokenverlust.
Beide Ausgaben ergänzen sich:

- der betroffene Node zeigt beispielsweise ein abruptes Journalende, einen
  unsauberen Folgeboot und zeitlich passende fehlgeschlagene Tasks;
- ein weiterlaufender Peer zeigt, wann der betroffene Node aus der
  Cluster-Mitgliedschaft verschwand.

Normale Corosync-Startmeldungen wie `host has no active links` werden nicht als
Ausfall gewertet. Warnrelevant sind tatsächliche Link-Down-, Token-Timeout- oder
Quorumverlust-Hinweise.

### Reboot- und Backup-Korrelation

`Temporal correlation` bedeutet, dass ein fehlgeschlagener `vzdump`-Task
höchstens 15 Minuten vor dem neuen Boot begann. Das ist ein wichtiger Hinweis,
aber allein noch kein Beweis, dass der Backup-Job die technische Grundursache war.
Der Backup-Datenstrom kann beispielsweise einen vorhandenen Storage-, NFS-,
Netzwerk-, Treiber- oder Hardwarefehler erst unter Last sichtbar machen.

Ein `unclean journal` zusammen mit einer fehlenden PID-1-/Kernel-Shutdown-Sequenz
spricht für Crash, Watchdog-Reset oder Stromverlust. `shutdown.target` aus einer
Benutzer-Systemd-Instanz ist dagegen kein Host-Shutdown.

### I/O-Pressure

Die Storage-Prüfung liest Linux PSI aus `/proc/pressure/io`. `full` bedeutet,
dass zeitweise alle nicht-idle Tasks gleichzeitig auf I/O warten. Ein kurzfristig
erhöhter Wert ist ein Lastindikator; dauerhaft hohe Werte zusammen mit vielen
Prozessen im Zustand `D`, hohem I/O-Wait oder Watchdog-Resets weisen auf einen
systemweiten Storage-/NFS-Stall hin. PSI identifiziert nicht von selbst das
verursachende Gerät oder den Server.

### RAM und Swap

Die Speicherbewertung kombiniert den Anteil von `MemAvailable`, Linux Memory-PSI
und eine kurze Messung der aktuellen Swap-I/O-Rate. Weniger als 20 Prozent
verfügbarer RAM erzeugen allein noch keine Warnung, solange weder Memory-Pressure
noch mindestens 1 MiB/s Swap-I/O erkennbar ist. Weniger als 10 Prozent bleiben
warnrelevant; weniger als 5 Prozent oder hohe vollständige Memory-Pressure werden
kritisch bewertet. Eine hohe Swap-Belegung ohne aktuelle Swap-I/O kann von einem
früheren Lastzustand stammen und wird deshalb nur als Hinweis ausgegeben.

### Zeitraum beachten

Journalwarnungen beziehen sich auf `--hours`, Live-Prüfungen wie Quorum,
Storage-Status und I/O-Pressure dagegen auf den aktuellen Zustand. Nach einer
Korrektur kann deshalb `--hours 1` eine übersichtlichere Nachkontrolle liefern,
während der 24-Stunden-Standard weiterhin ältere Vorfälle enthält.

## Sicherheit

Das Skript führt ausschließlich lesende Prüfungen aus. Es repariert, deaktiviert oder entfernt keine Dienste, Storages, iSCSI-Verbindungen oder Clusterressourcen.

## Voraussetzungen

- Proxmox VE
- Bash
- Ausführung als `root`
- optionale Werkzeuge wie `zpool`, `iscsiadm` und `ha-manager` werden nur geprüft, wenn sie installiert beziehungsweise relevant sind

## Lizenz

MIT – siehe [LICENSE](LICENSE).
