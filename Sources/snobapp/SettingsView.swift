import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(Key.middleClickEnabled) private var middleClickEnabled = true
    @AppStorage(Key.fingers) private var fingers = 3
    @AppStorage(Key.allowMoreFingers) private var allowMoreFingers = false
    @AppStorage(Key.tapToClick) private var tapToClick = true
    @AppStorage(Key.maxDistanceDelta) private var maxDistanceDelta = 0.05
    @AppStorage(Key.maxTimeDelta) private var maxTimeDelta = 300.0
    @AppStorage(Key.reverseEnabled) private var reverseEnabled = true
    @AppStorage(Key.reverseVertical) private var reverseVertical = true
    @AppStorage(Key.reverseHorizontal) private var reverseHorizontal = true
    @AppStorage(Key.scrollAcceleration) private var scrollAcceleration = 0.5
    @AppStorage(Key.smoothScrollEnabled) private var smoothScrollEnabled = true
    @AppStorage(Key.smoothness) private var smoothness = 0.4
    @AppStorage(Key.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Key.lidSleepEnabled) private var lidSleepEnabled = true
    @AppStorage(Key.batteryLimitEnabled) private var batteryLimitEnabled = true
    @AppStorage(Key.batteryLimit) private var batteryLimit = 80
    @AppStorage(Key.dischargeMode) private var dischargeMode = false

    // Les Command Line Tools n'embarquent pas le plugin de macros SwiftUI (@State) :
    // l'état local passe par un ObservableObject.
    @ObservedObject var model: SettingsModel

    var body: some View {
        // Onglets : avec une seule page défilante, les sections du bas (Batterie, Capot…)
        // restaient invisibles sans faire défiler (retour utilisateur v3).
        TabView(selection: $model.tab) {
            Form {
            if !model.trusted {
                Section {
                    HStack {
                        Label("Accès Accessibilité requis", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { Accessibility.prompt(); Accessibility.openSettings() }
                    }
                }
            }
            Section("Clic du milieu (trackpad)") {
                Toggle("Activer", isOn: $middleClickEnabled)
                Group {
                    Stepper("Nombre de doigts : \(fingers)", value: $fingers, in: 2...5)
                    Toggle("Accepter plus de doigts", isOn: $allowMoreFingers)
                    Toggle("Taper pour cliquer", isOn: $tapToClick)
                    LabeledContent("Durée max. du tap") {
                        HStack {
                            Slider(value: $maxTimeDelta, in: 100...600, step: 25)
                            Text("\(Int(maxTimeDelta)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }
                    .disabled(!tapToClick)
                    LabeledContent("Mouvement toléré") {
                        HStack {
                            Slider(value: $maxDistanceDelta, in: 0.01...0.2, step: 0.01)
                            Text(String(format: "%.2f", maxDistanceDelta)).monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    .disabled(!tapToClick)
                }
                .disabled(!middleClickEnabled)
                if fingers == 3 {
                    Text("Avec 3 doigts, « Glisser avec trois doigts » et « Toucher avec trois doigts » (Recherche) de macOS entrent en conflit. Passez à 4 doigts ou désactivez ces gestes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Apps ignorées (clic du milieu)") {
                // Pas de List ici : une liste défilante imbriquée dans un Form s'effondre à 0 px.
                if model.ignored.isEmpty {
                    Text("Aucune").foregroundStyle(.secondary)
                }
                ForEach(model.ignored, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Button {
                            model.ignored.removeAll { $0 == id }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Retirer")
                    }
                }
                Button("Ajouter une app…", action: addApp)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Clic", systemImage: "hand.tap") }
            .tag(0)
            Form {
            if !model.trusted {
                Section {
                    HStack {
                        Label("Accès Accessibilité requis", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { Accessibility.prompt(); Accessibility.openSettings() }
                    }
                }
            }
            Section("Défilement de la souris") {
                Toggle("Inverser le sens de la molette", isOn: $reverseEnabled)
                Toggle("Vertical", isOn: $reverseVertical).disabled(!reverseEnabled)
                Toggle("Horizontal", isOn: $reverseHorizontal).disabled(!reverseEnabled)
                LabeledContent("Vitesse") {
                    HStack {
                        Slider(value: $scrollSpeed, in: 0.5...3, step: 0.1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("0,5×").font(.caption)
                        } maximumValueLabel: {
                            Text("3×").font(.caption)
                        }
                        Text(String(format: "%.1f×", scrollSpeed).replacingOccurrences(of: ".", with: ","))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Accélération") {
                    HStack {
                        Slider(value: $scrollAcceleration, in: 0...1, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Aucune").font(.caption)
                        } maximumValueLabel: {
                            Text("macOS").font(.caption)
                        }
                        Text("\(Int((scrollAcceleration * 100).rounded())) %").monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Vitesse : multiplie la distance de chaque cran. Accélération : un cran lent ne change pas, seul l'emballement quand on tourne vite est réduit. Le trackpad et la Magic Mouse ne sont jamais modifiés.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Défilement fluide") {
                Toggle("Lisser la molette", isOn: $smoothScrollEnabled)
                LabeledContent("Douceur") {
                    HStack {
                        Slider(value: $smoothness, in: 0...1, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Vif").font(.caption)
                        } maximumValueLabel: {
                            Text("Doux").font(.caption)
                        }
                        Text("\(Int((SmoothScroller.settleTime(smoothness: smoothness) * 1000).rounded())) ms")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!smoothScrollEnabled)
                Text("Chaque cran est découpé en petits pas calés sur l'écran, avec accélération et décélération douces ; en rotation continue la vitesse reste régulière. La durée indiquée est celle d'un cran isolé.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Défilement", systemImage: "computermouse") }
            .tag(1)
            Form {
            if !model.trusted {
                Section {
                    HStack {
                        Label("Accès Accessibilité requis", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { Accessibility.prompt(); Accessibility.openSettings() }
                    }
                }
            }
            Section("Batterie") {
                Toggle("Limiter la recharge", isOn: $batteryLimitEnabled)
                LabeledContent("Recharge max.") {
                    HStack {
                        Slider(value: Binding(get: { Double(batteryLimit) },
                                              set: { batteryLimit = Int($0.rounded()) }),
                               in: 20...100, step: 5)
                        Text("\(batteryLimit) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!batteryLimitEnabled)
                Text(batteryExplanation).font(.caption).foregroundStyle(.secondary)
                if batteryLimitEnabled && (BatteryController.shared.needsHelper(Settings.shared.snapshot) || HelperInstaller.isInstalled) {
                    HStack {
                        Label(helperStatus.text, systemImage: helperStatus.icon)
                            .foregroundStyle(helperStatus.ok ? Color.secondary : Color.orange)
                        Spacer()
                        if !HelperInstaller.isInstalled || HelperInstaller.isOutdated {
                            Button(HelperInstaller.isInstalled ? "Mettre à jour" : "Installer…") {
                                HelperInstaller.install(); model.refresh()
                            }
                        } else {
                            Button("Désinstaller") { HelperInstaller.uninstall(); model.refresh() }
                        }
                    }
                }
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Batterie", systemImage: "battery.75percent") }
            .tag(2)
            Form {
            if !model.trusted {
                Section {
                    HStack {
                        Label("Accès Accessibilité requis", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { Accessibility.prompt(); Accessibility.openSettings() }
                    }
                }
            }
            Section("Capot") {
                Toggle("Mettre en veille quand on ferme le capot", isOn: $lidSleepEnabled)
                Text("Même avec des écrans externes branchés (macOS resterait sinon allumé en mode « clamshell »).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Capot", systemImage: "laptopcomputer") }
            .tag(3)
            Form {
            if !model.trusted {
                Section {
                    HStack {
                        Label("Accès Accessibilité requis", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { Accessibility.prompt(); Accessibility.openSettings() }
                    }
                }
            }
            Section("Général") {
                Toggle("Ouvrir au démarrage", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { LoginItem.set($0); model.launchAtLogin = LoginItem.isEnabled }
                ))
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Général", systemImage: "gearshape") }
            .tag(4)
        }
        .padding(.top, 8)
        .frame(width: 520, height: 600)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if model.trusted != Accessibility.isTrusted { model.trusted = Accessibility.isTrusted }
            model.tick &+= 1
        }
    }

    private var batteryExplanation: String {
        let cap = BatteryController.shared.nativeCap(for: batteryLimit)
        if !BatteryController.shared.nativeSupported {
            return "La limite est tenue par le service snobapp (coupure de l'adaptateur au-delà)."
        }
        if batteryLimit >= cap {
            return "Appliquée par macOS lui-même : fiable même app fermée ou Mac en veille."
        }
        return "macOS bloque la charge à \(cap) % (son minimum) ; le service snobapp décharge ensuite jusqu'à \(batteryLimit) %. Pendant la veille, la batterie ne dépasse jamais \(cap) %."
    }

    private var helperStatus: (text: String, icon: String, ok: Bool) {
        _ = model.tick
        if !HelperInstaller.isInstalled { return ("Service batterie non installé", "exclamationmark.triangle.fill", false) }
        if HelperInstaller.isOutdated { return ("Service batterie à mettre à jour", "arrow.triangle.2.circlepath", false) }
        if !BatteryController.shared.helperAlive { return ("Service batterie installé, sans réponse", "exclamationmark.triangle.fill", false) }
        return ("Service batterie actif", "checkmark.circle.fill", true)
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.ignored.contains(id) { model.ignored.append(id) }
        }
        save()
    }

    private func save() {
        Settings.shared.ignoredApps = model.ignored
        model.ignored = Settings.shared.ignoredApps
    }
}

final class SettingsModel: ObservableObject {
    @Published var ignored: [String] = Settings.shared.ignoredApps
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var trusted = Accessibility.isTrusted
    /// Incrémenté chaque seconde pour rafraîchir l'état du service.
    @Published var tick = 0
    @Published var tab = 0

    /// Resynchronise quand la liste est modifiée depuis le menu de la barre d'état.
    func refresh() {
        ignored = Settings.shared.ignoredApps
        launchAtLogin = LoginItem.isEnabled
        trusted = Accessibility.isTrusted
    }
}

final class SettingsWindowController {
    static func render(to path: String, tab: Int = 0) {
        let model = SettingsModel()
        model.tab = tab
        let view = NSHostingView(rootView: SettingsView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private let model = SettingsModel()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// v6.1 : la fenêtre est entièrement détruite à la fermeture. Avant, elle restait en mémoire
    /// et sa minuterie redessinait la vue SwiftUI chaque seconde, même fenêtre fermée.
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.title = "Réglages snobapp"
            w.isReleasedWhenClosed = false
            w.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in self?.teardown() }
            window = w
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func teardown() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // Libère la vue (et sa minuterie) après la fin de l'animation de fermeture.
        let w = window
        window = nil
        DispatchQueue.main.async { w?.contentView = nil }
    }
}
