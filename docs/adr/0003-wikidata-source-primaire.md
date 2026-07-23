# 0003. Utiliser Wikidata (via QLever) comme source primaire, Wikipedia pour les résumés

Date : 2026-07-23
Statut : Accepté

## Contexte

Le projet a besoin d'événements historiques structurés : date, localisation, relations entre événements, résumé, lien vers l'article. L'étude des sources (docs/studies/2026-07-sources-donnees-historiques.md) mesure sur Wikidata environ 4,77 M d'entités "événement", dont ~68 000 avec date et coordonnées directes (P625) et ~420 000 avec date et coordonnées via le lieu (P276 -> P625). Le endpoint SPARQL officiel (WDQS) timeoute à 60 s sur les requêtes globales ; le miroir QLever les exécute en quelques secondes. Les résumés ne sont pas dans Wikidata mais dans Wikipedia (API REST `page/summary`, CC BY-SA 4.0), dont les limites pour trafic anonyme se durcissent en 2026.

## Décision

Nous allons :
- extraire les événements depuis Wikidata (arbre Q1190554 filtré par liste noire de classes parasites) via le endpoint QLever pour les extractions massives, WDQS restant réservé aux petites requêtes fraîches ;
- résoudre les coordonnées en cascade : P625 direct, sinon P276 -> P625, en traçant la provenance ;
- ingérer en même temps les relations P361, P155/P156, P793, P1344 (P828/P1542 en bonus) ;
- enrichir paresseusement et en batch lent via l'API REST Wikipedia (fr avec repli en), avec User-Agent identifié, cache persistant et attribution CC BY-SA ;
- synchroniser mensuellement, par pipeline Oban idempotent basé sur les QID.

## Conséquences

Positives :
- Données structurées CC0, corpus de départ substantiel (~420 000 événements géolocalisables), relations typées pour tracer les liens sur la carte.
- QLever supprime le mur des timeouts ; l'ingestion reste reproductible (bascule possible vers les dumps JSON à terme).

Négatives :
- QLever est rechargé depuis les dumps (pas temps réel) ; accepté, l'histoire bouge lentement.
- L'arbre Q1190554 est bruité : la liste noire de classes demande une curation continue.
- Dépendance à des services tiers gratuits ; mitigée par le cache local persistant et la possibilité de passer aux dumps.

## Alternatives considérées

**Scraper Wikipedia directement.** Données non structurées, parsing fragile des infobox, contraire à l'étiquette Wikimedia ; rejeté.

**Dumps JSON Wikidata dès le départ.** Reproductible mais lourd (100+ Go compressés) et complexe pour un MVP ; reporté à une phase ultérieure si le besoin de reproductibilité totale se confirme.

**Base événementielle propriétaire (GeaCron...).** Licences fermées incompatibles avec un projet AGPL ; rejeté.
