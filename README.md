# coffee / chamomile — suspend programmato su macOS

Due comandi per un Mac headless che deve stare **sveglio di giorno** e **dormire di notte**,
svegliandosi da solo a un'ora prestabilita.

```
coffee      → impedisce lo sleep, e pianifica: suspend 23:30 / resume 06:30
chamomile   → ridà lo sleep e rimuove tutto quello che ha messo coffee
```

Pensato per un MacBook usato a **coperchio chiuso**, alimentato e raggiunto via SSH
(in questo caso tramite un tunnel che gira in un container dentro colima).

## Perché non basta `pmset repeat sleep`

Verificato su macOS 26.7.1 (Apple Silicon), non per sentito dire:

| prova | esito |
|---|---|
| `pmset -a disablesleep 1` + `pmset repeat sleep 23:30` | il sonno **non avviene** |
| `pmset -a disablesleep 1` + `pmset sleepnow` | `Unable to sleep system: error 0xe00002e2` (not permitted) |
| job launchd `StartCalendarInterval` su Mac dormiente | **non la sveglia**: il job parte al primo wake, in ritardo |
| `pmset repeat wake 06:30` | **sveglia** puntualmente (evento RTC) |

Quindi `disablesleep` va tolto prima di dormire, e la sveglia deve essere un evento RTC.
Il sonno delle 23:30 non può essere un evento `pmset`: lo chiede un job di launchd
(che gira come root, senza tty) con `disablesleep 0` seguito da `sleepnow`.

## Come funziona

```
23:30  launchd  →  pmset -a disablesleep 0 ; pmset sleepnow     la macchina dorme
06:30  RTC      →  pmset repeat wake                            la macchina si sveglia
06:30  launchd  →  pmset -a disablesleep 1                      resta sveglia
06:45  launchd  →  pmset -a disablesleep 1                      seconda occasione
```

I job di launchd hanno **finestre di guardia** (23:25–23:45, 06:25–12:00): launchd riesegue
i job mancati al risveglio, quindi senza guardia un tick delle 23:30 perso potrebbe
addormentare la macchina a mezzogiorno.

## Installazione

Nessuna dipendenza: solo bash e `pmset` (già presenti su macOS).

```bash
git clone <questo-repo> ~/mac-suspend
cd ~/mac-suspend
./bin/coffee            # chiede la password di sudo
```

`coffee` fa, in ordine:

1. `pmset -a disablesleep 1` — la macchina non dorme (nemmeno a coperchio chiuso);
2. `pmset repeat wake MTWRFSU 06:30:00` — la sveglia vera;
3. installa il LaunchDaemon `com.roberto.coffee.tick` in `/Library/LaunchDaemons`
   (gli orari sono nel plist, i percorsi assoluti vengono resi concreti all'installazione);
4. **verifica lo stato finale**, non il codice di uscita di `pmset` (che da non-root
   stampa "must be run as root" e ritorna `0`).

Se qualcosa non torna, esce con errore e non lascia lo stato a metà.

## Uso quotidiano

```bash
coffee        # arma tutto (idempotente)
chamomile     # disarma tutto e ridà lo sleep (idempotente)
```

Attenzione: `chamomile` rimette `disablesleep 0`, quindi con il coperchio chiuso la
macchina dorme **subito**. Lancialo in locale, non via SSH.

## Verifica

```bash
# cosa è armato
launchctl print system/com.roberto.coffee.tick >/dev/null && echo "tick caricato"
pmset -g sched | sed -n '/Repeating/,$p'      # deve comparire wake at 6:30AM every day
pmset -g | grep SleepDisabled                  # 1 = sveglia

# cosa è successo stanotte
grep -E "tick 23:30|tick 6:30|WARN" ~/mac-suspend/logs/tick.log
pmset -g log | awk '$4=="Sleep" || ($4=="Wake" && $5!="Requests")' | tail -6
```

Il tick scrive una riga per ogni esecuzione, con alimentazione e carica:

```
2026-10-30T23:30:05+0100 tick 23:30 now=1410 disablesleep=1 source=Battery Power charge=68%
Sleeping now...
```

## Problemi noti (tutti verificati sul campo)

| sintomo | causa | rimedio |
|---|---|---|
| alle 23:30 non dorme, nel log `Sleeping now...` ma nessun `Sleep` nel log di sistema | una **sessione SSH aperta**: `ttyskeepawake` + assertion `ttyassertion` degradano il sonno a *dark wake* | non essere collegato a quell'ora, oppure `sudo pmset -a ttyskeepawake 0` |
| non dorme e `pmset -g` dice `sleep prevented by …` | un'assertion (tipicamente `coreaudiod`: video o musica in riproduzione) | chiudere l'app; il tick lo registra nel log |
| si sveglia in *DarkWake*, non FullWake | normale con coperchio chiuso: CPU e rete attive, display spento | è quello che serve a un headless; verifica che l'SSH risponda |
| la notte consuma batteria | `MagSafe` non collegato: il log lo dice (`source=Battery Power`) | ricollegare; sotto il 30% il tick scrive un `WARN` |
| dopo un riavvio non è raggiungibile | **FileVault**: la macchina resta al login finché qualcuno non entra | nessuna soluzione lato software: tenere presente il rischio |

## Struttura

```
bin/coffee                                  il comando
bin/chamomile                               il comando inverso
daemon/coffee-tick                          eseguito da launchd, con le finestre di guardia
daemon/com.roberto.coffee.tick.plist.in     template del LaunchDaemon (@ROOT@ → percorso reale)
logs/                                       log del tick (ignorato da git)
```

## Disinstallazione

```bash
chamomile                                   # disarma e ridà lo sleep
sudo rm -rf ~/mac-suspend                   # se non ti serve più
```

Via di fuga manuale, sempre:

```bash
sudo pmset -a disablesleep 0
sudo pmset repeat cancel
sudo launchctl bootout system/com.roberto.coffee.tick
```

## Limiti

- Gli orari sono **fissi nel plist**: per cambiarli si modifica
  `daemon/com.roberto.coffee.tick.plist.in` e si rilancia `coffee`.
- La label `com.roberto.coffee.tick` contiene un nome utente: cambiala se ti dà fastidio.
- Il resume è un evento RTC singolo (`wake`): non riaccende una macchina spenta.
- Testato su un solo modello (MacBook Air M5, macOS 26.7.1). Il comportamento di
  `disablesleep` e dei job launchd può cambiare tra versioni di macOS.
