// Il motore dell'app: accende la catena, la guarda vivere, la spegne.
//
// Non c'e' logica della guida qui dentro, e non deve essercene. L'app lancia
// `scripts/serve_mac.sh` esattamente come lo lancerebbe un terminale, legge
// quello che stampa e interroga /health. Il giorno che la catena cambia, cambia
// lo script: l'app continua a funzionare senza sapere cos'e' cambiato.
//
// Questa e' anche la ragione per cui la prova e la sonda del discovery girano
// come processi Python del progetto invece che essere riscritte in Swift: la
// verita' su come si parla al server sta in un posto solo.

import Foundation
import SwiftUI

/// A che punto e' la catena.
enum Fase: Equatable {
    case spenta
    case avvio(String)   // cosa sta facendo adesso
    case pronta
    case caduta(String)

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
}

/// Come e' configurata la voce. I numeri sono misurati, e stanno in PIANO-MAC.md.
enum Voce: String, CaseIterable, Identifiable {
    case kokoro, sistema, clonata
    var id: String { rawValue }

    var etichetta: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .sistema: return "Voce di sistema"
        case .clonata: return "Voce clonata"
        }
    }

    var nota: String {
        switch self {
        case .kokoro: return "neurale, in tempo reale"
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
        self == .q4
            ? "prima frase in 0,9 s, 3,9 GB"
            : "risposte un filo migliori, +0,6 s e +1,2 GB"
    }
}

struct Salute: Equatable {
    var asr = ""
    var llm = ""
    var tts = ""
    var vlm = ""
    var pezzi = 0
    var profilo = ""
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
    @Published var salute: Salute?
    @Published var righe: [String] = []
    @Published var indirizzo: String = "127.0.0.1"
    @Published var serverSullaRete: [ServerVisto] = []
    @Published var sondaInCorso = false
    @Published var esitoProva: String?
    @Published var provaInCorso = false
    @Published var requisiti: [Requisito] = []
    /// Quanta memoria e' riutilizzabile adesso, in percentuale. Vedi `misuraLaMemoria`.
    @Published var liberaPercento: Double = 0

    @AppStorage("voce") var voce: Voce = .kokoro
    @AppStorage("taglia") var taglia: Taglia = .q4
    @AppStorage("rispondiAlDiscovery") var rispondiAlDiscovery: Bool = true
    @AppStorage("porta") var porta: Int = 8765

    let radice: URL
    private var processo: Process?
    private var vigile: Timer?

    init(radice: URL) {
        self.radice = radice
        self.indirizzo = Motore.indirizzoLocale()
        controllaRequisiti()
        misuraLaMemoria()
    }

    // MARK: - accendere e spegnere

    func accendi() {
        guard processo == nil else { return }
        righe = []
        fase = .avvio("avvio dei modelli...")
        esitoProva = nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec ./scripts/serve_mac.sh"]
        p.currentDirectoryURL = radice

        // UN AMBIENTE PULITO, NON QUELLO DI CHI HA APERTO L'APP.
        //
        // Ereditare l'ambiente del processo padre sembra prudente e non lo e':
        // a seconda di come l'app viene aperta - dal Finder, dal Dock, da un
        // terminale, da un'altra applicazione - il figlio si trova addosso
        // variabili diverse, e il servizio si comporta in modo diverso senza
        // che si capisca perche'. Qui si passa il minimo indispensabile, piu'
        // le scelte fatte nella finestra. Il resto lo mette la shell di login.
        let vecchio = ProcessInfo.processInfo.environment
        var ambiente: [String: String] = [:]
        for chiave in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "PATH"] {
            if let valore = vecchio[chiave] { ambiente[chiave] = valore }
        }
        ambiente["OLIVERA_TTS"] = voce.variabile
        ambiente["OLIVERA_QUANT"] = taglia.rawValue
        ambiente["OLIVERA_PORT"] = String(porta)
        ambiente["OLIVERA_DISCOVERY"] = rispondiAlDiscovery ? "1" : "0"
        // Senza questo Python bufferizza e il log arriva a blocchi: l'avvio
        // sembra piantato per venti secondi e poi salta alla fine.
        ambiente["PYTHONUNBUFFERED"] = "1"
        p.environment = ambiente

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

                // MORIRE DURANTE L'AVVIO E' SEMPRE UN GUASTO, ANCHE CON CODICE ZERO.
                //
                // Lo script ha un trap di uscita che chiude i figli, e il trap
                // rimette a posto il codice di ritorno: uno script che muore
                // sulla seconda riga puo' presentarsi come un'uscita pulita.
                // La prima volta e' costata un'ora, perche' l'app tornava
                // semplicemente a "spenta" come se il pulsante non fosse stato
                // premuto. Se non siamo mai arrivati a "pronta", e' caduta.
                if stavaPartendo {
                    let ultima = self.righe.last(where: {
                        $0.contains("rror") || $0.contains("line ") || $0.contains("not found")
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
        vigile?.invalidate()
        vigile = nil
        salute = nil
        processo?.terminate()
        processo = nil
        // La rete di sicurezza: se qualcosa e' sopravvissuto al segnale, lo
        // script di arresto lo chiude per nome. Senza questo un llama-server
        // orfano si tiene quattro giga fino al riavvio della macchina.
        let pulizia = Process()
        pulizia.executableURL = URL(fileURLWithPath: "/bin/zsh")
        pulizia.arguments = ["-lc", "./scripts/stop_mac.sh"]
        pulizia.currentDirectoryURL = radice
        try? pulizia.run()
    }

    private func assorbi(_ testo: String) {
        for riga in testo.split(separator: "\n", omittingEmptySubsequences: false) {
            let r = String(riga)
            if r.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            righe.append(r)
            if righe.count > 600 { righe.removeFirst(righe.count - 600) }

            if r.contains("llama.cpp:") { fase = .avvio("carico il modello di linguaggio...") }
            if r.contains("backend pronti") { fase = .avvio("scaldo i modelli...") }
            if r.contains("warmup in") { fase = .avvio("quasi pronta...") }
            if r.contains("in ascolto su") { fase = .pronta }
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

    /// Quanta memoria e' davvero disponibile adesso.
    ///
    /// QUESTA MISURA ESISTE PER UN POMERIGGIO INTERO. Su questo Mac da sedici
    /// gigabyte, con Chrome, Drive che sincronizza e mezza dozzina di sessioni
    /// aperte, la catena parte, i tre processi si vedono in Monitoraggio
    /// Attivita', e poi il servizio smette di rispondere. Non e' bloccato: e'
    /// stato paginato via per intero - `rss` a zero, CPU a zero - e il sistema
    /// non lo rimette dentro. Da fuori sembra un guasto del codice, e non lo e'.
    ///
    /// E NON SI GUARDA LO SWAP. Anche questo e' costato tempo: `vm.swapusage`
    /// dice quanto e' grande il file di scambio, e quel file macOS non lo
    /// rimpicciolisce mai. Dopo aver chiuso tutto continuava a dire 7,9 GB
    /// mentre la memoria libera era gia' tornata al 71%. Il numero che conta e'
    /// quanta memoria e' riutilizzabile adesso: libera piu' inattiva, che il
    /// sistema puo' riprendersi quando serve.
    func misuraLaMemoria() {
        let stato = Motore.esegui(radice: radice, comando: "vm_stat; sysctl -n hw.memsize")
        var pagine: [String: Double] = [:]
        var totaleByte: Double = 0
        var dimensionePagina: Double = 16384

        for riga in stato.split(separator: "\n") {
            if riga.hasPrefix("Mach Virtual Memory Statistics"),
               let p = riga.components(separatedBy: "page size of ").last,
               let valore = Double(p.components(separatedBy: " ").first ?? "") {
                dimensionePagina = valore
            } else if riga.contains(":") {
                let pezzi = riga.components(separatedBy: ":")
                let chiave = pezzi[0].trimmingCharacters(in: .whitespaces)
                let valore = pezzi.count > 1
                    ? Double(pezzi[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")) ?? 0
                    : 0
                pagine[chiave] = valore
            } else if let soloNumero = Double(riga.trimmingCharacters(in: .whitespaces)) {
                totaleByte = soloNumero
            }
        }

        guard totaleByte > 0 else { return }
        let riutilizzabile = (pagine["Pages free"] ?? 0)
            + (pagine["Pages inactive"] ?? 0)
            + (pagine["Pages speculative"] ?? 0)
            + (pagine["Pages purgeable"] ?? 0)
        liberaPercento = (riutilizzabile * dimensionePagina) / totaleByte * 100
    }

    /// Sotto questa soglia la catena entra in memoria a fatica: la guida serve
    /// circa cinque gigabyte fra modello di linguaggio, ascolto e voce.
    var memoriaStretta: Bool { liberaPercento > 0 && liberaPercento < 35 }
    var memoriaCritica: Bool { liberaPercento > 0 && liberaPercento < 20 }

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
        s.profilo = json["profile"] as? String ?? ""
        salute = s
        if case .avvio = fase { fase = .pronta }
    }

    // MARK: - chi risponde sulla rete

    func sondaLaRete() {
        sondaInCorso = true
        Task.detached { [radice] in
            let uscita = Motore.esegui(
                radice: radice,
                comando: "./.venv/bin/python -m olivera.tools.chi_risponde --json"
            )
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
        Task.detached { [radice, porta] in
            let uscita = Motore.esegui(
                radice: radice,
                comando: "./.venv/bin/python scripts/prova_rapida.py --url ws://127.0.0.1:\(porta)/ws --json"
            )
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

    struct Requisito: Identifiable {
        var id: String { nome }
        var nome: String
        var presente: Bool
        var comeSiRimette: String
    }

    func controllaRequisiti() {
        let fm = FileManager.default
        var elenco: [Requisito] = []

        func nelPercorso(_ eseguibile: String) -> Bool {
            !Motore.esegui(radice: radice, comando: "command -v \(eseguibile) || true")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        elenco.append(.init(
            nome: "ambiente Python",
            presente: fm.fileExists(atPath: radice.appendingPathComponent(".venv/bin/python").path),
            comeSiRimette: "python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt"))
        elenco.append(.init(
            nome: "whisper.cpp",
            presente: nelPercorso("whisper-server"),
            comeSiRimette: "brew install whisper-cpp"))
        elenco.append(.init(
            nome: "llama.cpp",
            presente: nelPercorso("llama-server"),
            comeSiRimette: "brew install llama.cpp"))
        elenco.append(.init(
            nome: "Ollama",
            presente: nelPercorso("ollama"),
            comeSiRimette: "brew install ollama"))

        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        elenco.append(.init(
            nome: "pesi dell'ascolto",
            presente: fm.fileExists(atPath: cache.appendingPathComponent("whisper-cpp/ggml-large-v3-turbo-q8_0.bin").path),
            comeSiRimette: "./scripts/setup_mac.sh"))
        elenco.append(.init(
            nome: "pesi della voce",
            presente: fm.fileExists(atPath: cache.appendingPathComponent("olivera/kokoro/kokoro-v1.0.onnx").path),
            comeSiRimette: "./scripts/setup_mac.sh"))
        elenco.append(.init(
            nome: "indice del corpus",
            presente: fm.fileExists(atPath: radice.appendingPathComponent("data/index/vectors.npy").path),
            comeSiRimette: "./.venv/bin/python -m olivera.rag.index"))

        requisiti = elenco
    }

    var tuttoPronto: Bool { requisiti.allSatisfy(\.presente) }

    func preparaLaMacchina() {
        fase = .avvio("preparo (scarica qualche centinaio di MB)...")
        Task.detached { [radice] in
            _ = Motore.esegui(radice: radice, comando: "./scripts/setup_mac.sh")
            await MainActor.run {
                self.controllaRequisiti()
                self.fase = .spenta
            }
        }
    }

    // MARK: - utilita'

    nonisolated static func esegui(radice: URL, comando: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", comando]
        p.currentDirectoryURL = radice
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let dati = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: dati, encoding: .utf8) ?? ""
    }

    nonisolated static func indirizzoLocale() -> String {
        var indirizzo = "127.0.0.1"
        var puntatore: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&puntatore) == 0, let primo = puntatore else { return indirizzo }
        defer { freeifaddrs(puntatore) }
        var corrente = primo
        while true {
            let interfaccia = corrente.pointee
            if
                interfaccia.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                let nome = interfaccia.ifa_name,
                String(cString: nome).hasPrefix("en")
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interfaccia.ifa_addr, socklen_t(interfaccia.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let trovato = String(cString: host)
                    if !trovato.hasPrefix("127.") { indirizzo = trovato; break }
                }
            }
            guard let prossimo = interfaccia.ifa_next else { break }
            corrente = prossimo
        }
        return indirizzo
    }
}
