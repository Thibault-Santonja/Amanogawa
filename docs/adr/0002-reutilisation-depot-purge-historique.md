# 0002. Réutiliser le dépôt GitHub avec purge des blobs lourds de l'historique

Date : 2026-07-23
Statut : Accepté

## Contexte

Le dépôt GitHub public `Thibault-Santonja/Amanogawa` contenait le prototype 2020-2022. Son historique pesait 105 MiB : `venv/` complet, wheel GDAL Windows, binaires OSGeo4W64 et `db.sqlite3` commités à l'époque. Chaque clone futur (CI comprise) aurait porté ce poids. Par ailleurs, le dossier local `~/Dev/Amanogawa` contenait un site HTML statique (musique/articles) sans rapport, dont le remote (`Amanogawas.git`) n'existe plus.

## Décision

Nous allons conserver le dépôt GitHub existant et son historique de commits, mais réécrire cet historique avec git-filter-repo pour en retirer `venv/`, `external_components/`, `db.sqlite3`, `.idea/`, `node_modules` et les wheels. Le site HTML sans rapport est archivé dans `docs/archive/2022-site-html/`. La branche par défaut devient `main`.

Garde-fous : bundle git complet sauvegardé avant réécriture (`~/Dev/amanogawa-backup-2026-07-23.bundle`) ; le code du prototype (hors binaires) reste consultable dans l'historique.

## Conséquences

Positives :
- Dépôt passé de 105 MiB à environ 660 KiB, 67 commits conservés.
- Continuité du projet (étoiles, URL, historique de l'idée depuis 2020).

Négatives :
- SHAs réécrits : tout clone antérieur devient divergent ; accepté car le dépôt n'avait aucun autre contributeur actif.
- Le prototype n'est plus dans l'arbre de travail ; accepté, il reste dans l'historique.

## Alternatives considérées

**Nouveau dépôt vierge.** Plus simple, mais perd l'historique et l'identité du projet ; rejeté par choix du mainteneur.

**Garder l'historique tel quel.** Zéro risque, mais 105 MiB de binaires morts imposés à chaque clone pour toujours ; rejeté au nom du critère de poids du projet.
