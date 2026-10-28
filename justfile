# Points d'entrée du dépôt (règle commune : `just --list` avant d'agir). Outil bash sans build : gabarit scripts/gabarits/justfile.statique adapté.
set windows-shell := ["bash", "-c"]
set shell := ["bash", "-c"]

# Contrôle de syntaxe de hunt-a1.sh sans l'exécuter (aucun test unitaire n'existe, aucun lancement réel)
test:
    bash -n hunt-a1.sh

# shellcheck sur le script, fins de ligne CRLF du poste Windows retirées avant analyse (le dépôt est en LF)
lint:
    tr -d '\r' < hunt-a1.sh | npx --yes shellcheck -s bash -

# Rien à servir : un script bash lancé par cron, jamais en session (il crée une instance cloud réelle)
dev:
    echo "pas de serveur : lancer hunt-a1.sh crée une instance réelle, sur demande du propriétaire du compte seulement"

# Rien à construire : un seul fichier bash
build:
    echo "rien à construire"

# Outil à une seule branche : pas de staging, la release (tag) part d'un push de master
deploy-staging:
    echo "pas de staging : branche unique master, tag et release par release-please"
