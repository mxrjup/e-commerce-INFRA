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

Chaque topic a son **topic de rebut**, même nom suivi de `.dlt`
(`order.paid.dlt`, ...) : un service y publie un message dont le traitement a
échoué après ses tentatives. Le script les crée avec les autres, six topics en
tout. Sans eux, un message en échec serait rejoué indéfiniment.

**Rejouer le Job.** Modifier le `ConfigMap` puis faire `kubectl apply` met le
script à jour **sans relancer le Job** : un Job déjà terminé ne se rejoue pas.
Le Job s'efface donc **une heure après sa fin** (`ttlSecondsAfterFinished`), et
le `kubectl apply` suivant le recrée et rejoue le script. Dans l'heure, ou pour
un Job créé avant ce réglage, le supprimer d'abord :

```bash
kubectl delete job kafka-create-topics --ignore-not-found
kubectl apply -f k8s/kafka/topics-job.yaml
```

Le script est idempotent, le rejouer ne touche à rien.

> **Avant de déployer e-commerce-BACK#109** (configuration Kafka commune), les
> DLT doivent exister sur le cluster : sans eux, un message en échec bloque sa
> partition. Le Job actuel date d'avant ce réglage : le supprimer puis
> réappliquer, comme ci-dessus, et vérifier `kubectl logs job/kafka-create-topics`
> (six topics).

**Disque.** La rétention est bornée par partition : 128 Mio, plus un segment
actif de 64 Mio. Avec 18 partitions (3 topics, 3 DLT, 3 partitions chacun),
le pire cas est d'environ 3,4 Gio sur le volume de 5 Gio. **Tout nouveau topic
ajoute 6 partitions** (lui et son DLT) : refaire ce calcul dans
`statefulset.yaml`.

## Plateforme applicative

PostgreSQL, Keycloak, les services du back-end et l'Ingress, rassemblés par
`k8s/kustomization.yaml` et appliqués d'une seule commande. Kafka n'en fait pas
partie : il s'applique **avant**, voir la section précédente.

| Objet | Rôle |
|---|---|
| `StatefulSet/postgres`, `Service/postgres` | une instance, `postgres:5432`, PVC de 5 Gio ; **un rôle et une base par service** |
| `ConfigMap/postgres-init` | crée ces rôles et bases au premier démarrage |
| `Deployment/keycloak`, `Service/keycloak` | Keycloak en mode production sous `/auth`, `keycloak:8080` |
| `ConfigMap/keycloak-realm-*` | le realm **déployé**, `k8s/keycloak/ecommerce-realm.json` |
| `Deployment` et `Service` `api-gateway`, `cart-service`, `order-service` | images GHCR du back-end |
| `NetworkPolicy/backend-from-gateway` | les services n'acceptent que la gateway et les autres services |
| `NetworkPolicy/postgres-from-clients` | la base n'accepte que les services et Keycloak |
| `Ingress/ecommerce` | l'hôte public : `/api` → gateway, `/auth/realms/ecommerce` et `/auth/resources` → Keycloak |
| `ConfigMap/platform-config-*` | `PUBLIC_HOST` et `PUBLIC_URL`, lus par les pods |

### Avant le premier déploiement

**1. L'hôte public**, dans `k8s/params.env` : `PUBLIC_HOST` et `PUBLIC_URL`,
le même hôte. Il est reporté dans l'Ingress, fixe l'issuer des jetons, les
redirections autorisées du back-office et l'origine CORS. La valeur versionnée,
`ecommerce.example.test`, est **à remplacer** par celle de l'école.

**2. Les Secrets**, jamais versionnés. Un modèle par Secret dans
`k8s/secrets.example/` ; copier dans `k8s/secrets/` (ignoré par git), remplir,
puis :

```bash
mkdir -p k8s/secrets && cp k8s/secrets.example/*.env.example k8s/secrets/
for f in k8s/secrets/*.env.example; do mv "$f" "${f%.example}"; done
# remplir chaque fichier (openssl rand -base64 24 pour les mots de passe), puis :
kubectl create secret generic postgres-credentials --from-env-file=k8s/secrets/postgres-credentials.env
kubectl create secret generic keycloak-admin       --from-env-file=k8s/secrets/keycloak-admin.env
kubectl create secret generic keycloak-smtp        --from-env-file=k8s/secrets/keycloak-smtp.env
kubectl create secret generic stripe               --from-env-file=k8s/secrets/stripe.env
# facultatif, Google et Apple :
kubectl create secret generic keycloak-idp         --from-env-file=k8s/secrets/keycloak-idp.env
```

| Secret | Obligatoire | Lu par |
|---|---|---|
| `postgres-credentials` | oui | PostgreSQL, Keycloak, les services |
| `keycloak-admin` | oui | Keycloak, au premier démarrage |
| `keycloak-smtp` | oui | Keycloak : le realm exige la vérification des emails |
| `stripe` | oui | `order-service` |
| `keycloak-idp` | non | Keycloak, fournisseurs Google et Apple |
| `ecommerce-tls` | voir 3. | l'Ingress |
| `ghcr-pull` | voir 4. | le kubelet, pour tirer les images |

> **Pas de `"` ni de `\`** dans les valeurs de `keycloak-smtp` et
> `keycloak-idp` : Keycloak les recopie telles quelles dans le JSON du realm
> avant de le lire, et l'import échoue.

**3. Le certificat TLS.** L'Ingress présente le Secret `ecommerce-tls`. Avec
un certificat fourni :

```bash
kubectl create secret tls ecommerce-tls --cert=chemin/vers/cert.pem --key=chemin/vers/key.pem
```

Avec cert-manager sur le cluster, ajouter à l'Ingress l'annotation
`cert-manager.io/cluster-issuer: <nom>` : il crée le Secret seul. Sans aucun
des deux, Traefik présente son certificat auto-signé. **Sans TLS du tout**, le
realm refuse les connexions venant de l'extérieur (`sslRequired: external`) :
c'est voulu, ne pas l'assouplir.

> **Le certificat auto-signé ne sert qu'à vérifier le déploiement.** Les
> vérifications ci-dessous passent avec `curl -k`, mais Stripe ne livre pas
> ses webhooks à un certificat non reconnu et l'application mobile refuse la
> connexion : le premier paiement échouerait. Pour un usage réel, un
> certificat signé par une autorité reconnue (fourni, ou via cert-manager).

**4. L'accès aux images.** Si les paquets GHCR du back-end sont privés, un
jeton GitHub avec le seul droit `read:packages` :

```bash
kubectl create secret docker-registry ghcr-pull --docker-server=ghcr.io \
  --docker-username=<compte-github> --docker-password=<jeton>
```

### Déployer

```bash
kubectl kustomize k8s/                       # relire ce qui sera appliqué
kubectl apply -k k8s/ --dry-run=server       # aucun avertissement attendu
kubectl apply -k k8s/
kubectl rollout status statefulset/postgres
kubectl rollout status deployment/keycloak   # une à deux minutes
kubectl get pods
```

Au **tout premier** déploiement, `cart-service` et `order-service` redémarrent
une fois : ils démarrent avant que PostgreSQL accepte les connexions. C'est
attendu.

Le tag des images se fixe dans la section `images` de `k8s/kustomization.yaml`
(`dev` pour l'instant). Les images sont publiées par la CI du back-end (`D03`
#54) sous `ghcr.io/mxrjup/e-commerce-back/<module>`.

### Vérifier

```bash
curl https://<PUBLIC_HOST>/auth/realms/ecommerce/.well-known/openid-configuration
# "issuer": "https://<PUBLIC_HOST>/auth/realms/ecommerce"
curl -i https://<PUBLIC_HOST>/api/orders          # 401 : jeton exigé
curl -i https://<PUBLIC_HOST>/auth/admin/         # 404 : console non publiée
```

### Keycloak

**L'adresse publique est celle du realm `ecommerce`, pas celle du serveur.**
Le realm porte `frontendUrl = PUBLIC_URL/auth` : ses jetons, pages de
connexion et liens d'email utilisent l'hôte public. Le serveur, lui, a pour
adresse celle du port-forward : c'est là que vivent le realm `master` et la
console d'administration, que l'Ingress ne publie pas. Publier `/auth/realms`
en entier exposerait la connexion des administrateurs à tout internet.

```bash
kubectl port-forward svc/keycloak 8180:8080
# console : http://localhost:8180/auth/admin, compte du Secret keycloak-admin
```

Le compte de `keycloak-admin` est temporaire (bandeau jaune dans la console) :
créer un compte d'administration nominatif dans le realm `master`, puis
supprimer le compte temporaire.

**Le realm déployé n'est pas celui du back-end.** C'est une copie de
`e-commerce-BACK/docker/keycloak/import/ecommerce-realm.json`, **sans les
comptes de démonstration**, avec ces différences :

| | Local (back-end) | Déployé (ici) |
|---|---|---|
| Vérification des emails | non | **oui**, avec `smtpServer` lu dans `keycloak-smtp` |
| Redirections de `web-bo` | `http://localhost:5173/*` | `PUBLIC_URL/*` |
| Redirections de `mobile-app` | `ecommerce://auth-callback`, `exp://*`, `http://localhost:8081/*` | `ecommerce://auth-callback` seulement |

Une modification de clients, de rôles ou de flux se reporte dans les deux
fichiers. Les valeurs d'environnement s'écrivent `${VARIABLE}` ou
`${VARIABLE:défaut}` : la forme `${env.VARIABLE}` n'est **pas** résolue par
Keycloak 26, qui garde alors la valeur par défaut ou le texte brut.

**Keycloak n'importe le realm que s'il n'existe pas.** Modifier le fichier
redémarre Keycloak, qui journalise `Realm 'ecommerce' already exists. Import
skipped` et garde l'ancienne configuration. Sur un cluster en service, une
modification se fait dans la console, puis se reporte dans le fichier pour le
prochain environnement neuf.

### PostgreSQL

Chaque service a **son rôle et sa base**, et ne peut pas se connecter à celle
d'un autre :

| Rôle | Base | Mot de passe (`postgres-credentials`) |
|---|---|---|
| `keycloak` | `keycloak` | `KEYCLOAK_DB_PASSWORD` |
| `cart_service` | `ecommerce_cart` | `CART_DB_PASSWORD` |
| `order_service` | `ecommerce_order` | `ORDER_DB_PASSWORD` |

Le script de `postgres-init` ne s'exécute qu'au **premier** démarrage, sur un
volume vide. Pour un nouveau service sur une base déjà initialisée : ajouter sa
ligne au script (pour les prochains environnements), sa clé au Secret, puis
créer rôle et base à la main :

```bash
kubectl exec -it postgres-0 -- psql -U postgres
# CREATE ROLE catalog_service LOGIN PASSWORD '...';
# CREATE DATABASE ecommerce_catalog OWNER catalog_service;
# REVOKE ALL ON DATABASE ecommerce_catalog FROM PUBLIC;
```

De même, changer un mot de passe dans le Secret ne change pas celui de la
base : `ALTER ROLE <rôle> PASSWORD '...'` dans `psql`, puis redémarrer le
service concerné.

### Ajouter un service

1. Un fichier `k8s/services/<service>.yaml` sur le modèle de `cart-service` :
   label `tier: backend`, même `securityContext`, `/tmp` en `emptyDir`.
2. Son entrée dans `resources` et dans `images` de `k8s/kustomization.yaml`.
3. Son rôle et sa base PostgreSQL, voir ci-dessus.
4. Sa route dans la gateway, côté back-end.

### Budget du namespace

| | CPU réservé | CPU limite | Mémoire réservée | Mémoire limite |
|---|---|---|---|---|
| Kafka | 250m | 1 | 1536 Mio | 1536 Mio |
| PostgreSQL | 100m | 500m | 512 Mio | 512 Mio |
| Keycloak | 250m | 1 | 1 Gio | 1 Gio |
| un service Java (×3 aujourd'hui) | 50m | 500m | 384 Mio | 512 Mio |
| **Total aujourd'hui** | **750m / 4** | **4 / 8** | **4224 Mio / 8 Gio** | **4608 Mio / 16 Gio** |

Les services consomment entre 170 et 240 Mio une fois démarrés. **La limite
CPU est la contrainte qui tient** : avec les six services encore à venir, à
500m chacun, le total atteint 7 cœurs sur 8, et 7,6 avec Kafka UI et
kafka-exporter (PR #4). Une mise à jour progressive
crée le nouveau pod avant d'arrêter l'ancien (`maxSurge: 1`) : il faut donc
toujours garder 500m de marge sous la limite, sinon la mise à jour reste
bloquée faute de quota.

### Ce qui reste à savoir

- **Prometheus (`D06` #17)** : s'il scrape les services depuis un autre
  namespace, `backend-from-gateway` devra l'autoriser.
- **Les pages de retour Stripe** (`STRIPE_SUCCESS_URL`, `STRIPE_CANCEL_URL`)
  pointent vers `PUBLIC_URL/checkout/...` : à confirmer avec le parcours de
  paiement mobile (`O11` #35).
- `cart-service` et `order-service` n'ont pas encore d'actuator : leurs sondes
  vérifient seulement que le port répond.
- Un second `kubectl apply -k` affiche encore `statefulset.apps/postgres
  configured` sans rien changer : limite connue de `kubectl apply` sur les
  `volumeClaimTemplates`, Kafka a la même.

## Kafka UI et monitoring Kafka

```bash
kubectl apply -f k8s/kafka-ui/
kubectl apply -f k8s/kafka-exporter/
```

| Objet | Rôle |
|---|---|
| `Deployment/kafka-ui`, `Service/kafka-ui` | interface web de Kafka, **en lecture seule**, 50m et 384 Mio réservés |
| `Deployment/kafka-exporter`, `Service/kafka-exporter` | métriques Kafka pour Prometheus sur `:9308/metrics`, 10m et 32 Mio réservés |
| `monitoring/grafana/dashboards/kafka.json` | le dashboard Grafana « Kafka » |

### Kafka UI

Topics, messages (corps et en-têtes), consumer groups et leur retard, topics
de rebut `*.dlt`. C'est l'outil pour comprendre un message en échec : dans un
DLT, le corps est intact et l'exception est dans les en-têtes `kafka_dlt-*`.

```bash
kubectl port-forward svc/kafka-ui 8090:8080
# puis http://localhost:8090
```

**Pas d'Ingress, volontairement.** Kafka UI n'a pas d'authentification à elle,
et les messages contiennent des identifiants de commande et d'utilisateur.
Passer par `port-forward`, c'est passer par les droits du kubeconfig. Elle est
aussi **en lecture seule** : ni création ni suppression de topic, ni
publication. Le Kafka UI du Docker Compose local, lui, peut publier un message
de test.

### kafka-exporter

Interroge le broker comme un client et expose, pour chaque topic et partition,
les offsets (d'où le débit et le volume) et, pour chaque consumer group, le
retard. Rien à configurer côté Kafka.

Le `Service` porte les annotations `prometheus.io/scrape`. Le Prometheus du
cluster (`D06` #17) doit le scraper, par ces annotations ou par un job
explicite :

```yaml
scrape_configs:
  - job_name: kafka-exporter
    static_configs:
      - targets: ["kafka-exporter:9308"]
```

### Le dashboard Grafana « Kafka »

`monitoring/grafana/dashboards/kafka.json`, à importer dans Grafana ou à
provisionner. Il choisit sa source Prometheus par une variable : aucun
identifiant de datasource n'est codé en dur.

| Section | Ce qu'on y lit |
|---|---|
| Vue d'ensemble | brokers, topics, **messages en DLT** (rouge dès 1), retard total, consommateurs actifs, partitions sous-répliquées |
| Topics | messages publiés par seconde, messages conservés |
| Consumer groups | retard et débit de traitement par groupe et topic |
| Rebut (DLT) | arrivées dans les DLT, et contenu de chacun |

Filtres par topic et par consumer group en haut de page.

Ce qui doit faire réagir : un **DLT non vide** (un traitement a échoué après
ses rejeux, lire le message dans Kafka UI), un **retard qui monte sans
redescendre** (le consommateur est arrêté ou trop lent, voir « consommateurs
actifs »), et des **brokers à 0** (l'exporteur ne joint plus Kafka).

Le retard d'un groupe n'apparaît qu'une fois qu'il a commité au moins un
offset : un service qui n'a encore rien consommé n'est pas dans la liste.

### Prévisualiser le dashboard en local

Le Prometheus et le Grafana du cluster arrivent avec `D06`. En attendant, et
pour mettre au point un dashboard, `monitoring/local/` lance kafka-exporter,
Prometheus et Grafana branchés sur le Kafka de la stack du back-end :

```bash
# dans e-commerce-BACK
docker compose up -d
# ici
docker compose -f monitoring/local/compose.yaml up -d
```

Grafana sur <http://localhost:3030> (`admin` / `admin`), dossier
« e-commerce », dashboard « Kafka ». Prometheus sur <http://localhost:9090>.
Le dashboard est lu directement depuis `monitoring/grafana/dashboards/` :
une modification du JSON apparaît en une dizaine de secondes, sans
redémarrage. Pour garder une modification faite dans l'interface : *Export* →
*Export as JSON* et remplacer le fichier.

## Pas encore en place

| Sujet | Issue |
|---|---|
| Images des services sur GHCR | `D03` #54 |
| Back-office web sur l'Ingress (`/`) | `T06` #11 |
| Déploiement automatique et rollback par tag | `D05` #38 |
| Prometheus et Grafana sur le cluster, dashboards applicatifs | `D06` #17 |
| Documentation de déploiement complète | `D08` #89 |
