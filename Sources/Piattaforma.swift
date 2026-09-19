// Tutto quello che sa di sistema operativo sta qui dentro, e solo qui.
//
// Il resto dell'app - la finestra, il motore, il modo di leggere lo stato del
// servizio - non nomina mai macOS. Portare l'app su Windows vuol dire scrivere
// una seconda conformita' a questo protocollo: sono sei funzioni, e sotto ognuna
// c'e' scritto qual e' l'equivalente su Windows.
//
// L'altra meta' del lavoro e' gia' fatta dall'altra parte: il servizio si avvia
// con `python -m olivera.launch` su entrambi i sistemi, e dice a che punto e' con
// righe `@@olivera {...}` che non dipendono dalla piattaforma. Prima c'erano uno
// script bash e uno PowerShell che sapevano cose diverse, e l'app doveva
// conoscerli tutti e due.

import Foundation
#if os(macOS)
import AppKit
#endif

/// Un requisito che deve esserci prima di poter accendere.
struct Requisito: Identifiable {
    var id: String { nome }
    var nome: String
    var presente: Bool
    var comeSiRimette: String
}

protocol Piattaforma {
    /// Come si chiama, per i messaggi.
    var nome: String { get }

    /// Come si esegue una riga di comando. Torna eseguibile e argomenti, cosi'
    /// chi chiama non deve sapere se sotto c'e' una shell POSIX o PowerShell.
    ///
    /// Windows: `powershell.exe -NoProfile -Command <riga>`.
    func comando(_ riga: String) -> (URL, [String])

    /// L'interprete Python del progetto, relativo alla radice.
    ///
    /// Windows: `.venv\Scripts\python.exe`.
    var python: String { get }

    /// L'indirizzo IPv4 con cui la macchina si presenta sulla rete locale.
    ///
    /// Windows: `GetAdaptersAddresses`, oppure la stessa cosa che fa gia'
    /// `olivera.launch.indirizzo_locale()` in tre righe di Python.
    func indirizzoLocale() -> String

    /// Quanta memoria e' riutilizzabile adesso, in percentuale.
    ///
    /// Windows: `GlobalMemoryStatusEx`, campo `dwMemoryLoad` (che e' l'opposto:
    /// 100 meno quello). NON si guarda il file di scambio: su macOS quel file
    /// non si rimpicciolisce mai e diceva 7,9 GB occupati mentre la memoria
    /// libera era gia' tornata al 71%.
    func memoriaLibera(radice: URL) -> Double

    /// Cosa deve esserci installato prima di poter accendere.
    ///
    /// Windows: cambiano i nomi (`llama-server.exe`, Ollama in
    /// `%LOCALAPPDATA%\Programs\Ollama`) e il comando che li cerca
    /// (`Get-Command` invece di `command -v`).
    func requisiti(radice: URL) -> [Requisito]

    /// Dove stanno i pesi dei modelli, fuori dal repository.
    ///
    /// Windows: `%LOCALAPPDATA%\olivera`.
    var cartellaPesi: URL { get }

    /// Il servizio di sistema che tiene acceso il server senza che nessuno lo
    /// avvii, se e' installato. L'app allora comanda QUELLO, invece di lanciare
    /// un secondo server che trova la porta presa e muore.
    ///
    /// Windows: un'attivita' pianificata (`schtasks`) o un servizio; i comandi
    /// diventano `schtasks /Run /TN olivera` e `schtasks /End /TN olivera`.
    func agente() -> Agente?

    /// Apre un file con l'applicazione di sistema associata (lotto APRI:
    /// "si deve poter interagire con i file nella lista" - il primo modo di
    /// interagire con un documento e' aprirlo come si aprirebbe dal Finder).
    ///
    /// Windows: `Process.Start(percorso)` con `UseShellExecute = true` fa la
    /// stessa cosa - lascia decidere al sistema quale programma associare
    /// all'estensione, invece di indovinarlo qui dentro.
    func apri(file: URL)

    /// Mostra il file nel gestore di file di sistema, gia' selezionato: la
    /// seconda cosa che si puo' fare con un documento (D1, LOTTO-APRI.md),
    /// per chi vuole vedere dove sta senza aprirlo.
    ///
    /// Windows: `explorer.exe /select,"percorso"`.
    func mostraNelFinder(file: URL)
}

/// Un servizio di sistema che sa accendere e spegnere il server.
struct Agente {
    var nome: String
    var accendi: String
    var spegni: String
}

// MARK: - la riga di comando che accende tutto, uguale ovunque

extension Piattaforma {
    /// UNA SOLA per tutti i sistemi, ed e' il punto di questa riorganizzazione.
    /// Le differenze fra Mac e PC - llama.cpp o Ollama, i link simbolici della
    /// cache di HuggingFace, il `keep_alive` della VRAM - stanno dentro
    /// `olivera/launch.py`, dove si leggono una accanto all'altra.
    func avvio(porta: Int, discovery: Bool) -> String {
        var riga = "\(python) -m olivera.launch --port \(porta)"
        if !discovery { riga += " --no-discovery" }
        return riga
    }

    func sonda() -> String { "\(python) -m olivera.tools.chi_risponde --json" }

    func prova(porta: Int) -> String {
        "\(python) scripts/prova_rapida.py --url ws://127.0.0.1:\(porta)/ws --json"
    }

    func preparazione() -> String { "\(python) -m olivera.tools.prepara" }
}

// MARK: - macOS

struct Mac: Piattaforma {
    let nome = "macOS"
    let python = "./.venv/bin/python"

    var cartellaPesi: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/olivera")
    }

    func comando(_ riga: String) -> (URL, [String]) {
        // `-l` perche' serve il PATH del profilo: `llama-server` e `ollama`
        // arrivano da Homebrew, che non sta nel PATH di un'app aperta dal Dock.
        (URL(fileURLWithPath: "/bin/zsh"), ["-lc", riga])
    }

    func indirizzoLocale() -> String {
        // PRIMA quella della rotta di default, poi le altre. Un Mac attaccato
        // via cavo alla LAN dell'universita' e via WiFi a un'altra rete ha due
        // indirizzi, e la prima versione mostrava il primo che trovava in
        // ordine di interfaccia: era quello della WiFi, e il visore stava
        // sull'altra rete. La rotta di default e' la scelta migliore che si
        // possa fare senza sapere dove sta il visore.
        let interfacciaDefault = Guscio.esegui(
            piattaforma: self, radice: URL(fileURLWithPath: "/"),
            comando: "route -n get default 2>/dev/null | awk '/interface:/{print $2}'"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var perNome: [(String, String)] = []
        var puntatore: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&puntatore) == 0, let primo = puntatore else { return "127.0.0.1" }
        defer { freeifaddrs(puntatore) }
        var corrente = primo
        while true {
            let interfaccia = corrente.pointee
            if
                interfaccia.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                let nome = interfaccia.ifa_name
            {
                let nomeInterfaccia = String(cString: nome)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if nomeInterfaccia.hasPrefix("en"),
                   getnameinfo(interfaccia.ifa_addr, socklen_t(interfaccia.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let trovato = String(cString: host)
                    if !trovato.hasPrefix("127.") { perNome.append((nomeInterfaccia, trovato)) }
                }
            }
            guard let prossimo = interfaccia.ifa_next else { break }
            corrente = prossimo
        }
        if let principale = perNome.first(where: { $0.0 == interfacciaDefault }) {
            return principale.1
        }
        return perNome.first?.1 ?? "127.0.0.1"
    }

    func agente() -> Agente? {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.olivera.voice.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        let uid = getuid()
        return Agente(
            nome: "launchd (com.olivera.voice)",
            // `bootstrap` e non `load`: e' il verbo moderno, e a differenza di
            // `kickstart` non fa niente se l'agente e' gia' su. `bootout`
            // lo toglie davvero: con KeepAlive attivo, un semplice `kill`
            // lo vedrebbe risorgere tre secondi dopo.
            accendi: "launchctl bootstrap gui/\(uid) '\(plist.path)' 2>&1 || launchctl kickstart gui/\(uid)/com.olivera.voice 2>&1",
            spegni: "launchctl bootout gui/\(uid)/com.olivera.voice 2>&1"
        )
    }

    func memoriaLibera(radice: URL) -> Double {
        let stato = Guscio.esegui(piattaforma: self, radice: radice, comando: "vm_stat; sysctl -n hw.memsize")
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
                let grezzo = pezzi.count > 1
                    ? pezzi[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                    : ""
                pagine[chiave] = Double(grezzo) ?? 0
            } else if let soloNumero = Double(riga.trimmingCharacters(in: .whitespaces)) {
                totaleByte = soloNumero
            }
        }

        guard totaleByte > 0 else { return 0 }
        let riutilizzabile = (pagine["Pages free"] ?? 0)
            + (pagine["Pages inactive"] ?? 0)
            + (pagine["Pages speculative"] ?? 0)
            + (pagine["Pages purgeable"] ?? 0)
        return (riutilizzabile * dimensionePagina) / totaleByte * 100
    }

    func apri(file: URL) {
        NSWorkspace.shared.open(file)
    }

    func mostraNelFinder(file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func requisiti(radice: URL) -> [Requisito] {
        let fm = FileManager.default
        func nelPercorso(_ eseguibile: String) -> Bool {
            !Guscio.esegui(piattaforma: self, radice: radice, comando: "command -v \(eseguibile) || true")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func c(_ percorso: String) -> Bool {
            fm.fileExists(atPath: cartellaPesi.appendingPathComponent(percorso).path)
        }
        func r(_ percorso: String) -> Bool {
            fm.fileExists(atPath: radice.appendingPathComponent(percorso).path)
        }

        // O3: i quattro nomi traducibili passano da NSLocalizedString. I tre nomi
        // propri (llama.cpp, whisper.cpp, Ollama) e i sette `comeSiRimette`
        // restano letterali: sono comandi di shell mostrati in monospaced
        // (Finestra.swift, Mancanze), codice e non prosa, uguali in ogni lingua.
        return [
            .init(nome: NSLocalizedString("ambiente Python", comment: ""), presente: r(".venv/bin/python"),
                  comeSiRimette: "python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt"),
            .init(nome: "llama.cpp", presente: nelPercorso("llama-server"),
                  comeSiRimette: "brew install llama.cpp"),
            .init(nome: "whisper.cpp", presente: nelPercorso("whisper-server"),
                  comeSiRimette: "brew install whisper-cpp"),
            .init(nome: "Ollama", presente: nelPercorso("ollama"),
                  comeSiRimette: "brew install ollama"),
            .init(nome: NSLocalizedString("pesi dell'ascolto", comment: ""),
                  presente: fm.fileExists(atPath: fm.homeDirectoryForCurrentUser
                      .appendingPathComponent(".cache/whisper-cpp/ggml-large-v3-turbo-q8_0.bin").path),
                  comeSiRimette: "./.venv/bin/python -m olivera.tools.prepara"),
            .init(nome: NSLocalizedString("pesi della voce", comment: ""), presente: c("kokoro/kokoro-v1.0.onnx"),
                  comeSiRimette: "./.venv/bin/python -m olivera.tools.prepara"),
            .init(nome: NSLocalizedString("indice del corpus", comment: ""), presente: r("data/index/vectors.npy"),
                  comeSiRimette: "./.venv/bin/python -m olivera.rag.index"),
        ]
    }
}

// MARK: - eseguire un comando e leggerne l'uscita

enum Guscio {
    /// Sincrono, per i comandi corti: la sonda, i requisiti, la memoria.
    static func esegui(piattaforma: Piattaforma, radice: URL, comando: String) -> String {
        let (eseguibile, argomenti) = piattaforma.comando(comando)
        let p = Process()
        p.executableURL = eseguibile
        p.arguments = argomenti
        p.currentDirectoryURL = radice
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let dati = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: dati, encoding: .utf8) ?? ""
    }

    /// L'ambiente da dare a un figlio: il minimo, non quello di chi ha aperto
    /// l'app. Ereditare sembra prudente e non lo e': a seconda che l'app venga
    /// aperta dal Finder, dal Dock o da un terminale, il figlio si trova addosso
    /// variabili diverse e il servizio si comporta in modo diverso senza che si
    /// capisca perche'. Il resto lo mette la shell di login.
    static func ambientePulito(_ aggiunte: [String: String]) -> [String: String] {
        let vecchio = ProcessInfo.processInfo.environment
        var pulito: [String: String] = [:]
        for chiave in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TEMP", "LANG", "LC_ALL", "PATH", "USERPROFILE"] {
            if let valore = vecchio[chiave] { pulito[chiave] = valore }
        }
        pulito["PYTHONUNBUFFERED"] = "1"
        return pulito.merging(aggiunte) { _, nuovo in nuovo }
    }
}

/// Quella su cui stiamo girando.
func piattaformaCorrente() -> Piattaforma {
    #if os(macOS)
    return Mac()
    #else
    #error("Manca la conformita' a Piattaforma per questo sistema: vedi i commenti nel protocollo.")
    #endif
}
