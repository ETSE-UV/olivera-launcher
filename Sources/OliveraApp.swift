// L'app che accende la guida sul Mac.
//
// Serve a una cosa sola e va giudicata su quella: dal doppio clic al momento in
// cui in Unity si puo' premere Play, senza aprire un terminale e senza doversi
// ricordare niente. Tutto il resto della finestra - la sonda della rete, la
// prova, il registro - esiste perche' quando NON funziona la domanda successiva
// e' sempre la stessa: e' acceso? risponde? sta girando il codice giusto?

import SwiftUI

@main
struct OliveraApp: App {
    @StateObject private var motore = Motore(radice: OliveraApp.radiceDelProgetto())

    /// `--stampa-lingua`: stampa su stdout le stringhe chiave nella lingua
    /// corrente ed esce, senza aprire la finestra. Diagnostica a costo zero
    /// (critica del lotto LINGUA, C2 e M3): NON sostituisce la prova vera, che
    /// legge l'albero di accessibilita' della finestra reale con -AppleLanguages,
    /// ma la affianca - se questa stampa la lingua sbagliata il problema e' nelle
    /// tabelle, se la finestra mostra la lingua sbagliata ma questa e' giusta il
    /// problema e' in una vista che non usa il meccanismo automatico (O2).
    /// Sicuro da chiamare prima che `motore` esista davvero: con @StateObject
    /// l'autoclosure si valuta al primo `body`, non qui - Motore(radice:) non
    /// parte, ne' `controllaRequisiti()` ne' `adotta()` (misurato: M3).
    init() {
        guard CommandLine.arguments.contains("--stampa-lingua") else { return }
        print("preferredLocalizations: \(Bundle.main.preferredLocalizations)")
        print(Fase.spenta.descrizione)
        print(Fase.pronta.descrizione)
        for r in piattaformaCorrente().requisiti(radice: OliveraApp.radiceDelProgetto()) {
            print(r.nome)
        }
        exit(0)
    }

    var body: some Scene {
        Window("Olivera", id: "principale") {
            Finestra()
                .environmentObject(motore)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 700)
    }

    /// Dov'e' il progetto.
    ///
    /// L'app compilata sta in `<progetto>/app/build/Olivera.app`, quindi il
    /// progetto e' quattro cartelle sopra il bundle. Se qualcuno sposta l'app
    /// altrove si ricade sulla posizione consueta, e in ultima istanza sulla
    /// cartella di lavoro: meglio partire e dire cosa manca che non partire.
    static func radiceDelProgetto() -> URL {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let risalendo = bundle
            .deletingLastPathComponent()   // build/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // <progetto>/
        let candidati = [
            risalendo,
            fm.homeDirectoryForCurrentUser.appendingPathComponent("dev/olivera-voice"),
            URL(fileURLWithPath: fm.currentDirectoryPath),
        ]
        for c in candidati where fm.fileExists(atPath: c.appendingPathComponent("olivera/net/server.py").path) {
            return c
        }
        return candidati[0]
    }
}
