# Catalogue de démonstration en production

Pour un **premier test** de la plateforme déployée, sans saisir de catalogue :
le jeu de démonstration du back-end (`catalog-service`,
`src/main/resources/demo/catalogue-demo.json`).

| Contenu | |
|---|---|
| Marques | 11 |
| Catégories | 4 racines et leurs sous-catégories |
| Univers, attributs | 4 et 4 |
| Produits | 19, avec 30 variantes, prix et stock |
| Photos | **aucune** (à ajouter par le back-office) |

## Charger

Prérequis : `catalog-service` déployé (`kubectl apply -k k8s/`) et son
catalogue **vide**.

```bash
export KUBECONFIG=$PWD/<votre-kubeconfig>.yaml
scripts/load-demo-catalog.sh
```

Le script :

1. redémarre `catalog-service` avec `SPRING_PROFILES_ACTIVE=demo` ;
2. attend dans ses journaux `Demonstration catalogue loaded: 19 products`
   (ou `Catalogue already has products` : rien n'est chargé) ;
3. **dans tous les cas**, même en cas d'erreur ou d'interruption, retire le
   profil et attend le redémarrage : le service ne reste jamais en `demo`.

Le chargement ne fait rien si le catalogue contient déjà un produit : relancer
le script est sans risque, et il n'écrase jamais un vrai catalogue.

Vérifier :

```bash
curl -s https://<PUBLIC_HOST>/api/catalog/products | head -c 300
kubectl get deployment catalog-service -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
# SPRING_PROFILES_ACTIVE ne doit plus apparaître
```

## Retirer

Le jeu de démonstration se supprime comme tout produit, depuis le
back-office : archiver les produits (un produit publié ne se supprime pas).
Pour repartir d'un catalogue vide sur un environnement de test seulement :
supprimer la base `ecommerce_catalog` et la recréer (README, « PostgreSQL »),
puis redémarrer `catalog-service`, qui rejoue ses migrations.

## À savoir

- Les marques sont réelles (Logitech, Razer, Sony…) et les prix inventés : à
  ne pas laisser sur une boutique ouverte au public.
- `kubectl apply -k k8s/` et le déploiement par tag du back-end ne remettent
  pas le profil : il n'est dans aucun manifest.
