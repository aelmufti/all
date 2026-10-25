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
                .font(.headline)
                .foregroundStyle(Color.pulseTextPrimary)

            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                ForEach(section.topics) { topic in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title)
                            .font(.subheadline.weight(.semibold))
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
                body: "La carte « Ce soir » vise ton prochain réveil prévu : celui d'aujourd'hui s'il n'est pas encore passé (il est 1 h du matin), sinon celui de demain. Chaque nuit passée a la sienne, en bas de la carte « Nuit ». Dans tous les cas, on part du réveil prévu du jour concerné et on remonte de ta durée idéale de sommeil, du temps d'éveil habituel dans la nuit et du délai d'endormissement. Le réveil prévu est celui que tu as réglé pour ce jour de la semaine ; à défaut, ton lever habituel en semaine ou le week-end (au moins trois nuits de ce type), puis ton lever habituel général. Ce n'est jamais l'heure à laquelle tu t'es réellement réveillé. La durée idéale de la nuit tient compte de son contexte — énergie au coucher, stress de la veille, sport récent, sommeil des nuits précédentes — mais ne s'écarte jamais de plus d'une heure de ta durée idéale générale ; faute d'assez de nuits (moins de trente) ou de contexte, c'est cette dernière qui est utilisée. Pour une nuit à venir, le contexte est estimé à ton heure de coucher habituelle (ou à maintenant si elle est passée)."),
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
        HelpSection(title: "Activités", topics: [
            HelpTopic(
                title: "Rogner une séance",
                body: "« Modifier » permet de corriger le début et la fin, par exemple si tu as oublié d'arrêter la montre. La courbe de fréquence cardiaque montre la zone gardée ; le reste est estompé. Les calories sont recalculées sur la zone gardée et réparties d'après ta fréquence cardiaque."),
            HelpTopic(
                title: "Fusionner des activités",
                body: "« Sélectionner » puis « Fusionner » réunit des activités du même sport qui ne se chevauchent pas, par exemple une course coupée par erreur. Le temps écoulé entre les deux n'est pas compté. Depuis le menu d'une ligne, « Fusionner avec la suivante » est proposé quand la suivante est du même sport et commence moins de 30 minutes après."),
            HelpTopic(
                title: "Séparer ou rétablir",
                body: "« Séparer » défait une fusion et rend les activités d'origine. « Rétablir l'original » retire la fenêtre rognée, le sport corrigé, le nom et la note, en gardant la fusion."),
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
        HelpSection(title: "Programme", topics: [
            HelpTopic(
                title: "Choisir un objectif",
                body: "Sèche, maintien ou masse sèche : un geste active l'entraînement et l'alimentation ensemble. Les jours d'entraînement proposés suivent tes habitudes des huit dernières semaines (marches exclues) ; « Personnaliser » permet de les choisir."),
            HelpTopic(
                title: "Entraînement",
                body: "Un programme d'entraînement pilote les séances et le calendrier. Les séances se cochent avec les activités importées de la montre. L'écran Programme affiche un résumé par domaine ; touche-le pour le détail, et ⓘ pour l'objectif, les notes et l'arrêt du programme. En fin de bloc, un bilan des séances s'affiche une fois ; il reste accessible par « Bilan » dans le détail."),
            HelpTopic(
                title: "Alimentation",
                body: "Un programme d'alimentation pilote les cibles de la page Nutrition : les cibles du jour sont recadrées par ses règles. Certains programmes fixent aussi le bilan énergétique (maintien, léger surplus, perte), qui remplace alors le déficit des réglages tant qu'ils sont actifs. La frise montre les sept derniers jours — la part des cibles tenues, en pointillés quand rien n'est saisi."),
            HelpTopic(
                title: "Sommeil",
                body: "Un programme de sommeil lit les nuits de la montre : celles déjà importées sont comparées à ses critères, il n'y a rien à saisir."),
        ]),
        HelpSection(title: "Profil", topics: [
            HelpTopic(
                title: "À quoi il sert",
                body: "Année de naissance, taille et sexe servent au métabolisme de base, à l'âge physiologique et à l'objectif calorique dynamique. Le poids se saisit jour par jour sur la page Nutrition."),
        ]),
        HelpSection(title: "Réveil & coucher", topics: [
            HelpTopic(
                title: "Réveil dans l'app",
                body: "Une ligne par jour : l'interrupteur active le réveil, l'heure se règle sur la ligne (enregistrée une fraction de seconde après le dernier changement). Ce n'est pas une alarme de l'app Horloge iOS (illisible depuis une app tierce) mais un rappel sonore : faute d'alertes critiques, il ne sonne ni en silencieux ni en boucle."),
            HelpTopic(
                title: "Lien avec le coucher",
                body: "Pour chaque jour où un réveil est réglé, l'heure de coucher conseillée se calcule sur cette heure plutôt que sur ton lever habituel."),
            HelpTopic(
                title: "Envoyer à la montre",
                body: "« Envoyer à la montre » règle en plus une alarme native sur la Venu 2 à partir du même planning, quand la montre est connectée."),
        ]),
        HelpSection(title: "Données & synchro", topics: [
            HelpTopic(
                title: "Où vivent les données",
                body: "Téléphone : tout reste sur l'iPhone, rien n'est envoyé à Pulse. Pulse : chaque synchro part vers le serveur. Les deux : gardé sur l'iPhone ET envoyé à Pulse, avec repli automatique sur le téléphone si Pulse est injoignable. L'iPhone récupère aussi les fichiers que Pulse détient et lui n'a pas (« Récupération depuis Pulse », app ouverte au premier plan ; interrompue puis reprise au retour dans l'app). Les activités y gardent leur fichier ; les mesures et le sommeil ne sont pas conservés."),
            HelpTopic(
                title: "Changer de stockage",
                body: "Chaque changement demande confirmation. Les saisies faites en Téléphone ne partent vers Pulse qu'en « Les deux » : passer de Téléphone à Pulse les laisse sur l'iPhone, passer d'abord par « Les deux » les envoie."),
            HelpTopic(
                title: "Purger les données de l'iPhone",
                body: "Efface la base de l'iPhone (mesures et saisies) et les fichiers de la montre déjà reçus par Pulse ; Pulse n'est jamais touché. Les fichiers que Pulse n'a pas reçus sont gardés, puis relus pour reconstruire la base (hors mode Pulse) ; en « Les deux », ce que Pulse détient est de nouveau récupéré. Bloquée tant que des saisies n'ont pas été reçues par Pulse — « Les deux » les envoie — ou que des fichiers de la montre n'existent plus que sur l'iPhone. Les aliments de départ sont recréés ; en « Les deux », le prochain échange récupère ce que Pulse détient."),
            HelpTopic(
                title: "Source de collecte",
                body: "« garmin-bridge » : le serveur parle à la montre en Bluetooth, sans téléphone. « iPhone (BLE) » : cette app récupère les fichiers et les envoie à Pulse. Basculer ne fait rien perdre — la déduplication par empreinte évite les doublons."),
            HelpTopic(
                title: "Jeton d'envoi",
                body: "Synchronisation › Jeton d'envoi (source iPhone). Le jeton de l'iPhone doit être celui du serveur, sinon Pulse refuse les envois : « À mettre à jour » indique qu'ils diffèrent, et « Utiliser le jeton du serveur » les aligne. Régénérer, côté serveur, invalide l'ancien jeton."),
            HelpTopic(
                title: "Montre",
                body: "La page affiche l'état du lien, les appareils à choisir tant qu'aucune montre n'est connectée, l'alerte d'envoi (avec « Renvoyer »), la synchro manuelle et le calendrier. « Diagnostic » réunit le technique : radio, connexion, listing GFDI, temps réel et affichage de tous les périphériques ; les métriques du lien sont aussi journalisées dans Console.app (subsystem « CleanYourRoom.all »). « Oublier l'appareil » demande confirmation."),
            HelpTopic(
                title: "Profil et adresse",
                body: "Le profil et l'adresse de Pulse s'enregistrent seuls : à chaque changement de sélecteur, à la validation du clavier ou en quittant la page."),
            HelpTopic(
                title: "Valeurs au tiret",
                body: "Un tiret « — » signale une absence de donnée sur la période : les valeurs ne descendent pas à zéro pour autant. Élargis la période ou synchronise la montre."),
        ]),
    ]
}

#Preview {
    HelpView()
}
