# e-commerce — infrastructure

Manifests Kubernetes et outillage de déploiement de la plateforme.

## Accès au cluster

Le namespace et son kubeconfig sont fournis par l'école. **Aucun identifiant de
cluster ne doit entrer dans ce dépôt** : le kubeconfig reste sur votre machine,
et le `.gitignore` est là pour éviter l'accident.

```bash
export KUBECONFIG=$PWD/<votre-kubeconfig>.yaml
kubectl get pods
```

Le kubeconfig fixe déjà le namespace par défaut : les manifests ne portent donc
pas de champ `namespace`, et s'appliquent là où pointe votre contexte.

Le namespace est contraint : **4 cœurs et 8 Gio réservés** (8 cœurs et 16 Gio
en limites), **40 pods**, **20 services** (ni NodePort ni LoadBalancer),
**10 volumes pour 50 Gio** (dont au plus 3 volumes et 10 Gio sur la classe
`local-path` ; la classe par défaut est `longhorn`). Ce budget est partagé par
tous les services : chaque manifest doit déclarer des `requests` modestes,
sinon un déploiement bloque faute de quota.

Les pods doivent respecter le niveau `baseline` des Pod Security Standards
(refus sinon) ; le niveau `restricted` est audité et donne un avertissement.

## Déployer la plateforme

`D04` (mxrjup/e-commerce-BACK#88) : Postgres, Keycloak, les services du
back-end et l'Ingress. Kafka a sa propre section, plus bas.

```text
k8s/
├── postgres/        StatefulSet + PVC 5 Gio, une base par service
├── keycloak/        mode production, realm importé au démarrage
├── services/        config commune, api-gateway, cart-service, order-service
└── ingress.yaml     api.<domaine> → gateway, auth.<domaine> → Keycloak
```

### 1. Les Secrets, créés à la main

Aucun identifiant n'est dans le dépôt. À créer une fois par namespace, avec de
vrais mots de passe :

```bash
kubectl create secret generic postgres-credentials \
  --from-literal=username=ecommerce --from-literal=password="$(openssl rand -base64 24)"
kubectl create secret generic keycloak-admin \
  --from-literal=username=admin --from-literal=password="$(openssl rand -base64 24)"

# Optionnels : le service démarre sans, mais le paiement et les connexions
# Google/Apple n'aboutissent pas.
kubectl create secret generic stripe --from-literal=secret-key=sk_test_...
kubectl create secret generic keycloak-idp \
  --from-literal=google-client-id=... --from-literal=google-client-secret=... \
  --from-literal=apple-client-id=...  --from-literal=apple-client-secret=...
```

Le mot de passe de l'administrateur Keycloak ne sert qu'au **premier**
démarrage : le changer ensuite se fait dans la console, pas dans le Secret.

### 2. Le realm Keycloak, depuis le dépôt back-end

Le realm n'est **pas copié** ici : on crée le ConfigMap depuis le fichier de
référence, `e-commerce-BACK/docker/keycloak/import/ecommerce-realm.json`
(cloné à côté de ce dépôt) :

```bash
kubectl create configmap keycloak-realm \
  --from-file=ecommerce-realm.json=../e-commerce-BACK/docker/keycloak/import/ecommerce-realm.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

Comme en local, Keycloak **n'importe le realm que s'il n'existe pas déjà** en
base : mettre le ConfigMap à jour ne change rien à un realm déjà créé.

> **Prérequis : mxrjup/e-commerce-BACK#115.** Avant ce correctif, le realm
> ignorait `KEYCLOAK_FRONTEND_URL` et annonçait toujours l'issuer
> `http://localhost:8180` : la gateway refusait alors tous les jetons. Créer le
> ConfigMap depuis un `dev` qui contient #115.

### 3. Le domaine

`ecommerce.local` est un exemple. Le remplacer par le domaine du cluster à
**deux endroits** : les URL de `k8s/services/config.yaml` et les hôtes de
`k8s/ingress.yaml`. L'URL publique de Keycloak devient le `iss` des jetons :
si la gateway et les navigateurs ne voient pas la même, toute requête
authentifiée est refusée.

### 4. Appliquer, dans l'ordre

```bash
kubectl apply -f k8s/kafka/service.yaml -f k8s/kafka/statefulset.yaml   # section Kafka
kubectl apply -f k8s/postgres/
kubectl rollout status statefulset/postgres
kubectl apply -f k8s/services/config.yaml -f k8s/keycloak/
kubectl rollout status deploy/keycloak        # 1 à 2 min au premier démarrage
kubectl apply -f k8s/services/ -f k8s/ingress.yaml
```

Puis vérifier :

```bash
curl http://api.<domaine>/actuator/health                                  # {"status":"UP",...}
curl http://auth.<domaine>/realms/ecommerce/.well-known/openid-configuration  # "issuer" = http://auth.<domaine>/realms/ecommerce
```

### Les images

Les services tirent `ghcr.io/mxrjup/e-commerce-back/<service>:dev`, publié par
la CI du back-end (`D03` mxrjup/e-commerce-BACK#54) à chaque merge sur `dev`,
avec `imagePullPolicy: Always`. **Les paquets sont publics** : ils héritent de
la visibilité du dépôt `e-commerce-BACK`, et se tirent sans identifiants
(vérifié après le premier push). Si le dépôt devenait privé, donner au
namespace un jeton en lecture :

```bash
kubectl create secret docker-registry ghcr-pull --docker-server=ghcr.io \
  --docker-username=<utilisateur> --docker-password=<jeton read:packages>
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
```

Un déploiement de production épinglera un tag de version ou `sha-<commit>`
plutôt que `dev` (`D05` #38).

### Ce qui est exposé, et ce qui ne l'est pas

| Entrée | Vers | Pourquoi |
|---|---|---|
| `api.<domaine>/**` | `api-gateway` | la gateway seule décide de ce qui est public |
| `auth.<domaine>/realms/**`, `/resources/**` | Keycloak | connexion, jetons, découverte OIDC |
| `auth.<domaine>/admin` | — | **pas exposée** |

La console d'administration de Keycloak se consulte par port-forward :

```bash
kubectl port-forward svc/keycloak 8180:8080   # puis http://localhost:8180/admin
```

Postgres, Kafka, Kafka UI et les services eux-mêmes n'ont pas d'entrée : ils
ne sont joignables que depuis le namespace.

**TLS** : à ajouter dans `ingress.yaml` quand le cluster fournit un certificat,
en passant les URL de `config.yaml` en `https`.

### Budget du namespace

Mesuré sur un cluster k3s configuré avec le même quota et les mêmes Pod
Security Standards que celui de l'école :

| | requests CPU | requests mémoire | limits CPU | limits mémoire |
|---|---|---|---|---|
| Kafka, Kafka UI, kafka-exporter | 310m | 1,9 Gio | 1,6 | 2,1 Gio |
| Postgres | 100m | 256 Mio | 0,5 | 512 Mio |
| Keycloak | 250m | 768 Mio | 1 | 1 Gio |
| 3 services | 300m | 1,1 Gio | 1,5 | 2,25 Gio |
| **Total actuel** | **960m / 4** | **4 Gio / 8** | **4,6 / 8** | **5,8 Gio / 16** |
| + 6 services à venir | 1,56 | 6,3 Gio | 7,6 | 10,3 Gio |

**La mémoire réservée et les limites CPU sont les deux contraintes** : avec
les neuf services, il reste environ 1,7 Gio réservables pour Prometheus et
Grafana (`D06` #17). C'est pourquoi chaque service est limité à 500m de CPU :
il démarre en ~30 s au lieu de 18 s, mais un cœur par service dépasserait le
quota. Les services consomment 160 à 230 Mio au repos pour 384 Mio réservés :
la réservation pourra baisser si la place manque.

Les sondes de `cart-service` et `order-service` sont des sondes TCP en
attendant leur Actuator (`D06` #17) ; la gateway en a déjà un.

## Kafka

Un broker unique en mode KRaft, avec un volume persistant.

```bash
kubectl apply -f k8s/kafka/service.yaml
kubectl apply -f k8s/kafka/statefulset.yaml
kubectl rollout status statefulset/kafka

kubectl apply -f k8s/kafka/topics-job.yaml
kubectl logs job/kafka-create-topics
```

| Objet | Rôle |
|---|---|
| `Service/kafka` | adresse des applications, `kafka:9092` |
| `Service/kafka-headless` | nom DNS stable du pod, `kafka-0.kafka-headless` |
| `StatefulSet/kafka` | le broker, 250m et 1,5 Gio réservés, PVC de 5 Gio |
| `ConfigMap/kafka-topics` | le script de création des topics |
| `Job/kafka-create-topics` | joue ce script une fois le broker prêt |

Les applications se connectent à **`kafka:9092`**, volontairement le même nom
que dans le Docker Compose local : la configuration d'un service est donc
identique en local et sur le cluster.

**Un StatefulSet et non un Deployment** : le broker a besoin d'une identité
stable et de retrouver son volume après un redémarrage, sinon il repart sur un
cluster vide. C'est aussi pourquoi il s'annonce sous son nom DNS plutôt que
sous son adresse IP, qui change à chaque redémarrage.

**La liste des topics est dupliquée** entre le `ConfigMap` d'ici et
`e-commerce-BACK/docker/kafka/create-topics.sh`, qui sert de référence pour la
stack locale. Les deux doivent rester synchronisées ; le tableau des topics et
de leurs producteurs est dans le README du dépôt back-end.

**Rejouer le Job** demande de le supprimer d'abord, un Job étant immuable :

```bash
kubectl delete job kafka-create-topics --ignore-not-found
kubectl apply -f k8s/kafka/topics-job.yaml
```

Le script est idempotent, le rejouer ne touche à rien.

## Pas encore en place

| Sujet | Issue |
|---|---|
| Déploiement automatique et rollback par tag | `D05` #38 |
| Prometheus, Grafana et dashboards | `D06` #17 |
| Documentation de déploiement complète | `D08` #89 |
