// Su cosa si basa la guida: la scheda che legge `/documenti`.
//
// Eugenio, 16 settembre: "vedere dalla gui quali sono i documenti su cui si
// basa il sistema rag". Il servizio manda SOLO i documenti pubblici, sempre
// (D1, LOTTO-DOCUMENTI.md): questa scheda si limita a mostrare quello che
// riceve, senza nessuna logica di filtro propria - il filtro e' gia' stato
// fatto da chi ha piu' contesto per farlo bene, il server.

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
                        RigaDocumento(documento: documento)
                    }
                }
            }
        }
    }
}

private struct RigaDocumento: View {
    let documento: Documento

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(documento.nome)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Text("\(documento.tipo) · \(documento.pezzi)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
