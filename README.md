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

## Pas encore en place

| Sujet | Issue |
|---|---|
| Manifests des services, Postgres, Keycloak, Ingress | `D04` #88 |
| Déploiement automatique et rollback par tag | `D05` #38 |
| Prometheus, Grafana et dashboards | `D06` #17 |
| Documentation de déploiement complète | `D08` #89 |
