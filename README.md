<p align="center"><img src="Resources/logo.png" width="160" alt="snobapp"></p>

<h1 align="center">snobapp</h1>

<p align="center">Une petite app de barre de menus macOS qui réunit quatre utilitaires en un seul.</p>

> **English** — snobapp is a tiny macOS menu-bar app: three-finger middle click on the trackpad, mouse-wheel reverse, speed and acceleration control and smooth scrolling, sleep on lid close even with external displays, and a battery charge limit with a discharge mode. Apple Silicon, macOS 13+ (charge limit: macOS 26.4+).

## Fonctions

| | |
|---|---|
| **Clic du milieu au trackpad** | cliquer avec 3 doigts (réglable) = clic du milieu ; taper avec 3 doigts aussi. Apps ignorables. |
| **Molette de la souris** | inversion verticale / horizontale, **vitesse réglable** (0,5× à 3×), **accélération réglable** (0 % : chaque cran vaut un cran lent ; 100 % : courbe macOS) et **défilement fluide** avec réglage de douceur. Le trackpad et la Magic Mouse ne sont jamais touchés. |
| **Veille capot fermé** | fermer le capot met le Mac en veille, même avec des écrans externes branchés. |
| **Limite de charge** | recharge max. réglable et **mode décharge** dans le menu. |

## Installation

1. Téléchargez `snobapp.zip` depuis les [Releases](../../releases), dézippez et placez `snobapp.app` dans `/Applications` (ou `~/Applications`).
2. L'app n'est pas notariée : au premier lancement, clic droit › **Ouvrir** (ou `xattr -dr com.apple.quarantine snobapp.app`).
3. Autorisez snobapp dans **Réglages Système › Confidentialité et sécurité › Accessibilité** (nécessaire pour le clic du milieu et la molette).
4. Pour une limite de charge sous 80 % ou le mode décharge : **Réglages › Batterie › Installer…** (mot de passe administrateur, une seule fois).

## Comment fonctionne la limite de charge

- **Limite native de macOS** (macOS 26.4+, paliers 80/85/90/95/100 %) : snobapp la règle sur le palier le plus proche au-dessus de votre limite. macOS l'applique lui-même — app fermée, Mac en veille ou service arrêté. snobapp ne la remet jamais à 100 % en quittant.
- **Service root** (facultatif) pour descendre sous le palier natif et pour le mode décharge : il coupe l'adaptateur secteur via le SMC (clé `CHIE`) au-dessus de la limite, et le rebranche quelques pourcents plus bas.
- **Sécurité** : la logique vit dans le service, indépendante de l'app ; avant chaque veille et à l'arrêt, l'adaptateur est rebranché. Au pire, la batterie remonte au palier natif, jamais à 100 %.
- Sur les Mac récents (macOS 27), les clés SMC d'arrêt de charge (`CHTE`, `CH0B`/`CH0C`) n'existent plus : seule la décharge est pilotable, d'où cette combinaison.

Le service : `/Library/PrivilegedHelperTools/io.github.snoblevrai.snobapp.helper` + `/Library/LaunchDaemons/io.github.snoblevrai.snobapp.helper.plist`, échanges via `/Library/Application Support/snobapp/`. Désinstallation depuis Réglages › Batterie.

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
| `SmoothScroller.swift` | défilement fluide (réserve de pixels restituée à ~120 Hz, décroissance exponentielle) |
| `EventTap.swift` | un seul tap d'évènements pour les clics et la molette |
| `LidSleep.swift` | veille à la fermeture du capot (`IOPMrootDomain`, `IOPMSleepSystem`) |
| `BatteryController.swift` | limite native, installation du service |
| `BatteryDaemon.swift` | service root : décharge et limite sous le palier natif |
| `SystemMonitor.swift` | réveil, branchement de trackpad, écrans, app au premier plan |
| `StatusMenu.swift`, `SettingsView.swift` | menu et réglages (onglets) |

## Crédits

Inspiré des projets open source [MiddleClick](https://github.com/artginzburg/MiddleClick) et [Mos](https://github.com/Caldis/Mos), et de l'utilitaire [smcFanControl](https://github.com/hholtmann/smcFanControl) pour le protocole SMC. snobapp en reprend les principes, pas le code. Les fonctions de veille et de limite de charge s'inspirent d'utilitaires existants (Clamshell, AlDente).

## Licence

[GPL-3.0](LICENSE). Utilise des frameworks privés d'Apple (MultitouchSupport, PowerUI) susceptibles de changer avec macOS.
