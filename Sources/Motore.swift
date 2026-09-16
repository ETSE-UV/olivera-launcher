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
        // O3: le due fisse passano da NSLocalizedString (String, non
        // LocalizedStringKey: Text(motore.fase.descrizione) in Finestra.swift
        // la vede come letterale verbatim se non e' gia' risolta qui). `cosa` e
        // `perche` arrivano gia' risolte da chi le costruisce (Python via
        // OLIVERA_LANG+t(), o Swift via NSLocalizedString piu' sotto in questo
        // file): non vanno wrappate una seconda volta.
        case .spenta: return NSLocalizedString("spenta", comment: "fase: il server non gira")
        case .avvio(let cosa): return cosa
        case .pronta: return NSLocalizedString("pronta", comment: "fase: il server risponde ed e' pronto")
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
        case .kokoro: return NSLocalizedString("Kokoro", comment: "nome proprio, non si traduce")
        case .sistema: return NSLocalizedString("Di sistema", comment: "")
        case .clonata: return NSLocalizedString("Clonata", comment: "")
        }
    }

    var nota: String {
        switch self {
        case .kokoro: return NSLocalizedString("neurale, 0,18 di fattore di tempo reale", comment: "")
        case .sistema: return NSLocalizedString("0,3 s piu' rapida, ma si sente che e' una macchina", comment: "")
        case .clonata: return NSLocalizedString("fuori dal tempo reale su questo Mac: solo per ascoltarla", comment: "")
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
    var etichetta: String {
        self == .q4
            ? NSLocalizedString("4 bit", comment: "")
            : NSLocalizedString("8 bit", comment: "")
    }
    var nota: String {
        self == .q4
            ? NSLocalizedString("prima frase in 0,9 s, 3,9 GB", comment: "")
            : NSLocalizedString("risposte un filo migliori, +0,6 s e +1,2 GB", comment: "")
    }
}

struct Salute: Equatable {
    var asr = ""
    var llm = ""
    var tts = ""
    var vlm = ""
    var pezzi = 0
}

/// Su cosa si basa la guida, dai passaggi PUBBLICI di `/documenti` (mai i
/// riservati: la scheda non li elenca, solo il loro numero. Vedi
/// Documenti.swift e olivera/net/server.py).
struct TotaliDocumenti: Equatable {
    var documenti = 0
    var pezzi = 0
    var pubblici = 0
    var riservati = 0
}

/// Cosa sappiamo di `/documenti`. Tre stati e non un opzionale perche' la
/// vista (Documenti.swift) deve distinguere "non ancora chiesto" (mostra la
/// rotella) da "chiesto e rifiutato": un server su codice vecchio risponde
/// bene a `/health` ma torna 404 su `/documenti`, e va detto, non lasciato a
/// girare come se stesse ancora caricando. La richiesta parte comunque una
/// volta sola per accensione dal `didSet` su `salute` qui sotto, che guarda
/// `oldValue == nil` e non legge mai questo enum.
enum StatoDocumenti: Equatable {
    case nonChiesti
    case caricati([Documento], TotaliDocumenti)
    case nonDisponibili(codice: Int)
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
    // `salute` e' l'UNICO imbuto per cui passano tutti e tre i percorsi verso
    // .pronta (adotta -> chiediSalute; accendi con agente -> avviaVigile ->
    // chiediSalute; accendi senza agente -> avviaVigile -> chiediSalute):
    // e' l'unico posto che lo scrive, mai `fase` da sola (che puo' diventare
    // .pronta leggendo lo stdout, in assorbi(), PRIMA che /health risponda
    // davvero - server.py stampa la riga di stato prima di uvicorn.run).
    // Agganciare /documenti qui, non a `fase`, copre i tre percorsi in un
    // colpo solo e non lo richiede ogni due secondi come /health (CRITICA-
    // documenti.md, obbligatoria 3).
    @Published var salute: Salute? {
        didSet {
            if salute == nil {
                documenti = .nonChiesti
            } else if oldValue == nil {
                Task { await chiediDocumenti() }
            }
        }
    }
    @Published var documenti: StatoDocumenti = .nonChiesti
    @Published var righe: [String] = []
    @Published var indirizzo: String = "127.0.0.1"
    @Published var serverSullaRete: [ServerVisto] = []
    @Published var sondaInCorso = false
    // O3: era String sola, e Finestra.swift colorava di rosso guardando due
    // frasi italiane dentro il testo (`esito.contains("NON ESEGUITO")`) - con
    // il testo tradotto quel confronto non avrebbe piu' trovato niente. Ora chi
    // legge il JSON (leggiProva) decide il guasto, e Finestra.swift legge solo
    // il campo `guasto`, mai il testo.
    @Published var esitoProva: (testo: String, guasto: Bool)?
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

    /// Chi tiene acceso il server: noi, l'agente di sistema, o nessuno.
    ///
    /// LA PRIMA VERSIONE NON SE LO CHIEDEVA. Da settembre 2026 il Mac tiene il
    /// server acceso da solo con un agente launchd che parte al login, e l'app
    /// - come Banchina, e come chiunque lanci lo script - trovava la porta presa
    /// e diceva "non e' partita". Non era vero: era partita un'ora prima, e il
    /// visore si era gia' collegato. Un'app che accende un server deve prima
    /// guardare se e' gia' acceso, e se lo e', dire di chi e'.
    enum Custode: Equatable {
        case nessuno
        case questaApp
        case agente(String)   // il nome del servizio di sistema
        case sconosciuto      // risponde, ma non l'abbiamo acceso noi e non c'e' un agente
    }
    @Published var custode: Custode = .nessuno

    init(radice: URL, piattaforma: Piattaforma = piattaformaCorrente()) {
        self.radice = radice
        self.piattaforma = piattaforma
        self.indirizzo = piattaforma.indirizzoLocale()
        controllaRequisiti()
        misuraLaMemoria()
        Task { await adotta() }
    }

    // MARK: - accendere e spegnere

    /// Se un server risponde gia' su questa porta, e' il nostro: si adotta.
    private func adotta() async {
        await chiediSalute()
        guard salute != nil else { return }
        custode = piattaforma.agente().map { .agente($0.nome) } ?? .sconosciuto
        fase = .pronta
        avanzamento = 1
        avviaVigile()
    }

    func accendi() {
        guard processo == nil else { return }
        righe = []
        resto = ""
        avanzamento = 0
        fase = .avvio(NSLocalizedString("avvio...", comment: ""))
        esitoProva = nil

        // C'e' un agente di sistema? Allora si accende QUELLO, e si aspetta che
        // risponda. Lanciare un secondo server sotto un agente con KeepAlive e'
        // una gara persa in partenza: uno dei due trova la porta presa.
        if let agente = piattaforma.agente() {
            custode = .agente(agente.nome)
            let formato = NSLocalizedString("chiedo a %@ di accenderla...", comment: "%@ e' il nome dell'agente, non si traduce")
            fase = .avvio(String(format: formato, agente.nome))
            let comando = agente.accendi
            Task.detached { [radice, piattaforma] in
                let esito = Guscio.esegui(piattaforma: piattaforma, radice: radice, comando: comando)
                await MainActor.run {
                    // "[agente]" e' un marcatore tecnico di log, come "[olivera]"
                    // lato Python (stato.py): resta uguale nelle tre lingue, non e'
                    // prosa. E' comunque in NSLocalizedString per uniformita' con le
                    // altre voci e perche' lo legge anche il test di parita' es/en.
                    let prefisso = NSLocalizedString("[agente]", comment: "prefisso tecnico di log, non tradurre")
                    self.righe.append("\(prefisso) \(esito.trimmingCharacters(in: .whitespacesAndNewlines))")
                    self.avviaVigile()
                }
            }
            return
        }

        custode = .questaApp
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
            // O5: la lingua la sceglie l'app (dalla propria localizzazione
            // preferita, non da OLIVERA_LANG che nessuno ha ancora impostato) e la
            // manda SEMPRE al lanciatore: e' l'unica riga che fa vincere questa
            // scelta su LANG/LC_ALL, che Guscio.ambientePulito copia dall'ambiente
            // di chi ha aperto l'app (Piattaforma.swift, ambientePulito: le
            // `aggiunte` vincono sempre nel merge).
            "OLIVERA_LANG": String((Bundle.main.preferredLocalizations.first ?? "it").prefix(2)),
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
                //
                // D5/O4: "manca" e' uscito da questo elenco. Prima era l'unico modo
                // di beccare "manca 'llama-server'" eccetera, e dipendeva dalla
                // parola italiana dentro un messaggio che con le altre lingue non
                // c'e' piu'. Adesso i tre `raise SystemExit` di launch.py mandano
                // prima uno stato("errore", t(...)) strutturato (vedi olivera/
                // launch.py), che arriva qui come .caduta ATTRAVERSO assorbi() e
                // Stato.leggi(), PRIMA che il processo termini: il ramo sopra
                // (`if case .caduta = self.fase { return }`) lo intercetta e non si
                // arriva mai fin qui per quei casi. Quello che resta e' un
                // indovinello di riserva per crash che non si sono annunciati.
                if stavaPartendo {
                    let ultima = self.righe.last(where: {
                        $0.contains("rror") || $0.contains("Error")
                    }) ?? self.righe.last ?? NSLocalizedString("nessun dettaglio", comment: "")
                    let formato = NSLocalizedString("non e' partita: %@", comment: "")
                    self.fase = .caduta(String(format: formato, ultima))
                } else {
                    if finito.terminationStatus == 0 {
                        self.fase = .spenta
                    } else {
                        let formato = NSLocalizedString("si e' fermata (codice %lld)", comment: "")
                        // terminationStatus e' Int32, %lld legge 64 bit: senza
                        // il cast un codice negativo (es. -15, SIGTERM) stampa
                        // 4294967281 invece di leggersi come atteso. I codici
                        // d'uscita normali sono 0-255 quindi oggi non si vede,
                        // ma il cast costa niente (critica, consigliata).
                        self.fase = .caduta(String(format: formato, Int(finito.terminationStatus)))
                    }
                }
            }
        }

        do {
            try p.run()
            processo = p
            avviaVigile()
        } catch {
            let formato = NSLocalizedString("non parte: %@", comment: "error.localizedDescription arriva gia' nella lingua di sistema di macOS, non in quella scelta dall'app")
            fase = .caduta(String(format: formato, error.localizedDescription))
        }
    }

    func spegni() {
        fase = .spenta
        avanzamento = 0
        vigile?.invalidate()
        vigile = nil
        salute = nil

        switch custode {
        case .agente:
            // Si spegne l'agente, non il processo: con KeepAlive, un processo
            // ucciso risorge tre secondi dopo e l'app sembra non fare niente.
            if let agente = piattaforma.agente() {
                let comando = agente.spegni
                Task.detached { [radice, piattaforma] in
                    let esito = Guscio.esegui(piattaforma: piattaforma, radice: radice, comando: comando)
                    await MainActor.run {
                        let prefisso = NSLocalizedString("[agente]", comment: "prefisso tecnico di log, non tradurre")
                        self.righe.append("\(prefisso) \(esito.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            }
        case .sconosciuto:
            // Non l'abbiamo acceso noi e non c'e' un agente: non e' nostro da
            // spegnere. Si dice, invece di uccidere un processo di cui non si
            // sa niente.
            fase = .caduta(NSLocalizedString("il server e' acceso da qualcos'altro: spegnilo da dove l'hai avviato", comment: ""))
            return
        case .questaApp, .nessuno:
            // Basta chiudere questo: il lanciatore chiude i suoi figli da solo,
            // su ogni sistema, e non lascia orfani.
            processo?.terminate()
            processo = nil
        }
        custode = .nessuno
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
        else {
            // Era pronta e ha smesso di rispondere: se la teneva l'agente, e'
            // caduta o e' stata spenta da fuori. Lo si dice, invece di lasciare
            // un pallino verde su un server che non c'e' piu'.
            if case .pronta = fase, case .agente = custode {
                salute = nil
                fase = .caduta(NSLocalizedString("non risponde piu': l'agente potrebbe averla riavviata, riprovo...", comment: ""))
            }
            return
        }

        var s = Salute()
        s.asr = json["asr"] as? String ?? ""
        s.llm = json["llm"] as? String ?? ""
        s.tts = json["tts"] as? String ?? ""
        s.vlm = json["vlm"] as? String ?? ""
        s.pezzi = json["chunks"] as? Int ?? 0
        // D2: appena /documenti e' arrivato, "N passaggi nell'indice" mostra i
        // PUBBLICI (totali.pubblici), non il totale grezzo di /health. Va
        // riapplicato ad OGNI risposta di /health, non solo alla prima: il
        // vigile chiama chiediSalute() ogni due secondi e senza questo la
        // correzione fatta una tantum in chiediDocumenti() durerebbe al
        // massimo due secondi prima che questa riga la sovrascrivesse con il
        // 533 grezzo (misurato: e' successo davvero, leggendo l'app con
        // l'albero di accessibilita' dopo l'apertura della scheda).
        if case .caricati(_, let totali) = documenti { s.pezzi = totali.pubblici }
        salute = s
        // Quando la accende l'agente non leggiamo il suo stdout: /health e'
        // l'unico modo di sapere che e' arrivata in fondo.
        switch fase {
        case .avvio, .caduta:
            fase = .pronta
            avanzamento = 1
        default:
            break
        }
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
                    } ?? NSLocalizedString("non risponde alla salute", comment: "")
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
            let esito = Motore.leggiProva(uscita)
            await MainActor.run {
                self.esitoProva = esito
                self.provaInCorso = false
            }
        }
    }

    /// O3: torna anche `guasto`, non solo il testo (vedi il commento su
    /// `esitoProva` piu' sopra) - Finestra.swift colora di rosso su quello, mai
    /// confrontando il testo con una frase italiana.
    nonisolated private static func leggiProva(_ uscita: String) -> (testo: String, guasto: Bool) {
        guard
            let dati = uscita.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any]
        else { return (NSLocalizedString("la prova non ha risposto", comment: ""), true) }
        if let errore = json["errore"] as? String {
            let formato = NSLocalizedString("non risponde: %@", comment: "")
            return (String(format: formato, errore), true)
        }

        let ordine = json["ordine"] as? [String: Any] ?? [:]
        let domanda = json["domanda"] as? [String: Any] ?? [:]
        let msOrdine = ordine["primoTestoMs"] as? Int ?? 0
        let audio = domanda["primoAudioMs"] as? Int ?? 0

        var righe: [String] = []
        var guasto = false
        if let azione = ordine["azione"] as? [String: Any] {
            let tipo = azione["kind"] as? String ?? "?"
            let bersaglio = azione["target"].map { "\($0)" } ?? ""
            let formato = NSLocalizedString("ordine eseguito (%@ %@) in %lld ms", comment: "")
            righe.append(String(format: formato, tipo, bersaglio, msOrdine))
        } else {
            righe.append(NSLocalizedString("ORDINE NON ESEGUITO: ha risposto a parole. Il server gira su codice vecchio.", comment: ""))
            guasto = true
        }
        let formatoDomanda = NSLocalizedString("domanda: primo suono in %@ s", comment: "")
        righe.append(String(format: formatoDomanda, String(format: "%.1f", Double(audio) / 1000)))
        return (righe.joined(separator: "\n"), guasto)
    }

    // MARK: - cosa manca prima di poter accendere

    func controllaRequisiti() { requisiti = piattaforma.requisiti(radice: radice) }

    var tuttoPronto: Bool { requisiti.allSatisfy(\.presente) }

    func preparaLaMacchina() {
        fase = .avvio(NSLocalizedString("preparo (scarica qualche centinaio di MB)...", comment: ""))
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
