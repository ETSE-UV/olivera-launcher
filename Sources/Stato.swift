// L'altra meta' di `olivera/stato.py`.
//
// Il servizio stampa una riga come questa:
//
//     @@olivera {"fase": "pronta", "testo": "in ascolto su 0.0.0.0:8765"}
//
// e qui la si rilegge. E' l'unico punto in cui l'app e il servizio si accordano
// su qualcosa, ed e' fatto apposta perche' sia poco: un prefisso che non puo'
// comparire per caso nei log di llama.cpp o di uvicorn, e un oggetto JSON che
// si puo' allargare senza rompere chi lo legge.
//
// Prima l'app cercava frasi dentro il testo dei log. Funzionava finche' nessuno
// riformulava un messaggio.

import Foundation

enum Stato {
    static let prefisso = "@@olivera "

    struct Riga {
        var fase: String
        var testo: String
        /// Tutto il resto del JSON, per chi vuole guardarci dentro senza che
        /// questo tipo debba conoscere in anticipo ogni campo.
        var extra: [String: Any]
    }

    static func leggi(_ riga: String) -> Riga? {
        guard riga.hasPrefix(prefisso) else { return nil }
        let json = String(riga.dropFirst(prefisso.count))
        guard
            let dati = json.data(using: .utf8),
            let oggetto = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
            let fase = oggetto["fase"] as? String
        else { return nil }
        return Riga(
            fase: fase,
            testo: oggetto["testo"] as? String ?? fase,
            extra: oggetto.filter { $0.key != "fase" && $0.key != "testo" }
        )
    }
}
