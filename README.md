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

**Rejouer le Job** demande de le supprimer d'abord, un Job étant immuable :

```bash
kubectl delete job kafka-create-topics --ignore-not-found
kubectl apply -f k8s/kafka/topics-job.yaml
```

Le script est idempotent, le rejouer ne touche à rien.

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
| Manifests des services, Postgres, Keycloak, Ingress | `D04` #88 |
| Déploiement automatique et rollback par tag | `D05` #38 |
| Prometheus et Grafana sur le cluster, dashboards applicatifs | `D06` #17 |
| Documentation de déploiement complète | `D08` #89 |
