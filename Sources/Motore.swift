// Il motore dell'app: accende la catena, la guarda vivere, la spegne.
//
// Non c'e' logica della guida qui dentro, e non c'e' piu' nemmeno niente che
// sappia di macOS: quello sta in Piattaforma.swift. Qui restano tre cose - far
// partire un comando, leggere le righe di stato, chiedere /health - e nessuna
// delle tre cambia passando a Windows.

import Foundation
import SwiftUI

/// A che punto e' la catena. Sono le stesse fasi che dichiara `olivera/stato.py`:
/// se ne aggiungono una la', si aggiunge un caso qui, e il compilatore lo dice.
enum Fase: Equatable {
    case spenta
    case avvio(String)
    case pronta
    case caduta(String)

    /// Dal nome che arriva nel JSON.
    static func da(_ nome: String, testo: String) -> Fase {
        switch nome {
        case "pronta": return .pronta
        case "errore": return .caduta(testo)
        default: return .avvio(testo)
        }
    }

    var descrizione: String {
        switch self {
        case .spenta: return "spenta"
        case .avvio(let cosa): return cosa
        case .pronta: return "pronta"
        case .caduta(let perche): return perche
        }
    }

    var colore: Color {
        switch self {
        case .spenta: return .secondary
        case .avvio: return .orange
        case .pronta: return .green
        case .caduta: return .red
        }
    }

    /// Quanto siamo avanti, da 0 a 1. Le fasi sono note e in ordine, quindi la
    /// barra puo' essere una barra vera invece di una rotella che gira.
    static func avanzamento(_ nome: String) -> Double {
        let ordine = ["avvio": 0.15, "llm": 0.35, "modelli": 0.6, "scaldo": 0.85, "pronta": 1.0]
        return ordine[nome] ?? 0.1
    }
}

enum Voce: String, CaseIterable, Identifiable {
    case kokoro, sistema, clonata
    var id: String { rawValue }

    var etichetta: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .sistema: return "Di sistema"
        case .clonata: return "Clonata"
        }
    }

    var nota: String {
        switch self {
        case .kokoro: return "neurale, 0,18 di fattore di tempo reale"
        case .sistema: return "0,3 s piu' rapida, ma si sente che e' una macchina"
        case .clonata: return "fuori dal tempo reale su questo Mac: solo per ascoltarla"
        }
    }

    var variabile: String {
        switch self {
        case .kokoro: return "kokoro"
        case .sistema: return "say"
        case .clonata: return "qwen-mps"
        }
    }
}

enum Taglia: String, CaseIterable, Identifiable {
    case q4 = "q4_K_M"
    case q8 = "q8_0"
    var id: String { rawValue }
    var etichetta: String { self == .q4 ? "4 bit" : "8 bit" }
    var nota: String {
        self == .q4 ? "prima frase in 0,9 s, 3,9 GB" : "risposte un filo migliori, +0,6 s e +1,2 GB"
    }
}

struct Salute: Equatable {
    var asr = ""
    var llm = ""
    var tts = ""
    var vlm = ""
    var pezzi = 0
}

struct ServerVisto: Identifiable, Equatable {
    var id: String { ip }
    var ip: String
    var porta: Int
    var questoMac: Bool
    var descrizione: String
}

@MainActor
final class Motore: ObservableObject {
    @Published var fase: Fase = .spenta
    @Published var avanzamento: Double = 0
    @Published var salute: Salute?
    @Published var righe: [String] = []
    @Published var indirizzo: String = "127.0.0.1"
    @Published var serverSullaRete: [ServerVisto] = []
    @Published var sondaInCorso = false
    @Published var esitoProva: String?
    @Published var provaInCorso = false
    @Published var requisiti: [Requisito] = []
    @Published var liberaPercento: Double = 0

    @AppStorage("voce") var voce: Voce = .kokoro
    @AppStorage("taglia") var taglia: Taglia = .q4
    @AppStorage("rispondiAlDiscovery") var rispondiAlDiscovery: Bool = true
    @AppStorage("porta") var porta: Int = 8765

    let radice: URL
    let piattaforma: Piattaforma
    private var processo: Process?
    private var vigile: Timer?
    private var resto = ""   // meta' riga rimasta dalla lettura precedente

    init(radice: URL, piattaforma: Piattaforma = piattaformaCorrente()) {
        self.radice = radice
        self.piattaforma = piattaforma
        self.indirizzo = piattaforma.indirizzoLocale()
        controllaRequisiti()
        misuraLaMemoria()
    }

    // MARK: - accendere e spegnere

    func accendi() {
        guard processo == nil else { return }
        righe = []
        resto = ""
        avanzamento = 0
        fase = .avvio("avvio...")
        esitoProva = nil

        let (eseguibile, argomenti) = piattaforma.comando(
            piattaforma.avvio(porta: porta, discovery: rispondiAlDiscovery)
        )
        let p = Process()
        p.executableURL = eseguibile
        p.arguments = argomenti
        p.currentDirectoryURL = radice
        p.environment = Guscio.ambientePulito([
            "OLIVERA_TTS": voce.variabile,
            "OLIVERA_QUANT": taglia.rawValue,
            "OLIVERA_PORT": String(porta),
        ])

        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = tubo
        tubo.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let dati = handle.availableData
            guard !dati.isEmpty, let testo = String(data: dati, encoding: .utf8) else { return }
            Task { @MainActor in self?.assorbi(testo) }
        }

        p.terminationHandler = { [weak self] finito in
            Task { @MainActor in
                guard let self else { return }
                let stavaPartendo: Bool
                if case .avvio = self.fase { stavaPartendo = true } else { stavaPartendo = false }
                self.processo = nil
                self.salute = nil
                if case .spenta = self.fase { return }  // spegnimento voluto
                // Se il servizio ha gia' detto PERCHE' sta morendo, quella frase
                // vale piu' di "codice 1": non la si copre con il riassunto.
                if case .caduta = self.fase { return }

                // MORIRE DURANTE L'AVVIO E' SEMPRE UN GUASTO, ANCHE CON CODICE ZERO.
                // Prima in mezzo c'era una shell con un trap di uscita che
                // rimetteva a posto il codice di ritorno, e uno script morto
                // sulla seconda riga si presentava come un'uscita pulita.
                // Adesso in mezzo non c'e' piu' niente, ma la regola resta:
                // se non siamo arrivati a "pronta", e' caduta.
                if stavaPartendo {
                    let ultima = self.righe.last(where: {
                        $0.contains("rror") || $0.contains("Error") || $0.contains("manca")
                    }) ?? self.righe.last ?? "nessun dettaglio"
                    self.fase = .caduta("non e' partita: \(ultima)")
                } else {
                    self.fase = finito.terminationStatus == 0
                        ? .spenta
                        : .caduta("si e' fermata (codice \(finito.terminationStatus))")
                }
            }
        }

        do {
            try p.run()
            processo = p
            avviaVigile()
        } catch {
            fase = .caduta("non parte: \(error.localizedDescription)")
        }
    }

    func spegni() {
        fase = .spenta
        avanzamento = 0
        vigile?.invalidate()
        vigile = nil
        salute = nil
        // Basta chiudere questo: il lanciatore chiude i suoi figli da solo, su
        // ogni sistema, e non lascia orfani. Prima serviva uno script di
        // pulizia perche' in mezzo c'era una shell che non li conosceva tutti.
        processo?.terminate()
        processo = nil
    }

    /// Legge quello che arriva, una riga alla volta, tenendo da parte la meta'
    /// riga che si e' spezzata fra due letture. Senza questo, una riga di stato
    /// tagliata a meta' dal buffer non viene riconosciuta e la barra si ferma.
    private func assorbi(_ testo: String) {
        resto += testo
        var pezzi = resto.components(separatedBy: "\n")
        resto = pezzi.removeLast()
        for riga in pezzi where !riga.trimmingCharacters(in: .whitespaces).isEmpty {
            righe.append(riga)
            if righe.count > 600 { righe.removeFirst(righe.count - 600) }
            if let s = Stato.leggi(riga) {
                fase = .da(s.fase, testo: s.testo)
                avanzamento = Fase.avanzamento(s.fase)
            }
        }
    }

    // MARK: - guardarla vivere

    private func avviaVigile() {
        vigile?.invalidate()
        misuraLaMemoria()
        vigile = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.chiediSalute()
                self?.misuraLaMemoria()
            }
        }
    }

    private func chiediSalute() async {
        guard let url = URL(string: "http://127.0.0.1:\(porta)/health") else { return }
        var richiesta = URLRequest(url: url)
        richiesta.timeoutInterval = 2
        guard
            let (dati, _) = try? await URLSession.shared.data(for: richiesta),
            let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any]
        else { return }

        var s = Salute()
        s.asr = json["asr"] as? String ?? ""
        s.llm = json["llm"] as? String ?? ""
        s.tts = json["tts"] as? String ?? ""
        s.vlm = json["vlm"] as? String ?? ""
        s.pezzi = json["chunks"] as? Int ?? 0
        salute = s
    }

    /// Quanta memoria e' davvero disponibile adesso.
    ///
    /// Con la macchina piena il servizio viene paginato via per intero - `rss` a
    /// zero, CPU a zero - e il sistema non lo rimette dentro: da fuori e'
    /// identico a un blocco. E' costato un pomeriggio, due volte.
    func misuraLaMemoria() {
        let valore = piattaforma.memoriaLibera(radice: radice)
        if valore > 0 { liberaPercento = valore }
    }

    /// Sotto queste soglie la catena entra in memoria a fatica: serve circa
    /// mezza dozzina di gigabyte fra modello di linguaggio, ascolto e voce.
    var memoriaStretta: Bool { liberaPercento > 0 && liberaPercento < 35 }
    var memoriaCritica: Bool { liberaPercento > 0 && liberaPercento < 20 }

    // MARK: - chi risponde sulla rete

    func sondaLaRete() {
        sondaInCorso = true
        let comando = piattaforma.sonda()
        Task.detached { [radice, piattaforma] in
            let uscita = Guscio.esegui(piattaforma: piattaforma, radice: radice, comando: comando)
            var trovati: [ServerVisto] = []
            if
                let dati = uscita.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
                let elenco = json["server"] as? [[String: Any]]
            {
                for voce in elenco {
                    let salute = voce["salute"] as? [String: Any] ?? [:]
                    let descrizione = (salute["tts"] as? String).map {
                        "\($0) · \(salute["llm"] as? String ?? "?")"
                    } ?? "non risponde alla salute"
                    trovati.append(ServerVisto(
                        ip: voce["ip"] as? String ?? "?",
                        porta: voce["porta"] as? Int ?? 8765,
                        questoMac: voce["questo_mac"] as? Bool ?? false,
                        descrizione: descrizione
                    ))
                }
            }
            await MainActor.run { [trovati] in
                self.serverSullaRete = trovati
                self.sondaInCorso = false
            }
        }
    }

    // MARK: - la prova

    func prova() {
        provaInCorso = true
        esitoProva = nil
        let comando = piattaforma.prova(porta: porta)
        Task.detached { [radice, piattaforma] in
            let uscita = Guscio.esegui(piattaforma: piattaforma, radice: radice, comando: comando)
            let testo = Motore.leggiProva(uscita)
            await MainActor.run {
                self.esitoProva = testo
                self.provaInCorso = false
            }
        }
    }

    nonisolated private static func leggiProva(_ uscita: String) -> String {
        guard
            let dati = uscita.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any]
        else { return "la prova non ha risposto" }
        if let errore = json["errore"] as? String { return "non risponde: \(errore)" }

        let ordine = json["ordine"] as? [String: Any] ?? [:]
        let domanda = json["domanda"] as? [String: Any] ?? [:]
        let msOrdine = ordine["primoTestoMs"] as? Int ?? 0
        let audio = domanda["primoAudioMs"] as? Int ?? 0

        var righe: [String] = []
        if let azione = ordine["azione"] as? [String: Any] {
            let tipo = azione["kind"] as? String ?? "?"
            let bersaglio = azione["target"].map { "\($0)" } ?? ""
            righe.append("ordine eseguito (\(tipo) \(bersaglio)) in \(msOrdine) ms")
        } else {
            righe.append("ORDINE NON ESEGUITO: ha risposto a parole. Il server gira su codice vecchio.")
        }
        righe.append("domanda: primo suono in \(String(format: "%.1f", Double(audio) / 1000)) s")
        return righe.joined(separator: "\n")
    }

    // MARK: - cosa manca prima di poter accendere

    func controllaRequisiti() { requisiti = piattaforma.requisiti(radice: radice) }

    var tuttoPronto: Bool { requisiti.allSatisfy(\.presente) }

    func preparaLaMacchina() {
        fase = .avvio("preparo (scarica qualche centinaio di MB)...")
        let comando = piattaforma.preparazione()
        Task.detached { [radice, piattaforma] in
            _ = Guscio.esegui(piattaforma: piattaforma, radice: radice, comando: comando)
            await MainActor.run {
                self.controllaRequisiti()
                self.fase = .spenta
            }
        }
    }
}
