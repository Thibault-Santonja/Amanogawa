# F04 -- Frise chronologique

> Phase 1 | Priorité P0 | Estimation : 1.5-2 semaines

## Résumé

La frise en bas de page : échelle symlog (l'histoire récente occupe plus de place que la préhistoire), fenêtre temporelle avec bornes déplaçables et fenêtre glissable, histogramme de densité des événements, et gradient de couleur bleu (début de fenêtre) vers rouge (fin de fenêtre) appliqué aux marqueurs de la carte et à la légende. La frise et la carte partagent le même état via la LiveView Explore.

Fondé sur les ADR 0005 (d3 en hook) et 0006 (modèle temporel).

## Analyse

### Architecture

- Module Elixir `Amanogawa.Atlas.TimeScale` : échelle symlog paramétrée (pivot vers -10 000, linéaire près du présent), conversions année <-> position normalisée [0,1] ; propriété testée (round-trip, monotonie, ancres connues : -100 000, -10 000, 0, 1000, 2000).
- Util JS miroir `assets/js/lib/time_scale.js` : MÊMES formules, testées contre les mêmes ancres (fixtures JSON partagées) pour garantir la cohérence Elixir/JS.
- `TimelineHook` : rendu d3 (axe gradué adaptatif : "100 ka BP", "VIIIe s. av. J.-C.", "1969"), brush custom pour la fenêtre, drag des bornes et du corps de fenêtre, debounce 150 ms avant `pushEvent("select_time_window")`.
- Histogramme de densité : `GET /api/events/histogram?from=&to=&buckets=` agrégé côté SQL (buckets en espace symlog), rendu en aires discrètes sous la frise.
- Gradient temporel : CSS custom properties (`--time-start-color`, `--time-end-color`) définies dans les tokens Tailwind ; la carte (expressions MapLibre) et la légende interpolent la MÊME rampe ; position d'un événement dans la fenêtre -> teinte.

### Affichage des dates

- Toujours respecter la précision (ADR 0006) : jamais de faux jour ; formatteur partagé (Gettext-ready) pour "il y a 100 000 ans", "VIIIe siècle av. J.-C.", "14 juillet 1789".

### Performance

- L'histogramme est une seule requête agrégée, cacheable par fenêtre arrondie.
- Le drag ne déclenche pas de fetch avant le debounce ; la carte anime l'opacité pendant l'attente.

## User Stories

- GIVEN la frise affichée, WHEN je resserre la fenêtre sur 1789-1815, THEN la carte n'affiche que les événements de la période, colorés du bleu (1789) au rouge (1815).
- GIVEN une fenêtre posée, WHEN je la fais glisser vers le passé, THEN carte et frise restent synchronisées sans à-coups (debounce, animations).
- GIVEN l'échelle complète, WHEN je regarde la frise, THEN les 10 000 dernières années occupent la majorité de l'espace et le paléolithique reste accessible.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #019 TimeScale symlog partagé Elixir + JS | 001-timescale-symlog.md | 12h |
| #020 TimelineHook : rendu frise + histogramme | 002-timelinehook-rendu.md | 16h |
| #021 Fenêtre temporelle : drag, resize, sync | 003-fenetre-temporelle.md | 12h |
| #022 Gradient temporel partagé (carte, frise, légende) | 004-gradient-temporel.md | 8h |

## Dépendances

- Prérequis : F02 (#006 pour le modèle temporel), F03 (#014, #015, #018).
- Sortie : critère de sortie du MVP.
