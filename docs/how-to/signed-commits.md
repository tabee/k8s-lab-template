---
title: SSH-Commit-Signatur einrichten
---

# SSH-Commit-Signatur einrichten

Commits auf `main` tragen eine SSH-Signatur eines **eigenen Signierschlüssels**. Die Liste der erlaubten Schlüssel
ist `.gitea/allowed_signers`. Gitea und `lab.sh` lesen dieselbe Liste
([Quellvertrauen](../concepts/source-trust.md), [ADR-0023](../concepts/decisions/0023-signed-main-and-source-trust.md)).
Es braucht kein GnuPG.

## Warum ein eigener Schlüssel

Verwende nicht deinen allgemeinen Anmeldeschlüssel (`~/.ssh/id_ed25519`): er entscheidet nicht darüber, was ins Lab
kommt. Nimm einen Schlüssel, der **nur**
signiert, zum Beispiel `~/.ssh/k8s-lab-signing`:

- Der Anmeldeschlüssel liegt auf vielen Servern in `authorized_keys`. Ein Schlüssel, der nirgends zum Anmelden
  taugt, kann im Verlust- oder Diebstahlsfall ohne Folgen für die Zugänge ersetzt werden.
- Der Wechsel ist ein kleiner, geübter Ablauf ([Schlüsselwechsel](#schluesselwechsel)) und berührt nichts anderes.

Einmal anlegen (mit Passphrase; das Skript legt nie einen Schlüssel an und liest nie den privaten Teil):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k8s-lab-signing -C k8s-lab-signing
ssh-add ~/.ssh/k8s-lab-signing          # Git signiert über den ssh-agent
```

## Voraussetzungen

- `git` 2.34 oder neuer, `ssh-keygen` (OpenSSH 8.0 oder neuer)
- der Signierschlüssel liegt im `ssh-agent`, damit `git commit` nicht jedes Mal nach der Passphrase fragt
- der öffentliche Teil ist in deinem Gitea-Konto eingetragen (**Einstellungen → SSH- / GPG-Schlüssel**), denn
  Gitea prüft „Signierte Commits verlangen“ mit den Schlüsseln des Kontos. Ob Gitea zusätzlich
  `.gitea/allowed_signers` liest, hängt von der Version ab; trage den Schlüssel in jedem Fall an beiden Orten ein.

## Voraussetzungen in Gitea {#voraussetzungen-gitea}

Mit «Signierte Commits verlangen» prüft Gitea jeden Push auf `main` selbst. Dabei zählt nicht `.gitea/allowed_signers`, sondern nur das Gitea-Konto. Ein SSH-signierter Commit gilt erst als verifiziert, wenn beides stimmt:

1. **Signaturschlüssel im Konto und verifiziert.** Unter Einstellungen > SSH-/GPG-Schlüssel den Inhalt von `~/.ssh/k8s-lab-signing.pub` hinzufügen und danach «Verifizieren» wählen. Gitea zeigt ein Token; dieses signieren und die Ausgabe einfügen:

   ```bash
   echo -n '<token>' | ssh-keygen -Y sign -n gitea -f ~/.ssh/k8s-lab-signing
   ```

2. **Committer-E-Mail aktiviert.** Die E-Mail aus `git config user.email` muss eine aktivierte Adresse dieses Kontos sein.

Verschickt die Gitea-Instanz keine Mails, kommt kein Aktivierungslink an. Dann aktiviert ein Administrator die Adresse unter Administration > Benutzerkonten > E-Mails mit einem Klick auf das Kreuz in der Spalte «Aktiviert».

Fehlt eines davon, weist Gitea den Push nur mit `pre-receive hook declined` und `Internal Server Error (no message for end users)` ab. Den eigentlichen Grund zeigt das Server-Log:

```bash
sudo docker service logs --timestamps --since 30m gitea_gitea 2>&1 | grep -E 'verifyCommits|Unverified'
```

oder in Grafana/Loki `{service="gitea_gitea"}`. Eine Zeile `Unverified commit: <sha>` heisst: Schlüssel oder E-Mail fehlen im Konto. Nach der Korrektur geht derselbe Push ohne neues Signieren durch.

## 1. Git einrichten

```bash
bash scripts/setup-signing.sh --dry-run                 # zeigt nur, was sich ändern würde
bash scripts/setup-signing.sh                           # Schlüssel ~/.ssh/k8s-lab-signing, gilt für diesen Klon
bash scripts/setup-signing.sh ~/.ssh/anderer-schluessel # ein anderer Schlüssel (privat oder .pub angeben)
```

Das Skript setzt in **diesem Klon** (Standard) `gpg.format ssh`, `user.signingkey`, `commit.gpgsign true` und
`gpg.ssh.allowedSignersFile .gitea/allowed_signers` (relativ, der Klon darf verschoben werden). Es trägt den Schlüssel
in `.gitea/allowed_signers` ein, falls er fehlt, und sagt am Ende, was noch von Hand fehlt (`ssh-add`, Gitea-Konto).
Zweimal ausführen ist unschädlich.

Mit `--global` gelten die Einstellungen für alle Repos. Den Pfad zur Liste setzt das Skript dann nicht, weil er
vom Repo abhängt; in jedem Klon, in dem du prüfen willst: `git config gpg.ssh.allowedSignersFile .gitea/allowed_signers`.

## 2. Den Schlüssel freigeben {#schluessel-freigeben}

Die Datei `.gitea/allowed_signers` bekommt eine Zeile `* namespaces="git" ssh-ed25519 AAAA... Kommentar`. Der
erste Commit, der sie füllt, kann sich nicht selbst freigeben (die Liste kommt immer aus dem Stand **davor**):
solange sie leer ist, warnt die CI nur. Danach gilt sie.

```bash
git add .gitea/allowed_signers
git commit -m "Allow my commit signing key"
git push
git log --show-signature -1
```

Die letzte Zeile muss `Good "git" signature` zeigen. Merke dir die Commit-ID (`git rev-parse HEAD`): ab diesem
Commit gilt die Signatur, sie ist auch der erste Anker für
[`lab.sh trust init`](github-push-mirror.md#vertrauten-commit-festlegen).

## 3. Gitea: Branch-Schutz für `main` {#branch-schutz}

In Gitea unter **Einstellungen → Branches → Regel für `main`**. So ist `main` eingestellt:

| Einstellung | Wert |
|---|---|
| Push | nur Whitelist: du allein |
| Merge | nur Whitelist: du allein |
| Force-Push | nicht erlaubt |
| **Signierte Commits verlangen** | an |
| Geschützte Dateien | `.gitea/allowed_signers`, `.gitea/workflows/*` |
| Administratoren müssen die Regeln befolgen | an |
| Statusprüfungen | aus (gemergt wird lokal, siehe unten) |
| Merge-Stil | nur „Fast-Forward only“ |
| „Manuell mergen“ | an |
| Manuellen Merge automatisch erkennen | an |

Pull-Requests bleiben im Repo eingeschaltet: sie sind der Ort für Prüfung und Diskussion, gemergt wird aber lokal.
Die Git-Einstellungen dazu (`gpg.format ssh`, `user.signingkey ~/.ssh/k8s-lab-signing.pub`, `commit.gpgsign true`,
`gpg.ssh.allowedSignersFile .gitea/allowed_signers`) setzt `setup-signing.sh` nur in diesem Klon, nicht global.

Wer nicht auf der Whitelist steht (zum Beispiel ein Assistent), kann nur Feature-Branches pushen und
Pull-Requests öffnen. Der tägliche Ablauf steht in [Alltag mit signierten Commits](alltag-signierte-commits.md). Seine Commits sind nicht signiert; **du** bringst sie signiert nach `main`
([Pull-Request signiert übernehmen](#pr-signiert-uebernehmen)).

Der Workflow `signature-check.yml` ist die zweite Linie: er prüft jeden Push auf `main` und färbt ihn rot. Er ersetzt
den Branch-Schutz nicht, denn wer den Workflow im selben Push ändert, führt die geänderte Fassung aus. Deshalb sind
die Workflows geschützte Dateien. Auf Feature-Branches läuft er nicht: dort sind unsignierte Commits gewollt.

## 4. Pull-Request signiert übernehmen {#pr-signiert-uebernehmen}

Die Schaltfläche „Mergen“ in Gitea geht nicht: sie erzeugt Commits, die Gitea selbst signiert oder gar nicht, und das
sind keine erlaubten Signer. Ein lokaler `git merge --no-ff -S` hilft auch nicht: er signiert nur den Merge-Commit,
die unsignierten Commits des Branches kommen mit und werden abgewiesen (die Test-Suite prüft genau das). Der Weg, der
funktioniert: die Commits des Branches mit deinem Schlüssel **neu signieren** und `main` per Fast-Forward vorrücken.

```bash
git switch main && git pull --ff-only
bash scripts/merge-signed.sh feature/mein-branch          # lokal, schiebt nichts
git log --show-signature -3                               # Sichtprüfung: Good "git" signature
git push origin main
git push origin --delete feature/mein-branch              # danach den Pull-Request schliessen
```

Oder alles in einem Schritt mit `bash scripts/merge-signed.sh feature/mein-branch --push`. Das Skript

1. holt den Stand, verlangt einen sauberen Arbeitsbaum und eingerichtetes Signieren,
2. spielt den Branch auf `origin/main` neu ab (`git rebase --force-rebase -S`): die Autoren bleiben, Committer und
   Signatur sind deine, der Verlauf bleibt linear,
3. prüft jeden neuen Commit mit `scripts/check-commit-signatures.sh`, genau wie die CI,
4. rückt `main` nur per Fast-Forward vor (nie ein Merge-Commit, nie ein Force),
5. pusht nur mit `--push`.

Bei einem Fehler bleibt alles unverändert: kein Zwischenbranch, nichts gepusht. Ein Konflikt beim Neuabspielen heisst:
der Branch muss zuerst auf den aktuellen `main` nachgezogen werden. Die Commits haben nach dem Neusignieren andere IDs;
Gitea schliesst den Pull-Request deshalb nicht von selbst. Schliesse ihn von Hand.

Wer lieber **einen** Commit will: `git merge --squash origin/feature/mein-branch && git commit -S -m "..."` und
pushen. Dabei geht die Einzelhistorie verloren.

## Prüfen

```bash
# alle Commits eines Bereichs, mit der Schlüsselliste des Ausgangsstands
bash scripts/check-commit-signatures.sh --before <ALT> --after <NEU>

# eine einzelne Prüfung, wie lab.sh sie macht
bash scripts/lab-trust.sh verify <COMMIT>
```

## Schlüsselwechsel {#schluesselwechsel}

`.gitea/allowed_signers; .gitea/workflows/*` sind geschützte Dateien: Gitea weist Pushes ab, die sie ändern. Für
den Wechsel nimmst du deshalb in der Branch-Regel für `main` die geschützte Datei `.gitea/allowed_signers`
**vorübergehend** heraus und setzt die Regel nach Schritt 3 **sofort** wieder. Die Liste kommt für jeden Push aus
dem Stand **davor**: der neue Schlüssel wird mit einem Commit eingetragen, den der **alte** Schlüssel signiert.

1. Neuen Schlüssel anlegen (`ssh-keygen -t ed25519 -f ~/.ssh/neuer-schluessel -C k8s-lab-signing`), `ssh-add`, in Gitea
   eintragen. Eine Zeile `* namespaces="git" ssh-ed25519 AAAA... Kommentar` für ihn in `.gitea/allowed_signers`
   ergänzen (Typ und Schlüssel aus `~/.ssh/neuer-schluessel.pub`), noch mit dem **alten** Schlüssel committen und pushen.
   Jetzt gelten beide.
2. `bash scripts/setup-signing.sh ~/.ssh/neuer-schluessel` stellt `user.signingkey` um. Einen Commit signieren und
   pushen: das ist die Probe, dass der neue Schlüssel durch den Schutz kommt.
3. Die Zeile des alten Schlüssels entfernen, mit dem **neuen** signieren, pushen.
4. Den Anker auf einen Commit ab Schritt 2 setzen (`bash scripts/lab.sh trust init <COMMIT>`), den alten Schlüssel aus
   dem Gitea-Konto löschen und die Dateien des alten Schlüssels sicher entsorgen.

Zum Schluss prüfen, dass die Branch-Regel wieder `.gitea/allowed_signers; .gitea/workflows/*` als geschützte
Dateien führt.

Ging der alte Schlüssel verloren oder wurde er gestohlen: Schritt 1 geht nicht, weil nichts mehr mit dem alten
Schlüssel signiert. Dann die Regel wie eben vorübergehend lockern, auf dem Steuerrechner einen Commit mit dem neuen
Schlüssel erzeugen, die Liste in Gitea (Admin-Zugang) ersetzen, den Anker mit `bash scripts/lab.sh trust init <COMMIT>`
neu setzen und die Regel wieder schliessen. Ab dem Wechsel gelten nur Commits des neuen Schlüssels.

## Fehlersuche

| Meldung | Ursache |
|---|---|
| `error: Load key ... incorrect passphrase supplied` | Schlüssel nicht im Agent: `ssh-add ~/.ssh/k8s-lab-signing` |
| `No principal matched` | Zeile fehlt oder `namespaces="git"` fehlt in `.gitea/allowed_signers` |
| `error: gpg.ssh.allowedSignersFile needs to be configured` | in diesem Klon fehlt die Einstellung: `bash scripts/setup-signing.sh` |
| `FAIL ... no allowed signer in its parent` (`lab-trust.sh`) | der Commit wurde vor dem Eintrag des Schlüssels signiert; der Anker muss auf diesem oder einem späteren Commit liegen |
| Gitea: „Commit nicht signiert / nicht verifiziert“ beim Push | der öffentliche Schlüssel fehlt im Gitea-Konto, oder die E-Mail des Commits gehört nicht zum Konto |
| Web-Merge wird abgewiesen | gewollt, siehe [Pull-Request signiert übernehmen](#pr-signiert-uebernehmen) |
