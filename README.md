<p align="center"><img src="Resources/logo.png" width="160" alt="snobapp"></p>

<h1 align="center">snobapp</h1>

<p align="center">Une petite app de barre de menus macOS qui réunit cinq utilitaires en un seul.</p>

> **English** — snobapp is a tiny macOS menu-bar app: three-finger middle click on the trackpad, mouse-wheel reverse, speed and acceleration control and smooth scrolling, sleep on lid close even with external displays, a keep-awake (caffeinate) toggle, and a battery charge limit with a discharge mode. Apple Silicon, macOS 13+ (charge limit: macOS 26.4+).

## Fonctions

| | |
|---|---|
| **Clic du milieu au trackpad** | cliquer avec 3 doigts (réglable) = clic du milieu ; taper avec 3 doigts aussi. Apps ignorables. |
| **Molette de la souris** | inversion verticale / horizontale, **vitesse réglable** (0,5× à 3×), **accélération réglable** (0 % : chaque cran vaut un cran lent ; 100 % : courbe macOS) et **défilement fluide** avec réglage de douceur. Le trackpad et la Magic Mouse ne sont jamais touchés ; sans souris externe branchée, la molette n'est pas du tout interceptée. |
| **Veille capot fermé** | fermer le capot met le Mac en veille, même avec des écrans externes branchés. |
| **Empêcher la veille** | case « Empêcher la veille (caffeinate) » dans le menu : comme `caffeinate -i`, le Mac reste éveillé (l'écran peut s'éteindre) ; mémorisée, relancée au démarrage. Fermer le capot met toujours en veille. |
| **Limite de charge** | recharge max. (80–95 %, tenue par macOS sur secteur, rétablie automatiquement) **mode décharge** et **charge complète** dans le menu (se décochent seuls). |

## Installation

1. Téléchargez `snobapp.zip` depuis les [Releases](../../releases), dézippez et placez `snobapp.app` dans `/Applications` (ou `~/Applications`).
2. L'app n'est pas notariée : au premier lancement, clic droit › **Ouvrir** (ou `xattr -dr com.apple.quarantine snobapp.app`).
3. Autorisez snobapp dans **Réglages Système › Confidentialité et sécurité › Accessibilité** (nécessaire pour le clic du milieu et la molette).
4. Pour une limite de charge sous 80 % ou le mode décharge : **Réglages › Batterie › Installer…** (mot de passe administrateur, une seule fois).

## Comment fonctionne la limite de charge

- **Limite native de macOS** (macOS 26.4+, paliers 80 / 85 / 90 / 95 %) : arrivé à la limite, macOS arrête la charge et le Mac fonctionne **sur secteur, sans solliciter la batterie** — même app fermée ou en veille.
- **Surveillance** : la limite peut être désactivée ou relevée par d'autres (redémarrage, autre app, « charger complètement »). snobapp la vérifie au lancement, au branchement du chargeur, au réveil et toutes les 60 s, et la rétablit aussitôt. Il ne la remet jamais à 100 % en quittant.
- **Pas de limite sous 80 %** : sur les Mac récents (macOS 27), les clés SMC d'arrêt de charge (`CHTE`, `CH0B`/`CH0C`) n'existent plus ; seule la coupure de l'adaptateur (`CHIE`) reste, ce qui obligerait à alterner décharge et recharge (micro-cycles). snobapp ne propose donc que les paliers natifs.
- **Charge complète** (menu) : lève la limite jusqu'à batterie pleine ; se décoche seule une fois la batterie pleine ou le chargeur débranché. Cochée chargeur débranché, elle vaut pour le prochain branchement.
- **Mode décharge** (menu) : un petit service root coupe l'adaptateur jusqu'à la limite, puis la limite native prend le relais. Avant chaque veille et à l'arrêt, l'adaptateur est rebranché.

Le service : `/Library/PrivilegedHelperTools/io.github.snoblevrai.snobapp.helper` + `/Library/LaunchDaemons/io.github.snoblevrai.snobapp.helper.plist`, échanges via `/Library/Application Support/snobapp/`. Installation / désinstallation depuis Réglages › Batterie.

## Compiler

Command Line Tools suffisent (pas besoin de Xcode).

```sh
./build.sh            # → build/snobapp.app
./build.sh install    # → ~/Applications/snobapp.app, puis lancement
build/snobapp.app/Contents/MacOS/snobapp --selftest        # multitouch, SMC, limite native, scénarios du service
swift Tools/make-icon.swift Resources                      # régénère l'icône
```

Signature ad hoc avec une exigence désignée stable (`identifier`) : l'autorisation Accessibilité survit aux recompilations. Pour signer avec un certificat : `SIGN_ID="Nom" ./build.sh`.

## Architecture

| Fichier | Rôle |
|---|---|
| `Sources/CMultitouch/` | pont C vers le framework privé MultitouchSupport (dlopen) |
| `Sources/CSMC/` | accès SMC (AppleSMC) et limite native (PowerUI.framework, privé) |
| `MiddleClickEngine.swift` | détection du tap à N doigts, réécriture des clics |
| `MouseScroll.swift` | inversion et amortissement de l'accélération de la molette |
| `SmoothScroller.swift` | défilement fluide : chaque cran est étalé sur l'intervalle mesuré entre les crans, puis lissé par un ressort à amortissement critique, à la cadence de l'écran (CVDisplayLink) |
| `EventTap.swift` | interception des clics et de la molette (deux taps, chacun actif seulement quand il sert), thread dédié |
| `PointingDevices.swift` | détection d'une souris externe (registre IOKit) |
| `LidSleep.swift` | veille à la fermeture du capot (`IOPMrootDomain`, `IOPMSleepSystem`) |
| `KeepAwake.swift` | case « Empêcher la veille » (assertion `PreventUserIdleSystemSleep`, comme `caffeinate -i`) |
| `BatteryController.swift` | limite native, installation du service |
| `BatteryDaemon.swift` | service root : décharge et limite sous le palier natif |
| `SystemMonitor.swift` | réveil, branchement de trackpad, écrans, app au premier plan |
| `StatusMenu.swift`, `SettingsView.swift` | menu et réglages (onglets) |

## Crédits

Inspiré des projets open source [MiddleClick](https://github.com/artginzburg/MiddleClick) et [Mos](https://github.com/Caldis/Mos), et de l'utilitaire [smcFanControl](https://github.com/hholtmann/smcFanControl) pour le protocole SMC. snobapp en reprend les principes, pas le code. Les fonctions de veille et de limite de charge s'inspirent d'utilitaires existants (Clamshell, AlDente).

## Licence

[GPL-3.0](LICENSE). Utilise des frameworks privés d'Apple (MultitouchSupport, PowerUI) susceptibles de changer avec macOS.
