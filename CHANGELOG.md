# Changelog

Alle wesentlichen Änderungen an diesem Projekt werden hier dokumentiert.

## Unreleased

- kombinierte RAM-Bewertung aus verfügbarem Speicher, Memory-PSI und aktueller
  Swap-I/O statt einer alleinigen Warnschwelle von 20 Prozent
- Boot-Startabfrage beendet den JSON-Journalstrom nach dem ersten Eintrag, statt
  jeden Boot vollständig zu dekodieren
- README um Interpretationshilfen für Trefferzahlen, lokale Node-Sicht,
  Backup-Reboot-Korrelation, I/O-Pressure und Prüfzeitraum ergänzt
- schnellere Reboot-Analyse durch begrenzte Journalfenster vor und nach dem Boot
- einheitliche neutrale Farbe für alle Einträge im Menü der Einzelprüfungen
- saubere Host-Shutdowns werden nur noch aus PID-1- und Kernelmeldungen abgeleitet;
  `shutdown.target` aus Benutzer-Systemd-Instanzen erzeugt keinen Fehlbefund mehr
- Erkennung eines beschädigten beziehungsweise unsauber geschlossenen Journals im Folgeboot
- zeitliche Korrelation fehlgeschlagener `vzdump`-Tasks mit lokalen Reboots
- Anzeige aktueller vollständiger Linux-I/O-Pressure bei der Storage-Prüfung
- präzisere Storage-/NFS-Fehlermuster ohne generische Sensor-`I/O error`-Treffer
- Corosync-Startmeldungen werden von echten Link-, Token- und Quorumverlusten getrennt
- Erkennung von Reboots im gewählten Prüfzeitraum
- Ursachenanalyse anhand des vorherigen Boot-Journals mit Belegzeilen
- übersichtlicheres, farbiges Terminal-Menü mit gruppierten Prüfungen
- erneute Menüabfrage bei ungültiger Auswahl
- interaktives Menü für vollständige und einzelne Healthchecks
- nicht-interaktive Auswahl über `--all` und `--check NAME`
- Backup-Zusammenfassung für abgeschlossene `vzdump`-Tasks
- detaillierte Backup-Prüfung mit Task-Logs fehlgeschlagener Backups
- paginierte, versionskompatible Abfrage der Task-Historie je Cluster-Node
- lokale Filterung nach Zeitraum und `vzdump` für ältere PVE-Versionen
- Ausgabe des tatsächlichen Proxmox-Fehlers, falls die Task-Abfrage scheitert
- vollständige Logs fehlgeschlagener Backups über `pvenode task log`
- eindeutige Kennzeichnung nicht erfolgreicher Task-Status als `FAILED`

## 0.1.0 – 2026-08-20

- erster öffentlicher Stand
- Prüfung von Cluster, Quorum und QDevice
- Ausgabe aller PVE- und Quorum-Mitglieder
- Prüfung der HA-Dienste und HA-Ressourcen
- RAM-, Swap- und ZFS-ARC-Auswertung
- Prüfung von ZFS-Pools und Proxmox-Storages
- Erkennung aktiver und veralteter iSCSI-Einträge
- zusammengefasste Auswertung kritischer Journalmeldungen
- konfigurierbarer Journalzeitraum über `--hours`
- Exit-Codes für Monitoring und Automatisierung
