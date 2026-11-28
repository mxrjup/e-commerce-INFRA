#!/usr/bin/env bash
# Remplit un catalogue VIDE avec les donnees de demonstration du back-end
# (catalog-service, profil « demo » : 11 marques, 19 produits, 30 variantes,
# sans photos), puis remet le service dans sa configuration normale.
#
#   KUBECONFIG=... scripts/load-demo-catalog.sh
#
# Le chargement ne fait rien si le catalogue contient deja un produit : le
# relancer est sans risque. Pour un premier test de la production, pas pour
# du vrai contenu. Voir docs/catalogue-demo.md.
#
# Variables :
#   KUBECONFIG       acces au cluster ; le namespace est celui du contexte
#   ROLLOUT_TIMEOUT  attente maximale d'un redemarrage, 300s par defaut
#   LOAD_TIMEOUT     attente maximale du chargement, en secondes, 300 par defaut
set -euo pipefail

deployment=catalog-service
rollout_timeout="${ROLLOUT_TIMEOUT:-300s}"
load_timeout="${LOAD_TIMEOUT:-300}"

loaded='Demonstration catalogue loaded'
skipped='Catalogue already has products'

kubectl get deployment "$deployment" >/dev/null

# Quoi qu'il arrive, y compris une erreur ou un Ctrl-C, le service repart sans
# le profil : en production, il ne doit jamais rester actif.
restore() {
    echo "Retour a la configuration normale de $deployment."
    kubectl set env deployment/"$deployment" SPRING_PROFILES_ACTIVE- >/dev/null
    kubectl rollout status deployment/"$deployment" --timeout="$rollout_timeout"
}
trap restore EXIT

echo "Redemarrage de $deployment avec le profil demo."
kubectl set env deployment/"$deployment" SPRING_PROFILES_ACTIVE=demo >/dev/null
kubectl rollout status deployment/"$deployment" --timeout="$rollout_timeout"

# Le chargement tourne au demarrage, avant que le service soit pret : une fois
# le rollout termine, la ligne de journal est deja la, ou le sera sous peu.
waited=0
while :; do
    logs=$(kubectl logs deployment/"$deployment" 2>/dev/null || true)
    if grep -q "$loaded" <<< "$logs"; then
        grep "$loaded" <<< "$logs" | tail -1
        break
    fi
    if grep -q "$skipped" <<< "$logs"; then
        echo "Le catalogue contient deja des produits : rien n'a ete charge."
        break
    fi
    if ((waited >= load_timeout)); then
        echo "Pas de trace du chargement apres ${load_timeout}s : voir kubectl logs deployment/$deployment." >&2
        exit 1
    fi
    sleep 5
    waited=$((waited + 5))
done
