# 0006. Modéliser le temps avec HistoricalDate (année astronomique signée + précision)

Date : 2026-07-23
Statut : Accepté

## Contexte

Le projet couvre de la préhistoire (centaines de milliers d'années avant notre ère) à aujourd'hui. Le type `date` de PostgreSQL ne descend pas sous l'an -4713 et les types date des langages supposent des calendriers modernes. Wikidata encode ses dates avec une précision explicite (0 = milliard d'années ... 11 = jour), une convention astronomique (1 BCE = année 0) et des pièges connus : précision masquée par le raccourci `wdt:`, décalage d'un an des années négatives entre RDF et JSON, faux "1er janvier" massifs, calendrier julien d'affichage. Afficher "1er janvier -0750" pour une date connue au siècle près serait une faute historiographique.

## Décision

Nous allons représenter toute date historique par un embedded schema `HistoricalDate` : `year` (entier signé, convention astronomique), `month` et `day` (nuls sauf si precision >= 10), `precision` (échelle Wikidata 0-11), `calendar` (grégorien/julien, affichage seulement). En base : colonnes plates (`begin_year`, `begin_month`, `begin_day`, `begin_precision`, ...) pour indexation et tri par `(year, month NULLS FIRST, day NULLS FIRST)`. La normalisation (décalage RDF, troncature des faux 1er janvier) se fait dans l'adaptateur d'ingestion, testée par property-based tests. L'affichage respecte toujours la précision ("VIIIe siècle av. J.-C.", jamais un jour inventé).

## Conséquences

Positives :
- Tout l'axe temporel du projet (frise symlog, filtres, tri, gradient) repose sur un modèle unique, indexable, testé.
- La précision portée partout permet un affichage honnête et des filtres corrects.

Négatives :
- Plus verbeux qu'un simple champ date (4 colonnes par borne) ; accepté, c'est le prix de la correction.
- Les comparaisons intra-année ne sont définies que si les deux bornes ont precision >= 10 ; accepté et codé explicitement.

## Alternatives considérées

**PostgreSQL `date` ou `timestamp`.** Plage insuffisante pour la préhistoire ; rejeté d'emblée.

**Année décimale en float.** Simple pour la frise mais perd la précision et crée des égalités flottantes douteuses ; rejeté pour le stockage (utilisable ponctuellement côté rendu).

**Type composite PG custom.** Élégant mais complexifie migrations et outillage Ecto pour un bénéfice marginal vs colonnes plates ; rejeté.
