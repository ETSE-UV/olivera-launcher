// La finestra.
//
// Un'idea per riga verticale, e la piu' importante in alto: acceso o spento, e
// che indirizzo scrivere. Tutto quello che serve solo quando qualcosa non va -
// requisiti, rete, registro - sta sotto e chiuso.

import SwiftUI

struct Finestra: View {
    @EnvironmentObject var motore: Motore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Testata()
                if motore.memoriaStretta { Memoria() }
                if !motore.tuttoPronto { Mancanze() }
                Interruttore()
                if motore.fase == .pronta { Indirizzo(); Prova() }
                Preferenze()
                Rete()
                Registro()
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - testata

private struct Testata: View {
    @EnvironmentObject var motore: Motore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Olivera").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle()
                        .fill(motore.fase.colore)
                        .frame(width: 8, height: 8)
                    Text(motore.fase.descrizione)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - la memoria

/// Il guasto che non sembra un guasto.
///
/// Con la memoria finita la catena parte, i tre processi si vedono in Monitoraggio
/// Attivita', e poi il servizio non risponde piu': non e' bloccato, e' stato
/// paginato via e il sistema non lo rimette dentro. Senza questa scheda si passa
/// il pomeriggio a cercare un errore nel codice.
private struct Memoria: View {
    @EnvironmentObject var motore: Motore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: motore.memoriaCritica ? "exclamationmark.triangle.fill" : "memorychip")
                .foregroundStyle(motore.memoriaCritica ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(motore.memoriaCritica
                     ? "Il Mac sta finendo la memoria (libera il \(Int(motore.liberaPercento))%)"
                     : "Memoria stretta: libera il \(Int(motore.liberaPercento))%")
                    .font(.callout.weight(.medium))
                Text(motore.memoriaCritica
                     ? "Cosi' la guida parte e poi si ferma a meta', e sembra rotta. Chiudi Chrome, metti in pausa Google Drive e chiudi le sessioni che non ti servono, poi riprova."
                     : "I tempi che misuri adesso non sono quelli veri: la macchina sta scambiando memoria col disco.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background((motore.memoriaCritica ? Color.red : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - cosa manca

private struct Mancanze: View {
    @EnvironmentObject var motore: Motore

    var body: some View {
        Scheda(titolo: "Prima di accendere manca qualcosa", icona: "wrench.and.screwdriver") {
            ForEach(motore.requisiti.filter { !$0.presente }) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.nome).font(.callout)
                        Text(r.comeSiRimette)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button("Prepara la macchina") { motore.preparaLaMacchina() }
                Button("Ricontrolla") { motore.controllaRequisiti() }
                    .buttonStyle(.borderless)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - l'interruttore

private struct Interruttore: View {
    @EnvironmentObject var motore: Motore

    private var accesa: Bool {
        if case .spenta = motore.fase { return false }
        if case .caduta = motore.fase { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                accesa ? motore.spegni() : motore.accendi()
            } label: {
                HStack {
                    Image(systemName: accesa ? "stop.fill" : "play.fill")
                    Text(accesa ? "Spegni la guida" : "Accendi la guida")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accesa ? .red : .accentColor)
            .disabled(!motore.tuttoPronto && !accesa)

            if case .avvio = motore.fase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("il primo avvio prende un minuto: carica i modelli e li scalda, "
                         + "cosi' il primo visitatore non paga l'attesa")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .caduta(let perche) = motore.fase {
                Text(perche).font(.caption).foregroundStyle(.red)
            }
            if let s = motore.salute {
                HStack(spacing: 8) {
                    Gettone(icona: "ear", testo: s.asr.components(separatedBy: " (").first ?? s.asr)
                    Gettone(icona: "brain", testo: s.llm)
                    Gettone(icona: "waveform", testo: s.tts.replacingOccurrences(of: "TTS", with: ""))
                }
                Text("\(s.pezzi) passaggi nell'indice")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Gettone: View {
    let icona: String
    let testo: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icona).font(.caption2)
            Text(testo).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

// MARK: - l'indirizzo

private struct Indirizzo: View {
    @EnvironmentObject var motore: Motore
    @State private var copiato = false

    private var ws: String { "ws://\(motore.indirizzo):\(motore.porta)/ws" }

    var body: some View {
        Scheda(titolo: "Su Unity puoi premere Play", icona: "visionpro") {
            Text(motore.rispondiAlDiscovery
                 ? "Con il campo host vuoto il visore trova il Mac da solo. Se preferisci essere sicuro, scrivi questo indirizzo in OliveraGuide:"
                 : "Il discovery e' spento su questo Mac: l'indirizzo va scritto a mano nel campo host di OliveraGuide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(motore.indirizzo)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    let p = NSPasteboard.general
                    p.clearContents()
                    p.setString(motore.indirizzo, forType: .string)
                    copiato = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiato = false }
                } label: {
                    Label(copiato ? "copiato" : "copia", systemImage: copiato ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 3) {
                Riga(chiave: "WebSocket", valore: ws)
                Riga(chiave: "Prova nel browser", valore: "http://\(motore.indirizzo):\(motore.porta)")
            }
            .padding(.top, 2)

            Text("La prima volta macOS chiede se lasciar passare le connessioni in entrata: bisogna dire di si', se no il visore non arriva.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Riga: View {
    let chiave: String
    let valore: String
    var body: some View {
        HStack(spacing: 6) {
            Text(chiave).font(.caption).foregroundStyle(.secondary)
            Text(valore).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}

// MARK: - la prova

private struct Prova: View {
    @EnvironmentObject var motore: Motore

    var body: some View {
        Scheda(titolo: "Prova senza visore", icona: "checkmark.seal") {
            Text("Manda un ordine e una domanda. L'ordine deve tornare come azione: se torna a parole, il server sta girando su codice vecchio.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { motore.prova() } label: {
                    if motore.provaInCorso {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("provo...") }
                    } else {
                        Label("Prova adesso", systemImage: "play.circle")
                    }
                }
                .disabled(motore.provaInCorso)
                Spacer()
            }
            if let esito = motore.esitoProva {
                Text(esito)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(esito.contains("NON ESEGUITO") || esito.contains("non risponde") ? .red : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - preferenze

private struct Preferenze: View {
    @EnvironmentObject var motore: Motore
    @State private var aperto = false

    private var accesa: Bool { motore.fase != .spenta }

    var body: some View {
        DisclosureGroup(isExpanded: $aperto) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Voce", selection: $motore.voce) {
                        ForEach(Voce.allCases) { v in Text(v.etichetta).tag(v) }
                    }
                    .pickerStyle(.segmented)
                    Text(motore.voce.nota).font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Modello", selection: $motore.taglia) {
                        ForEach(Taglia.allCases) { t in Text(t.etichetta).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    Text(motore.taglia.nota).font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Fatti trovare dal visore in automatico", isOn: $motore.rispondiAlDiscovery)
                    Text("Spegnilo quando anche il PC ha il suo server acceso: se rispondono in due, Unity ne prende uno a caso.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if accesa {
                    Text("I cambiamenti valgono al prossimo avvio.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Come deve parlare", systemImage: "slider.horizontal.3").font(.callout)
        }
    }
}

// MARK: - la rete

private struct Rete: View {
    @EnvironmentObject var motore: Motore
    @State private var aperto = false

    var body: some View {
        DisclosureGroup(isExpanded: $aperto) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Manda lo stesso richiamo che manda il visore e ascolta chi risponde. Se rispondono in due, la scelta di Unity non e' prevedibile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { motore.sondaLaRete() } label: {
                    if motore.sondaInCorso {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("ascolto...") }
                    } else {
                        Label("Chi risponde sulla rete", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(motore.sondaInCorso)

                ForEach(motore.serverSullaRete) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: s.questoMac ? "desktopcomputer" : "pc")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.ip):\(s.porta)\(s.questoMac ? "  (questo Mac)" : "")")
                                .font(.system(.caption, design: .monospaced))
                            Text(s.descrizione).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if motore.serverSullaRete.count > 1 {
                    Label("Rispondono in \(motore.serverSullaRete.count): spegni il discovery su quello che non deve prendersi il visore.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Chi c'e' sulla rete", systemImage: "network").font(.callout)
        }
    }
}

// MARK: - registro

private struct Registro: View {
    @EnvironmentObject var motore: Motore
    @State private var aperto = false

    var body: some View {
        DisclosureGroup(isExpanded: $aperto) {
            ScrollViewReader { lettore in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(motore.righe.enumerated()), id: \.offset) { indice, riga in
                            Text(riga)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(riga.contains("ERROR") ? .red
                                                 : riga.contains("WARNING") ? .orange : .secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(indice)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 180)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: motore.righe.count) { _ in
                    if let ultima = motore.righe.indices.last {
                        withAnimation { lettore.scrollTo(ultima, anchor: .bottom) }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Registro", systemImage: "text.alignleft").font(.callout)
        }
    }
}

// MARK: - contenitore

struct Scheda<Contenuto: View>: View {
    let titolo: String
    let icona: String
    @ViewBuilder var contenuto: Contenuto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(titolo, systemImage: icona)
                .font(.callout.weight(.medium))
            contenuto
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
