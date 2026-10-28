# Hunt A1

## Règles inconditionnelles
- Dépôt public MIT : tout ce qui est commité est lisible par le monde, historique compris ; aucun OCID, région, e-mail ni hostname réel (fichiers et messages de commit), les vraies valeurs vivent dans `~/hunt-a1.conf` ; les idées privées vont dans `IDEES.md` (ignoré).
- Jamais de lancement réel (`bash hunt-a1.sh`) sans demande explicite du propriétaire du compte : il crée (ou tente de créer) une instance cloud ; contrôles sans effet de bord : `just test`, `just lint`.
- Un seul fichier bash sans dépendance (pas de Python ni Node) ; README en anglais, descriptions de commit dans la langue de l'historique ; fonctionnement, état, limites du Free Tier : `docs/architecture.md` et README.
- Branche unique `master` (dépôt public, runner GitHub seulement, jamais auto-hébergé) : release-please tire tag et changelog des commits conventionnels, rien n'est déployé.

<!-- gen:debut -->
Dépôt `Moodtuner997/hunt-a1` (projet `hunt-a1`, hunt-a1, statut pause). Déploiement : aucun (pas de déploiement).
Avant toute action : `gh issue list --label etat` (l'issue État, vérité opérationnelle), `git fetch --prune`, `just --list` (points d'entrée uniformes : test, lint, dev, build, deploy-staging).
Tâches = issues GitHub ; état du dépôt = issue épinglée État ; mémoire longue = nœud `02-projets/hunt-a1.md` du second cerveau. Rien d'autre ne fait foi.
Enveloppe : PR vers `dev`, fusion si CI verte ; `staging` et `main` n'avancent que par tag (release.yml, release.sh). Secrets jamais lus. Généré par scripts/claude-md-gen.py : ne pas éditer ce bloc.
<!-- gen:fin -->

## Pièges
- Demander plus que le Free Tier (2 OCPU / 12 Go, 2 instances) donne `LimitExceeded` à chaque essai, remplit le log et la boîte mail : raison du coupe-circuit et de son mail unique (a5aaae5, 2026-07-22) ; README, `hunt-a1.conf.example`, script et `docs/architecture.md` restent alignés.
- Une ligne cron sans la chaîne `hunt-a1` n'est jamais retirée par `disable_cron` (filtre `grep -v hunt-a1`) : le script relancerait après succès.
- Aucune idée privée dans un fichier suivi : `IDEES.md` a dû être ignoré (0b1045f, 2026-10-12).
- Pas de workflow de revue à jeton sur ce dépôt public : une revue automatique a été retirée (bcd6f54, 2026-10-02).
- Les niveaux de log `INFO / RETRY / FATAL / WARN / SUCCESS / ERROR` sont cités par le README (`grep SUCCESS`) : ne pas les renommer.
- `shellcheck` absent du laptop : `just lint` retombe sur `npx shellcheck` (v0.11.0, mesuré le 2026-10-28).
- La branche distante `release-please--branches--master` subsiste après la release 1.0.2 (71d06f2, doublon du squash 83366a9) : à purger si `git log master..` n'y trouve que ce commit.
