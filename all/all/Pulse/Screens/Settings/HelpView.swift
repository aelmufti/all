//
//  HelpView.swift
//  all (bridge-connect)
//
//  Sous-page « Aide » des Paramètres — regroupe les explications d'utilisation
//  qui alourdissaient autrefois les écrans de contenu (Accueil, Sommeil,
//  Alimentation…). Parti pris produit : l'UI des écrans parle d'elle-même ;
//  qui veut le détail (« comment c'est calculé », « comment lire ce repère »)
//  vient ici. Présentée en feuille depuis `SettingsView` (motif « Statut du
//  pont » / « Collecteur »).
//
//  Page de lecture : `ScrollView` de `PulseCard` (vocabulaire des écrans de
//  contenu), pas un `Form` de réglages — rien n'est réglable ici.
//

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                    Text("Les écrans restent épurés ; le détail de ce qu'ils affichent et de la façon dont c'est calculé vit ici.")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                        .padding(.horizontal, PulseSpacing.xs)

                    ForEach(HelpContent.sections) { section in
                        HelpSectionCard(section: section)
                    }
                }
                .padding(PulseSpacing.lg)
            }
            .background(Color.pulseBackground)
            .navigationTitle("Aide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton { dismiss() } }
        }
    }
}

// MARK: - Rendu d'une section (titre + liste de sujets)

private struct HelpSectionCard: View {
    let section: HelpSection

    var body: some View {
        PulseCard {
            Text(section.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)

            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                ForEach(section.topics) { topic in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.pulseTextPrimary)
                        Text(topic.body)
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, PulseSpacing.xs)
        }
    }
}

// MARK: - Modèle de contenu

private struct HelpTopic: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let topics: [HelpTopic]
}

/// Texte d'aide — source unique, en français, voix de l'app. Reprend les
/// explications retirées des écrans de contenu (cf. git) : on les déplace ici
/// plutôt que de les perdre.
private enum HelpContent {
    static let sections: [HelpSection] = [
        HelpSection(title: "Accueil", topics: [
            HelpTopic(
                title: "Graphe d'intensité",
                body: "Le trait plein monte avec les minutes déjà faites dans la semaine ; le pointillé oblique donne le rythme régulier à tenir pour atteindre l'objectif. Quand plusieurs objectifs coexistent, chaque trait monte vers le sien."),
            HelpTopic(
                title: "Objectif d'intensité",
                body: "L'objectif s'ajuste seul sur tes six dernières semaines : en hausse si elles montent, en baisse si elles baissent, allégé après trois semaines tenues de justesse, stable sinon. Faute de mesures récentes il reste inchangé, et tu peux toujours le fixer à la main."),
        ]),
        HelpSection(title: "Sommeil", topics: [
            HelpTopic(
                title: "Heure de coucher conseillée",
                body: "La carte « Ce soir » vise ton prochain réveil prévu : celui d'aujourd'hui s'il n'est pas encore passé (il est 1 h du matin), sinon celui de demain. Les nuits passées ont chacune la leur. Dans tous les cas, on part du réveil prévu du jour concerné et on remonte de ta durée idéale de sommeil, du temps d'éveil habituel dans la nuit et du délai d'endormissement. Le réveil prévu est celui que tu as réglé pour ce jour de la semaine ; à défaut, ton lever habituel en semaine ou le week-end (au moins trois nuits de ce type), puis ton lever habituel général. Ce n'est jamais l'heure à laquelle tu t'es réellement réveillé. La durée idéale de la nuit tient compte de son contexte — énergie au coucher, stress de la veille, sport récent, sommeil des nuits précédentes — mais ne s'écarte jamais de plus d'une heure de ta durée idéale générale ; faute d'assez de nuits (moins de trente) ou de contexte, c'est cette dernière qui est utilisée. Pour une nuit à venir, le contexte est estimé à ton heure de coucher habituelle (ou à maintenant si elle est passée)."),
            HelpTopic(
                title: "Durée idéale de sommeil",
                body: "Pas la durée que tu dors d'habitude — celle qui, chez toi, précède les meilleurs lendemains. On mesure ta Body Battery au réveil et le soir, et ton niveau de stress le lendemain, pour chaque durée de nuit observée. Tes nuits courtes ne sont pas prises pour une préférence : on regarde leur effet, pas leur fréquence ; là où tu n'as pas assez de nuits (typiquement les nuits longues), l'estimation reste sur une fourchette de littérature (7 à 9 h) plutôt que d'inventer une tendance. La durée idéale propre à chaque nuit (cartes de l'écran Sommeil) la déplace légèrement selon le contexte du jour, sans jamais la sortir de 7 à 9,5 h. Une « nuit d'essai » t'est proposée certains soirs, quand l'incertitude est forte, pour mesurer ce qu'on ne connaît pas encore. La durée conseillée ne descend jamais sous 7 h, recommandation générale pour un adulte. Comme pour le reste de l'écran : une corrélation observée, pas une expérience contrôlée — un résultat à prendre comme une piste, pas une vérité absolue."),
            HelpTopic(
                title: "Composition des phases",
                body: "Les barres donnent la part de sommeil profond, léger et paradoxal, en pourcentage du sommeil réel (hors éveil). Le trait vertical marque la fourchette de référence — indicative, et variable avec l'âge."),
            HelpTopic(
                title: "Dette de sommeil",
                body: "Somme des écarts négatifs à ton objectif sur la période. La durée retenue est le sommeil réel (profond + léger + paradoxal) ; le temps au lit passé éveillé ne compte pas. Les nuits sans données de montre sont exclues, pas comptées à zéro."),
            HelpTopic(
                title: "Stress & nuit",
                body: "La corrélation affichée n'est pas une preuve de cause : une journée stressante peut aussi abîmer la nuit qui suit, pas seulement l'inverse."),
            HelpTopic(
                title: "Éveils & oxygénation",
                body: "À ne pas lire comme un dépistage d'apnée. Tes éveils sont surtout de longs réveils, pas les micro-éveils de quelques secondes qui suivent une apnée ; l'écart avec les désaturations vient le plus souvent d'un artefact de mouvement du capteur au réveil."),
        ]),
        HelpSection(title: "Alimentation", topics: [
            HelpTopic(
                title: "Journée vide ≠ zéro",
                body: "Une journée sans aucune saisie reste vide : elle ne compte pas comme un zéro et n'entre pas dans les moyennes."),
            HelpTopic(
                title: "Barres pâles",
                body: "Les barres pâles sont des journées partiellement saisies ; elles ne comptent pas dans la moyenne."),
            HelpTopic(
                title: "Fourchettes de macros",
                body: "Sur une jauge, la zone translucide est la fourchette visée (cadre de programme ou cibles manuelles) et le repère fin marque la cible."),
        ]),
        HelpSection(title: "Réveil & coucher", topics: [
            HelpTopic(
                title: "Réveil dans l'app",
                body: "Le réveil se règle ici, dans l'app — ce n'est pas une alarme de l'app Horloge iOS (illisible depuis une app tierce). C'est un rappel sonore : faute d'alertes critiques, il ne sonne ni en silencieux ni en boucle."),
            HelpTopic(
                title: "Lien avec le coucher",
                body: "Pour chaque jour où un réveil est réglé, l'heure de coucher conseillée se calcule sur cette heure plutôt que sur ton lever habituel."),
            HelpTopic(
                title: "Envoyer à la montre",
                body: "« Envoyer à la montre » règle en plus une alarme native sur la Venu 2 à partir du même planning, quand le lien BLE est actif."),
        ]),
        HelpSection(title: "Données & synchro", topics: [
            HelpTopic(
                title: "Où vivent les données",
                body: "Téléphone : tout reste sur l'iPhone, rien n'est envoyé à Pulse. Pulse : chaque synchro part vers le serveur. Les deux : gardé sur l'iPhone ET envoyé à Pulse, avec repli automatique sur le téléphone si Pulse est injoignable."),
            HelpTopic(
                title: "Valeurs au tiret",
                body: "Un tiret « — » signale une absence de donnée sur la période : les valeurs ne descendent pas à zéro pour autant. Élargis la période ou synchronise la montre."),
        ]),
    ]
}

#Preview {
    HelpView()
}
