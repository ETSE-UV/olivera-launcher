// Su cosa si basa la guida: la scheda che legge `/documenti`.
//
// Eugenio, 16 settembre: "vedere dalla gui quali sono i documenti su cui si
// basa il sistema rag". Il servizio manda SOLO i documenti pubblici, sempre
// (D1, LOTTO-DOCUMENTI.md): questa scheda si limita a mostrare quello che
// riceve, senza nessuna logica di filtro propria - il filtro e' gia' stato
// fatto da chi ha piu' contesto per farlo bene, il server.
//
// Lotto APRI, Eugenio: "si deve poter interagire con i file nella lista". Ogni
// riga diventa cliccabile: apre un dettaglio con le sezioni pubbliche e,
// SOLO se il server risponde da questo stesso Mac (D2, LOTTO-APRI.md, lo
// stesso confine che il server applica gia' su `percorso`), due pulsanti che
// passano dalla `Piattaforma` - questa vista non sa cosa sia NSWorkspace, ne'
// dovrebbe: e' cosa di sistema operativo, e sta in Piattaforma.swift.

import Foundation
import SwiftUI

/// Un documento del corpus, cosi' come lo manda `/documenti`. L'`id` e' il
/// `nome`: il server raggruppa per titolo di fonte, quindi e' unico per
/// costruzione, e non c'e' bisogno di chiedere un `id` al server (che
/// porterebbe fuori lo slug della sezione - vedi il commento sopra
/// `/documenti` in olivera/net/server.py).
struct Documento: Identifiable, Equatable {
    var id: String { nome }
    var nome: String
    var tipo: String
    var lingua: [String]
    var pezzi: Int

    init?(json: [String: Any]) {
        guard
            let nome = json["nome"] as? String,
            let tipo = json["tipo"] as? String,
            let pezzi = json["pezzi"] as? Int
        else { return nil }
        self.nome = nome
        self.tipo = tipo
        self.lingua = json["lingua"] as? [String] ?? []
        self.pezzi = pezzi
    }
}

/// Il dettaglio di un documento, cosi' come lo manda `GET /documenti/{nome}`
/// (lotto APRI). A differenza di `Documento`, che arriva intero con
/// `/documenti`, questo si chiede solo al primo click su una riga: aprire
/// tutti i dettagli in anticipo vorrebbe dire una richiesta per documento a
/// ogni accensione, per una scheda che nella maggioranza dei casi resta
/// chiusa (D3, LOTTO-DOCUMENTI.md).
struct DettaglioDocumento: Equatable {
    struct Sezione: Identifiable, Equatable {
        // Due sezioni con lo stesso titolo nello stesso documento non sono
        // previste (il server raggruppa per titolo, CRITICA-documenti.md): se
        // succedesse, l'`id` duplicato e' un problema del corpus, non di
        // questa vista.
        var id: String { titolo }
        var titolo: String
        var pezzi: Int
    }
    var sezioni: [Sezione]
    // nil quando il server non e' su questo Mac (D2): niente pulsanti, solo
    // la riga che lo dice.
    var percorso: String?

    init?(json: [String: Any]) {
        guard let sezioniJSON = json["sezioni"] as? [[String: Any]] else { return nil }
        self.sezioni = sezioniJSON.compactMap { voce in
            guard
                let titolo = voce["titolo"] as? String,
                let pezzi = voce["pezzi"] as? Int
            else { return nil }
            return Sezione(titolo: titolo, pezzi: pezzi)
        }
        self.percorso = json["percorso"] as? String
    }
}

extension Motore {
    /// Legge `/documenti` una volta, quando la guida diventa pronta (vedi il
    /// `didSet` su `salute`): a differenza di `/health`, l'indice non cambia
    /// mentre il server resta acceso, quindi chiederlo ogni due secondi come
    /// fa il vigile sarebbe solo spreco.
    func chiediDocumenti() async {
        guard let url = URL(string: "http://127.0.0.1:\(porta)/documenti") else { return }
        var richiesta = URLRequest(url: url)
        richiesta.timeoutInterval = 3
        guard let (dati, risposta) = try? await URLSession.shared.data(for: richiesta) else {
            documenti = .nonDisponibili(codice: 0)
            return
        }
        let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 0
        guard
            codice == 200,
            let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
            let elencoJSON = json["documenti"] as? [[String: Any]],
            let totaliJSON = json["totali"] as? [String: Any]
        else {
            // Il caso vero di questo ramo: un server su codice vecchio, che
            // risponde bene a /health (altrimenti non saremmo arrivati fin
            // qui) ma non conosce ancora /documenti (404).
            documenti = .nonDisponibili(codice: codice)
            return
        }

        let elenco = elencoJSON.compactMap { Documento(json: $0) }
        let totali = TotaliDocumenti(
            documenti: totaliJSON["documenti"] as? Int ?? 0,
            pezzi: totaliJSON["pezzi"] as? Int ?? 0,
            pubblici: totaliJSON["pubblici"] as? Int ?? 0,
            riservati: totaliJSON["riservati"] as? Int ?? 0
        )
        documenti = .caricati(elenco, totali)

        // D2: "N passaggi nell'indice" (Finestra.swift:172) mostra i pubblici
        // appena /documenti e' arrivato, il totale grezzo di /health fino ad
        // allora. Si scrive qui, su `salute.pezzi`, non in Finestra.swift:
        // quella vista legge gia' `s.pezzi` senza sapere da dove viene, e il
        // lotto non tocca quel file oltre alla riga di Documenti().
        if var s = salute { s.pezzi = totali.pubblici; salute = s }
    }

    /// Il dettaglio di un documento, al primo click sulla sua riga (lotto
    /// APRI). A differenza di `chiediDocumenti()` non si mette in cache qui:
    /// resta nello stato locale della riga (`RigaDocumento`, sotto), perche'
    /// non serve altrove nell'app - aprire e richiudere la stessa riga due
    /// volte nella stessa accensione richiede due volte, ed e' voluto: il
    /// costo e' un `GET` in piu' su un servizio locale, non un giro di rete.
    ///
    /// Torna anche il codice HTTP quando fallisce (critica di Opus, lotto
    /// APRI): un timeout o un 5xx non sono "codice vecchio" come un 404, e su
    /// questa macchina un timeout e' concreto (durante la critica la memoria
    /// libera e' scesa al 13-16% con 11 GB di swap) - vedi il commento su
    /// `.nonDisponibili` in `contenuto`, sotto, la stessa regola vale qui.
    func chiediDettaglioDocumento(nome: String) async -> EsitoDettaglioDocumento {
        guard
            let nomeCodificato = nome.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "http://127.0.0.1:\(porta)/documenti/\(nomeCodificato)")
        else { return .fallito(codice: 0) }
        var richiesta = URLRequest(url: url)
        richiesta.timeoutInterval = 3
        guard let (dati, risposta) = try? await URLSession.shared.data(for: richiesta) else {
            return .fallito(codice: 0)
        }
        let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 0
        guard
            codice == 200,
            let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
            let dettaglio = DettaglioDocumento(json: json)
        else { return .fallito(codice: codice) }
        return .ok(dettaglio)
    }
}

/// L'esito di `chiediDettaglioDocumento`: come `.nonDisponibili(codice:)` per
/// l'elenco (sopra), ma per una singola riga - stesso motivo, lo stesso
/// codice 0 per timeout/connessione rifiutata, il codice HTTP vero per il
/// resto.
enum EsitoDettaglioDocumento {
    case ok(DettaglioDocumento)
    case fallito(codice: Int)
}

/// La scheda "Su cosa si basa": chiusa di default, come Rete e Registro
/// (Finestra.swift). Lotto LINGUA: il titolo era una String, quindi Label(titolo,
/// ...) lo mostrava verbatim invece di cercarlo in Localizable.strings (lo
/// stesso difetto corretto in Finestra.swift su Scheda.titolo e Riga.chiave -
/// vedi la critica, M1 caso 6). LocalizedStringKey lo rimette nel meccanismo
/// automatico di SwiftUI, chiave = testo italiano (D1).
struct Documenti: View {
    @EnvironmentObject var motore: Motore
    @State private var aperto = false
    // Un solo documento aperto per volta e' sufficiente (LOTTO-APRI.md): non
    // c'e' bisogno di un insieme, il nome di quello aperto (o nil, nessuno).
    @State private var documentoAperto: String?
    private let titolo: LocalizedStringKey = "Su cosa si basa"

    var body: some View {
        DisclosureGroup(isExpanded: $aperto) {
            contenuto
                .padding(.top, 8)
        } label: {
            // Il tester di DOCUMENTI ha trovato il titolo del DisclosureGroup
            // illeggibile dall'albero di accessibilita'. La critica di LINGUA
            // ha misurato che ne' Label(titolo, ...) ne' un .accessibilityLabel
            // sopra arrivano a un AXTitle/AXDescription su AXDisclosureTriangle
            // (stessa prova di Finestra.swift, Preferenze/Rete/Registro): un
            // HStack con un Text dentro si', ed e' quello che risolve titolo
            // tramite LocalizedStringKey (D1) esattamente come Label faceva.
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                Text(titolo)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var contenuto: some View {
        switch motore.documenti {
        case .nonChiesti:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("leggo l'elenco...").font(.caption).foregroundStyle(.secondary)
            }
        case .nonDisponibili(let codice):
            // 404 e' la sola diagnosi certa: e' l'unico codice che dice
            // "il server c'e', gira, ma non conosce questa rotta" (codice
            // vecchio). Ogni altro caso (0 = timeout/connessione rifiutata
            // di chiediDocumenti(), 5xx) e' un fallimento diverso e non va
            // spacciato per "codice vecchio" - dire il codice vero, non
            // indovinare la causa.
            Text(
                codice == 404
                    ? "Non disponibile: il server sta girando su codice vecchio."
                    : "Non disponibile: il server non ha risposto (codice \(codice))."
            )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .caricati(let elenco, let totali):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(totali.documenti) documenti, \(totali.pubblici) passaggi")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(elenco) { documento in
                        RigaDocumento(
                            documento: documento,
                            aperto: documentoAperto == documento.nome,
                            alternaAperto: {
                                // withAnimation: senza, la .transition(.opacity)
                                // sotto (RigaDocumento) non anima niente - una
                                // transizione ha bisogno di un cambio di stato
                                // dentro un blocco di animazione per attivarsi.
                                withAnimation {
                                    documentoAperto = (documentoAperto == documento.nome) ? nil : documento.nome
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

/// Cosa sappiamo del dettaglio di UNA riga. Non e' `StatoDocumenti` (quello
/// e' per l'elenco intero, letto una volta sola): questo vive nello stato
/// locale della riga e si azzera quando la riga si richiude (`.onChange(of:
/// aperto)`, sotto), cosi' non resta un dettaglio in cache che non
/// corrisponde piu' a un indice che nel frattempo potrebbe essere cambiato
/// con un riavvio del server.
private enum StatoDettaglio: Equatable {
    case nonChiesto
    case caricamento
    case caricato(DettaglioDocumento)
    // Stesso codice di EsitoDettaglioDocumento.fallito: 0 per timeout o
    // connessione rifiutata, il codice HTTP vero per il resto (critica di
    // Opus, lotto APRI - vedi il commento su chiediDettaglioDocumento).
    case nonDisponibile(codice: Int)
}

private struct RigaDocumento: View {
    @EnvironmentObject var motore: Motore
    let documento: Documento
    let aperto: Bool
    let alternaAperto: () -> Void
    @State private var dettaglio: StatoDettaglio = .nonChiesto

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: alternaAperto) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(documento.nome)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Text("\(documento.tipo) · \(documento.pezzi)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(documento.nome)

            if aperto {
                dettaglioView
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
        }
        // Ogni apertura chiede il dettaglio, e la chiusura lo azzera (vedi
        // StatoDettaglio, sopra in questo file): un riavvio del server con un
        // indice nuovo, avvenuto mentre la riga era chiusa, si vede alla
        // riapertura invece di restare per sempre il dettaglio letto alla
        // prima apertura di questa accensione dell'app. Il costo e' un `GET`
        // in piu' su un servizio locale a ogni apri/richiudi, non un giro di
        // rete (vedi il commento su chiediDettaglioDocumento, sopra in
        // questo file, nell'extension di Motore).
        .onChange(of: aperto) { adessoAperto in
            guard adessoAperto else {
                dettaglio = .nonChiesto
                return
            }
            guard dettaglio == .nonChiesto else { return }
            dettaglio = .caricamento
            Task {
                switch await motore.chiediDettaglioDocumento(nome: documento.nome) {
                case .ok(let ricevuto):
                    dettaglio = .caricato(ricevuto)
                case .fallito(let codice):
                    dettaglio = .nonDisponibile(codice: codice)
                }
            }
        }
    }

    @ViewBuilder
    private var dettaglioView: some View {
        switch dettaglio {
        case .nonChiesto, .caricamento:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("leggo il dettaglio...").font(.caption2).foregroundStyle(.secondary)
            }
        case .nonDisponibile(let codice):
            // Stessa distinzione di `contenuto` sopra (righe 186-199): 404 e'
            // la sola diagnosi certa di "codice vecchio", ogni altro caso
            // (timeout, connessione rifiutata, 5xx) dice il codice vero
            // invece di indovinare la causa.
            Text(
                codice == 404
                    ? "Non disponibile: il server sta girando su codice vecchio."
                    : "Non disponibile: il server non ha risposto (codice \(codice))."
            )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .caricato(let ricevuto):
            VStack(alignment: .leading, spacing: 4) {
                if !ricevuto.sezioni.isEmpty {
                    Text("sezioni")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(ricevuto.sezioni) { sezione in
                        // "· " non e' testo da tradurre (e' un separatore fra
                        // dati: titolo e numero), quindi non serve una voce
                        // in tabella per l'intera riga - solo "passaggi", in
                        // coda, e' la parola che genera_strings.py registra.
                        (Text("\(sezione.titolo) · \(sezione.pezzi) ") + Text("passaggi"))
                            .font(.caption2)
                            .lineLimit(2)
                    }
                }
                if let percorso = ricevuto.percorso {
                    HStack(spacing: 10) {
                        Button("Apri") {
                            motore.piattaforma.apri(file: URL(fileURLWithPath: percorso))
                        }
                        Button("Mostra nel Finder") {
                            motore.piattaforma.mostraNelFinder(file: URL(fileURLWithPath: percorso))
                        }
                    }
                    .font(.caption2)
                } else {
                    // Niente pulsanti se `percorso` e' null: o il server
                    // risponde da un altro Mac (D2, il visore lo interroga
                    // sulla rete), o il file non esiste su questo Mac (D2-bis
                    // - la narrazione POI porta un source_path del PC Windows
                    // di Unity, mai esistito qui: server.py, `_calcola_dettagli`,
                    // campo `_esiste`). Le due cause sono indistinguibili dal
                    // client, e la frase non ne indovina una: dice solo il
                    // fatto vero in entrambe, "il file non e' su questo Mac"
                    // (correzione della critica di Opus sul lotto APRI: la
                    // frase precedente, "il file sta sul server", era falsa
                    // per la narrazione POI, che non sta su nessun server).
                    Text("il file non e' su questo Mac")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
