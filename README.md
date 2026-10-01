# ploi-backup

Elke nacht een versleutelde backup van al je [Ploi](https://ploi.io)-servers naar een [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box), met [restic](https://restic.net). Alle sites, databases en serverconfiguratie gaan mee, en nieuwe sites en databases ook, zonder dat je iets hoeft in te stellen. Gaat er iets mis, dan krijg je een melding in Discord.

**Voor wie:** je beheert servers via Ploi (Ubuntu, amd64 of arm64) met sites in `/home`, bijvoorbeeld Laravel, Statamic of WordPress. Je gebruikt MySQL/MariaDB en/of SQLite. Je wilt per server één keer iets inrichten en daarna niet meer omkijken.

**Niet voor:** PostgreSQL, data in Docker-volumes, of databases waarbij je maximaal een paar minuten mag verliezen (zie [Databases vaker backuppen](#databases-vaker-backuppen-optioneel)).

---

## Inrichten

Je hebt **Ploi** en een **Hetzner-account** nodig. Root-toegang tot de servers is niet nodig: alles loopt via Ploi.

### Eén keer

1. **Storage Box.** Bestel een Storage Box in de [Hetzner Console](https://console.hetzner.com) (BX11 is voor de meeste mensen genoeg). Noteer het **ID**; dat staat in de URL van de Storage Box. Zet daar ook aan:
   - **Delete protection**
   - een **automatisch snapshotplan**, bijvoorbeeld dagelijks en maximaal 10. Daarmee kan zelfs een gehackte server zijn backups niet echt kwijtmaken.
2. **API-token.** Console > *Security* > *API tokens* > nieuw token met **Read & Write**. Je hebt het alleen nodig bij stap 2 per server. Trek het daarna weer in.
3. **restic-wachtwoord.** Maak in je wachtwoordmanager een wachtwoord van 32 tekens of meer. **Zonder dit wachtwoord zijn je backups onbruikbaar.** Gebruik voor al je servers hetzelfde wachtwoord.
4. **Meldingen.**
   - Discord: kanaal > *Integraties* > *Webhooks* > *Nieuwe webhook* > URL kopiëren.
   - Aangeraden: maak ook een gratis account op [Healthchecks.io](https://healthchecks.io) en kopieer *Settings* > *Ping key*. Dan krijg je ook een mail als de backup helemaal niet draait.
5. **Ploi-script.** Ploi > *Scripts* > *New script*:
   - naam `ploi-backup`, user **root**
   - inhoud: [`backup/ploi-script.sh`](backup/ploi-script.sh)
   - vul de vier regels bovenaan in

### Per server

1. **Installeren.** Ploi > *Scripts* > `ploi-backup` > *Run* op de server. Je ziet *"nog niet ingericht"*. Dat klopt.
2. **Koppelen.** Maak een tweede Ploi-script `ploi-backup-setup` (user **root**) met de inhoud hieronder. Vul de drie waarden in, run het op de server, en **maak het script daarna weer leeg**: Ploi bewaart scripts als platte tekst.
   ```bash
   export HETZNER_TOKEN="het-api-token"
   export RESTIC_PASSWORD="het-restic-wachtwoord"
   export SETUP_SERVER_NAME="server-naam-uit-ploi"
   export SETUP_MYSQL=1
   /usr/local/sbin/ploi-backup setup </dev/null
   ```
   - `SETUP_SERVER_NAME` is de naam waaronder de server in de backups staat. **Neem de servernaam uit Ploi**, en houd die daarna altijd hetzelfde.
   - `SETUP_MYSQL=1` maakt een MySQL-gebruiker die alleen kan lezen. Daarvoor **herstart MySQL één keer**, een paar seconden. Doe dit op een rustig moment. Laat de regel weg als de server geen MySQL heeft.
   - Gelukt? Dan krijg je een 🆕-bericht in Discord.
3. **Inplannen.** Ploi > *Scripts* > `ploi-backup` > *Schedule*: dagelijks, op de server, op een rustige tijd. Bijvoorbeeld `30 3 * * *` (03:30, servertijd is meestal UTC). Heb je meerdere servers, laat ze dan minstens 30 minuten na elkaar starten.

Klaar. De eerste backup kun je meteen starten met *Run*. Een nieuwe server toevoegen is dezelfde drie stappen.

### Werkt het?
- Na de eerste backup krijg je 🟢 *"Eerste backup klaar"* in Discord.
- Daarna is het stil zolang alles goed gaat. Elke zondag komt er een 🟢-weekrapport per server.
- **Komt het weekrapport niet, of krijg je 🔴 of 🟠, kijk dan meteen.** In de melding staat wat er mis is.

---

## Meldingen

| Melding | Wat het betekent | Wat je doet |
|---|---|---|
| 🆕 / ♻️ | Server gekoppeld (nieuw, of een bestaande herbouwde server) | Niets |
| 🟢 Eerste backup / Weekrapport | Alles werkt | Niets |
| 🟠 Klaar met waarschuwingen | De bestanden zijn gebackupt, maar er ging iets mis, bijvoorbeeld geen MySQL-toegang | Doe wat in de melding staat |
| 🔴 Backup mislukt | Er is niets gebackupt. In de melding staan de laatste logregels. | Oplossen. Zie [Problemen oplossen](#problemen-oplossen) |
| ⚠️ Backup overgeslagen | De server is veel kleiner dan bij de vorige backup. Leeggemaakt of opnieuw opgebouwd? | Eerst restoren, of zie de melding |

---

## Terugzetten

Log in als root op de server. Waar `ORG` staat, vul je je `PB_ORG` in.

**Zet altijd eerst terug naar `/root/restore-test`, en nooit direct over een live site heen.**

```bash
B=ploi-backup
$B restic snapshots                       # overzicht van alle snapshots
```

**Bestanden van een site:**
```bash
$B restic restore latest --tag ploi-backup --target /root/restore-test --include /home/USER/SITE
diff -rq /root/restore-test/home/USER/SITE /home/USER/SITE | head        # wat is er anders?
rsync -a --dry-run /root/restore-test/home/USER/SITE/ /home/USER/SITE/   # eerst kijken
rsync -a /root/restore-test/home/USER/SITE/ /home/USER/SITE/             # dan terugzetten
```
- Een ander moment kiezen? Vervang `latest` door een ID uit `$B restic snapshots`.
- Gebruik bij bestanden altijd `--tag ploi-backup`. Gebruik je de [uurlijkse databasebackup](#databases-vaker-backuppen-optioneel), dan kan `latest` anders een snapshot zijn waarin alleen databases zitten.

**MySQL-database:**
```bash
$B restic dump latest /var/backups/ploi-backup-ORG/mysql/DATABASE.sql > /root/restore-test/db.sql
mysql -u DB_USER -p DATABASE < /root/restore-test/db.sql       # DB_USER en wachtwoord staan in .env / wp-config.php
```

**SQLite-database (bijvoorbeeld Statamic):**
```bash
$B restic ls latest /var/backups/ploi-backup-ORG/sqlite        # namen: USER_SITE_database_database.sqlite.sql
$B restic dump latest /var/backups/ploi-backup-ORG/sqlite/NAAM.sql > /root/restore-test/db.sql
sqlite3 /root/restore-test/database.sqlite < /root/restore-test/db.sql
```
Vervang daarna het bestand van de site door deze nieuwe database, met de site even in onderhoud (`php artisan down`, terugzetten, `php artisan up`), en zet de eigenaar goed met `chown`.

**De hele server is weg:**
1. Maak de server opnieuw aan in Ploi, met dezelfde sites, system users en (lege) databases.
2. Run `ploi-backup` één keer, en daarna `ploi-backup-setup` met dezelfde `SETUP_SERVER_NAME`, hetzelfde restic-wachtwoord en een extra regel `export ADOPT=1`. De server wordt dan gekoppeld aan zijn oude backups. **Zet de schedule nog niet aan.**
3. Zet alles terug:
   - de sites: `restore --tag ploi-backup ... --include /home`, en daarna per site `rsync` en `chown -R user:user`
   - de databases, zoals hierboven
   - eerst `mysql/_users_and_grants.sql` importeren (`mysql -u ploi -p < bestand`, met het databasewachtwoord uit de installatiemail van Ploi). Daarmee krijgen de databasegebruikers hun oude wachtwoorden terug.
4. Controleer de sites en zet dan pas de schedule aan. Vergeet je de restore, dan slaat de backup zichzelf over en meldt hij dat. Je oude backups worden dus niet weggedrukt.

Tip: Hetzner Cloud Backups (een vinkje per server in de Console, kost 20% van de serverprijs) zet een hele server sneller terug. ploi-backup is dan de tweede, onafhankelijke kopie.

---

## Databases vaker backuppen (optioneel)

Kun je voor één site of app geen dag aan data missen? Maak dan een Ploi-script `ploi-backup-db` (user **root**) met als inhoud alleen:
```bash
/usr/local/sbin/ploi-backup run-db
```
Plan het in op die server, bijvoorbeeld elk uur (`15 * * * *`).
- Er gaan dan alleen databasedumps mee, met een eigen bewaartermijn: 48 uur en 7 dagen.
- De dagelijkse backup en de db-backup zitten elkaar niet in de weg.

**Grenzen:** je verliest maximaal een uur. Moet het tot op de minuut, dan heb je point-in-time recovery nodig (MySQL-binlogs) of een managed database. Dat valt buiten dit project, net als PostgreSQL.

---

## Updaten

Een nieuwe versie staat bij [Releases](../../releases), samen met de bijbehorende checksum. Pas in het Ploi-script `ploi-backup` de regels `VERSION` en `SHA256` aan. De eerstvolgende run gebruikt dan de nieuwe versie. Verder hoef je niets te doen.

---

## Hoe het werkt

**Wat gaat mee:**
- `/home`: alle sites, inclusief `.env`, uploads, `vendor` en `.git`
- `/etc`: nginx, php-fpm, supervisor, letsencrypt, en `/etc/crontab` met de Ploi-crons
- `/root` en `/usr/local/sbin`
- een dump van **elke** MySQL/MariaDB-database (`mysqldump --single-transaction`, zonder locks), plus de databasegebruikers en hun rechten
- een dump van **elke** SQLite-database onder `/home`. Die wordt gemaakt als de eigenaar van het bestand, dus consistent, ook in WAL-modus.

**Wat niet mee gaat**, omdat het vanzelf opnieuw wordt opgebouwd:
- `node_modules` en de caches van npm en composer
- Laravel `storage/framework/{cache,views,sessions}`
- Statamic static cache en glide
- WordPress `wp-content/cache` en de backups van backup-plugins (`ai1wm-backups`, `updraft`, …)

**Bewaartermijn:** 14 dagen, 8 weken en 6 maanden. Op zondag wordt opgeschoond en wordt 5% van de data echt teruggelezen als integriteitscheck.

**Zo loopt het:**
1. Ploi start `ploi-script.sh`.
2. Dat haalt deze repo op, op precies de vaste `VERSION`, en controleert de `SHA256`. Een gewijzigde repo kan dus niets ongemerkt uitvoeren.
3. Het script installeert zich als `/usr/local/sbin/ploi-backup-ORG`, met de korte naam `ploi-backup` ernaast.
4. Het start de backup op de achtergrond, via systemd. Daardoor maakt het niet uit hoe lang die duurt.
5. Is GitHub niet bereikbaar, dan draait de al geïnstalleerde versie.

**Belasting:** de backup draait met de laagste CPU- en IO-prioriteit, dus sites gaan voor. Gemeten op een server met 2 vCPU en 9 sites (12 GB):

| Run | Duur | Effect op de sites |
|---|---|---|
| Eerste backup | 2,5 min | geen verschil in responstijd |
| Elke volgende backup | ongeveer 1 min | niet merkbaar |

**Beveiliging:**
- Elke server heeft een eigen sub-account op de Storage Box, in `servers/<naam>`. Een server kan daardoor alleen bij zijn eigen backups, en niet bij andere servers of andere mappen op de Storage Box.
- De backups zijn versleuteld met het restic-wachtwoord.
- Het API-token wordt nergens opgeslagen.

| Op de server (alleen root) | Inhoud |
|---|---|
| `/root/.ploi-backup-ORG/env` | het restic-wachtwoord en de gegevens van het sub-account |
| `/root/.ploi-backup-ORG/id_ed25519` | de SSH-key voor het sub-account |
| `/root/.backup-mysql.cnf` | de MySQL-gebruiker `backup` (kan alleen lezen) |
| `/var/log/ploi-backup-ORG/` | de log van de laatste run (geschiedenis: `journalctl -u ploi-backup-ORG`) |

**Handige commando's** (als root):
```bash
ploi-backup status               # laatste snapshots en log
ploi-backup backup               # backup nu, in de voorgrond
ploi-backup restic ...           # elke restic-opdracht, met de juiste repo en het juiste wachtwoord
```

---

## Problemen oplossen

| Probleem | Oplossing |
|---|---|
| *nog niet ingericht* | Stap 2 per server (`ploi-backup-setup`) |
| *ploi-backup: No such file or directory* | Eerst stap 1: `ploi-backup` één keer runnen op de server |
| *geen MySQL-toegang* | `ploi-backup-setup` opnieuw runnen met `SETUP_MYSQL=1`. Zonder `HETZNER_TOKEN` mag ook: alleen `RESTIC_PASSWORD` is nodig. |
| *restic-wachtwoord klopt niet* | Gebruik het wachtwoord uit je wachtwoordmanager. Een fout wachtwoord in setup verandert niets aan een werkende server. |
| *repository is already locked* | Draait er nog een backup? `systemctl status ploi-backup-ORG`. Zo niet: `ploi-backup restic unlock`. |
| *downloaden of checksum mislukt* (in de Ploi-output) | Kloppen `VERSION` en `SHA256` met de release? Tot dat is opgelost draait de al geïnstalleerde versie gewoon door. |
| Storage Box niet bereikbaar | Uitgaand verkeer op poort 23 moet open staan. Kijk ook op [status.hetzner.com](https://status.hetzner.com). |

Setup kun je zo vaak runnen als je wilt. Werkt alles al, dan verandert er niets.

---

## Ontwikkeling

- **Testen:** `test/run-tests.sh` draait een volledige test in Docker, met een nagebootste Storage Box, MySQL, SQLite en Discord: backup, restore, foutsituaties en meldingen.
- **Release maken:**
  1. Pas `VERSION` en de uitkomst van `sha256sum backup/ploi-backup.sh` aan in `backup/ploi-script.sh`.
  2. Commit, tag en push: `git tag vX.Y.Z && git push --tags`.
  3. Maak een GitHub-release met de checksum erin.
