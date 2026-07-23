# 0004. Utiliser Cliopatria comme socle de frontières historiques, historical-basemaps en complément

Date : 2026-07-23
Statut : Accepté

## Contexte

Le projet veut afficher les zones d'influence des entités politiques à travers l'histoire. Les frontières anciennes sont floues par nature : il faut des polygones datés présentés comme zones d'influence semi-transparentes, pas comme des frontières exactes. Datasets étudiés (licences vérifiées) : Cliopatria/Seshat (CC BY 4.0, -3400 à 2024, 1600+ entités, ~14 000 polygones datés, GeoJSON), historical-basemaps d'A. Ourednik (GPL-3.0, -123 000 à ~2010, précision volontairement grossière), OpenHistoricalMap (CC0, couverture inégale), GeaCron et Euratlas (propriétaires), Seshat Equinox (CC BY-NC-SA).

## Décision

Nous allons utiliser Cliopatria (CC BY 4.0) comme socle mondial de frontières historiques (-3400 à 2024), complété par historical-basemaps (GPL-3.0, données) pour la période antérieure à -3400. Les polygones sont importés dans PostGIS (`atlas.polities` + `atlas.borders` avec from_year/to_year), affichés en aplats semi-transparents avec un traitement visuel assumant l'imprécision. Attribution des deux sources dans les crédits de la carte.

## Conséquences

Positives :
- Couverture mondiale continue de la préhistoire à nos jours, licences compatibles AGPL, formats GeoJSON directement importables.
- Le requêtage "frontières actives à l'année A" est un simple filtre from_year/to_year indexé.

Négatives :
- Précision hétérogène et parfois contestable (les frontières historiques sont un sujet académiquement disputé) ; assumé et signalé dans l'UI (transparence, mention de la source et de l'imprécision).
- Deux datasets à réconcilier à la jonction -3400 ; accepté, la jonction est traitée côté import.
- La GPL-3.0 de historical-basemaps s'applique aux données importées ; compatible avec notre AGPL-3.0, mais à documenter clairement sur la page Sources.

## Alternatives considérées

**OpenHistoricalMap seul.** CC0 et vivant, mais couverture mondiale trop inégale pour un fond systématique ; retenu seulement comme complément optionnel futur.

**GeaCron ou Euratlas.** Qualité éditoriale reconnue mais licences propriétaires ; rejeté.

**Dessiner nos propres frontières.** Coût de curation immense (leçon du projet Running Reality) ; rejeté pour le MVP, l'éditeur collaboratif de phase 2 pourra amender localement.
