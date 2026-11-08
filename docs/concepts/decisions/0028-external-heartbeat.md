# ADR 0028: Externer Heartbeat statt dauerhaftem Heim-Gegenpunkt

**Status:** angenommen

## Kontext

Alarme liefen bisher nur auf dem Steuerrechner (`lab-alert.py`, Desktop und Journal).
Fällt der Steuerrechner aus oder bleibt er aus, bleibt die Stille unbemerkt. Ein dauerhafter
Tunnel-Gegenpunkt zu Hause und ein eigener Handy-Alarmkanal vor dem Go-live wären zusätzliche
Betriebsflächen. Die Matrix-Senke bleibt vorerst aus (#41).

## Entscheidung

Vor dem Go-live der Produktion ist die Überwachung ein **externer Heartbeat**:

1. `lab-alert.py` sendet nach jedem Lauf einen HTTP-GET an eine
   healthchecks.io-kompatible Ping-URL (Provider wählbar: healthchecks.io, Better Stack,
   Uptime Kuma Push, …).
2. Die URL liegt in einer SOPS-Datei auf dem Steuerrechner, nie im Git.
3. Bleibt der Ping aus (Steuerrechner aus, Timer tot), meldet der externe Dienst selbst
   (zum Beispiel per E-Mail des Anbieters).
4. Es gibt keinen dauerhaften Heim-Gegenpunkt nur für die Überwachung und keinen separaten
   Handy-Alarmkanal vor dem Go-live.
5. Folge, die sichtbar bleibt: Sicherungen laufen nur, solange der Steuerrechner mit dem
   Backup-Ziel (rustfs) läuft. Das ist Absicht, kein Defekt.

## Folgen

- `backup_alert_heartbeat_enabled` ist standardmässig aus; der Betreiber legt Konto und URL
  selbst an und schaltet danach um ([Alarme](../../how-to/alerts.md)).
- Die Matrix-Senke bleibt aus, bis bewusst nach dem Go-live eingeschaltet (#41).
- Ein ausgeschalteter Steuerrechner erzeugt beim Heartbeat-Anbieter einen Alarm; das ist das
  gewünschte Signal, kein Fehlalarm.

## Siehe auch

- [Alarm bei Backup- oder Kantenausfall](../../how-to/alerts.md)
- Issue #8, Entscheid 06.11.2026
