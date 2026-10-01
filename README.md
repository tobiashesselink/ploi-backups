# ploi-backup

Elke nacht een versleutelde backup van al je [Ploi](https://ploi.io)-servers naar een [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box), met [restic](https://restic.net). Alle sites, databases en serverinstellingen gaan mee. Nieuwe sites en databases gaan vanzelf mee. Terugzetten kan per site, met de database die erbij hoort, via een Ploi-script. Gaat er iets mis, dan krijg je een melding in Discord.

**Voor wie:** je beheert Ubuntu-servers via Ploi, met sites in `/home` (bijvoorbeeld Laravel, Statamic of WordPress) en MySQL/MariaDB en/of SQLite.
**Niet voor:** PostgreSQL, data in Docker-volumes, of data waarbij je maar een paar minuten mag verliezen.

---

## Inrichten

### Eén keer
1. **Storage Box.** Bestel er een in de [Hetzner Console](https://console.hetzner.com) (BX11 is voor de meeste mensen genoeg) en noteer het **ID**. Zet daar **Delete protection** aan, en een **automatisch snapshotplan** (dagelijks, maximaal 10).
2. **restic-wachtwoord.** Maak in je wachtwoordmanager een wachtwoord van 32 tekens of meer. **Zonder dit wachtwoord zijn je backups onbruikbaar.**
3. **Discord.** Kanaal > *Integraties* > *Webhooks* > *Nieuwe webhook* > URL kopiëren. Aangeraden: ook een gratis [Healthchecks.io](https://healthchecks.io)-account, met de *Ping key*. Dan krijg je ook een mail als de backup helemaal niet draait.
4. **Ploi-script.** Ploi > *Scripts* > *New script*. Noem het `ploi-backup`, user **root**. Plak de inhoud van [`backup/ploi-script.sh`](backup/ploi-script.sh) erin en vul de regels bovenaan in. Laat `PB_HETZNER_TOKEN` leeg.

### Per server
1. **Token invullen.** Maak in de Hetzner Console een API-token aan: *Security* > *API tokens*, **Read & Write**. Zet het in het Ploi-script bij `PB_HETZNER_TOKEN`.
2. **Run.** Draai `ploi-backup` op de server. Die richt zichzelf in en maakt meteen de eerste backup. Dat duurt een paar minuten. In Discord verschijnen 🆕 en daarna 🟢.
   - Heeft de server MySQL, dan herstart MySQL hierbij één keer, een paar seconden. Kies daarvoor een rustig moment.
3. **Token weer leegmaken** in het Ploi-script. Trek het token daarna in, in de Hetzner Console.
4. **Inplannen.** *Schedule* > dagelijks, op die server, op een rustige tijd. Bijvoorbeeld `30 3 * * *` (03:30; de servertijd is meestal UTC). Laat meerdere servers minstens 30 minuten na elkaar starten.

Dat is alles. Daarna hoor je alleen iets als er iets mis is, en op zondag een 🟢-weekrapport per server.

De servernaam in de backups is de hostname. Wil je een andere naam, bijvoorbeeld de naam uit Ploi, zet dan bij stap 2 tijdelijk `export PB_SERVER_NAME="naam"` in het script.

---

## Overzicht van de backups

Maak één keer een Ploi-script `ploi-backup-list` (user **root**) met als inhoud alleen:
```bash
/usr/local/sbin/ploi-backup list
```
Je krijgt dan per backup het ID, de datum en tijd, de soort (volledig, database of veiligheid) en de grootte, en daaronder de sites.

Zet je er een site achter, bijvoorbeeld `/usr/local/sbin/ploi-backup list voorbeeld.nl`, dan zie je per backup hoe groot de bestanden en de database van die site zijn. Het ID gebruik je bij het terugzetten. Via SSH werkt hetzelfde commando: `ploi-backup list`.

---

## Terugzetten

Maak één keer een Ploi-script `ploi-backup-restore` (user **root**):
```bash
export RESTORE_SITE="voorbeeld.nl"    # de map van de site, zoals in /home/<user>/voorbeeld.nl
export RESTORE_WHEN="latest"          # latest, een datum (2026-09-30) of een backup-ID
export RESTORE_APPLY=0                # 0 = proef, 1 = echt terugzetten
/usr/local/sbin/ploi-backup restore
```

1. **Proef** (`RESTORE_APPLY=0`). Er verandert niets live. De bestanden en de database komen in `/root/restore-test`, zodat je ze kunt bekijken.
2. **Echt** (`RESTORE_APPLY=1`). De site en de database die erbij hoort gaan samen terug. De database staat in `.env` of `wp-config.php`. Er gebeurt dit:
   1. Eerst wordt vanzelf een **veiligheidsbackup** van de huidige staat gemaakt.
   2. Daarna gaat de site even in onderhoud (Laravel en Statamic).
   3. Dan worden de bestanden en de database teruggezet en de caches geleegd.
3. **Ongedaan maken?** In de ♻️-melding staat het ID van de veiligheidsbackup. Zet dat ID bij `RESTORE_WHEN` en run het opnieuw met `RESTORE_APPLY=1`.

**Variaties:**
- Alleen de database: zet `export RESTORE_PART=db` erbij. Alleen de bestanden: `export RESTORE_PART=files`.
- Via SSH, als root, met dezelfde opties: `ploi-backup restore voorbeeld.nl`, met `--apply`, `--when 2026-09-30` en `--db-only`/`--files-only`. Gebruik SSH bij grote sites, als Ploi te lang moet wachten.

**Hele server weg?**
1. Maak de server opnieuw aan in Ploi, met dezelfde sites en (lege) databases. Geef de database-users hetzelfde wachtwoord als in de `.env` of `wp-config.php` uit de backup. Dat wachtwoord vind je met een proef-restore.
2. Zet in het Ploi-script `ploi-backup` tijdelijk het token, `export PB_SERVER_NAME="oude naam"` en `export PB_ADOPT=1`. Run het. De server wordt dan aan zijn oude backups gekoppeld. **Zet de schedule nog niet aan.**
3. Zet per site terug met `ploi-backup-restore` (`RESTORE_APPLY=1`).
4. Maak de cronjobs en queue workers opnieuw aan in Ploi. Hoe ze waren ingesteld, zie je in de backup: `/etc/crontab` en `/etc/supervisor/conf.d/`.
5. Haal het token, `PB_SERVER_NAME` en `PB_ADOPT` weer weg, en zet de schedule aan.

Tip: met Hetzner Cloud Backups (een vinkje per server, 20% van de serverprijs) zet je een hele server sneller terug. ploi-backup is dan je tweede, losse kopie.

---

## Meldingen

| Melding | Betekenis |
|---|---|
| 🆕 / ♻️ | Server gekoppeld, of site teruggezet. Je hoeft niets te doen. |
| 🟢 | Eerste backup klaar, of het weekrapport (zondag). Alles werkt. |
| 🟠 | Bestanden zijn gebackupt, maar er ging iets mis, bijvoorbeeld geen toegang tot MySQL. In de melding staat wat je moet doen. |
| 🔴 | Mislukt. In de melding staan de laatste regels van de log. |
| ⚠️ | Backup overgeslagen: de server is veel kleiner dan de vorige keer. Leeggemaakt of opnieuw opgebouwd? Eerst terugzetten. |
| 🔧 | Server nog niet gekoppeld: vul het token in (zie *Per server*). |

**Komt het weekrapport op zondag niet, kijk dan zelf.** Healthchecks.io doet dat automatisch voor je.

---

## Databases vaker backuppen (optioneel)
Is een dag aan dataverlies te veel voor een site? Maak dan een Ploi-script `ploi-backup-db` (user root) met alleen `/usr/local/sbin/ploi-backup run-db`, en plan het elk uur in (`15 * * * *`) op die server.

- Er gaan dan alleen databasedumps mee. Die worden 48 uur en 7 dagen bewaard.
- Terugzetten gaat hetzelfde, met `RESTORE_PART=db`.
- Moet het tot op de minuut, dan heb je MySQL-binlogs of een managed database nodig. Dat valt buiten dit project.

## Updaten
Een nieuwe versie staat bij [Releases](../../releases). Zet `VERSION` en `SHA256` uit de release in het Ploi-script `ploi-backup`. Bij de eerstvolgende run is de nieuwe versie actief.

---

## Hoe het werkt

- **Wat gaat mee:**
  - `/home`: alle sites, inclusief `.env`, uploads, `vendor` en `.git`
  - `/etc`, met daarin ook de cronjobs (`/etc/crontab`) en de queue workers (`/etc/supervisor/conf.d`) van Ploi
  - `/root`, `/usr/local/sbin`, `/opt` en `/var/spool/cron`
  - een dump van elke MySQL/MariaDB-database (zonder locks), plus de database-users met hun rechten
  - een dump van elke SQLite-database onder `/home`
- **Wat niet:** caches die vanzelf opnieuw worden opgebouwd:
  - `node_modules`
  - de caches van npm en composer
  - Laravel `storage/framework`
  - Statamic static cache en glide
  - WordPress `wp-content/cache`
  - backups van backup-plugins
- **Bewaren:** 14 dagen, 8 weken en 6 maanden. Elke zondag wordt opgeschoond en wordt 5% van de data teruggelezen als controle. Veiligheidsbackups van een restore blijven 30 dagen staan.
- **Zo loopt het:**
  1. Ploi draait [`ploi-script.sh`](backup/ploi-script.sh).
  2. Dat haalt precies de vaste `VERSION` van deze repo op en controleert de `SHA256`. Een gewijzigde repo kan dus niets ongemerkt uitvoeren.
  3. Het script installeert zich als `/usr/local/sbin/ploi-backup`.
  4. Het start de backup op de achtergrond, met de laagste CPU- en IO-prioriteit.
  5. Is GitHub niet bereikbaar, dan draait de versie die al op de server staat.
- **Belasting:** gemeten op een server met 2 vCPU en 9 sites (12 GB). De eerste backup duurde 2,5 minuut, een volgende ongeveer 1 minuut. De responstijd van de sites bleef gelijk.
- **Beveiliging:**
  - Elke server heeft een eigen sub-account op de Storage Box, in `servers/<naam>`, en kan niet bij de backups van andere servers.
  - De backups zijn versleuteld met het restic-wachtwoord.
  - Het API-token wordt nergens opgeslagen.
  - Het tijdelijke scriptbestand dat Ploi op de server zet, haalt het script meteen weg.
  - Op de server staan alleen bestanden die alleen root kan lezen: `/root/.ploi-backup-<org>/` (wachtwoord en SSH-key) en `/root/.backup-mysql.cnf` (een MySQL-user die alleen kan lezen).

**Handige commando's** (via SSH, als root):
```bash
ploi-backup status            # laatste backups en log
ploi-backup backup            # nu een backup, in de voorgrond
ploi-backup restic snapshots  # alle backups (elke restic-opdracht werkt zo)
journalctl -u ploi-backup-<org>   # geschiedenis
```

## Problemen oplossen

| Melding of probleem | Oplossing |
|---|---|
| 🔧 *nog niet gekoppeld* | *Per server*, stap 1 tot en met 3 |
| *er bestaan al backups voor …* | Opnieuw opgebouwde server: zet tijdelijk `PB_ADOPT=1` (zie *Hele server weg*). Anders: kies een andere `PB_SERVER_NAME`. |
| *geen MySQL-toegang* | Als root: `SETUP_MYSQL=1 ploi-backup setup </dev/null`. MySQL herstart dan één keer; het token is niet nodig. |
| Terugzetten: *objecten van een andere MySQL-user* of *triggers of routines* | De site-user mag die niet vervangen, en er is niets veranderd. Zet de database terug als MySQL-root of `ploi`-user: doe eerst een proef, daarna `mysql -u ploi -p DATABASE < /root/restore-test/<site>-<id>/database.sql` |
| *repository is already locked* | Draait er nog een backup? (`systemctl status ploi-backup-<org>`) Zo niet: `ploi-backup restic unlock` |
| *downloaden of checksum mislukt* | Klopt `VERSION`/`SHA256` met de release? Tot dat is opgelost draait de geïnstalleerde versie gewoon door. |
| Storage Box onbereikbaar | Uitgaand verkeer op poort 23 moet open staan. Kijk ook op [status.hetzner.com](https://status.hetzner.com). |

---

## Ontwikkeling
- **Testen:** `test/run-tests.sh` draait een volledige test in Docker: backup, terugzetten, nieuwe server, foutsituaties en meldingen. Er wordt een Storage Box, MySQL, SQLite en Discord nagebootst.
- **Release maken:**
  1. Zet een nieuwe `VERSION` en de uitkomst van `sha256sum backup/ploi-backup.sh` in `backup/ploi-script.sh`.
  2. Commit, en push de tag (`git tag vX.Y.Z && git push --tags`).
  3. Maak een GitHub-release met beide waarden erin.
