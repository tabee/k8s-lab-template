---
title: Öffentliche Fassung
---

# Öffentliche Fassung des Repos

Dieses Repo gibt es in zwei Fassungen: einer **privaten** (mit persönlichen
Werten, Adressen und den echten verschlüsselten Secrets) und einer **öffentlichen**,
die nur neutrale Platzhalter enthält. Die öffentliche Fassung ist die, aus der
Freunde ihr eigenes Lab bauen ([Lab für Freunde](../tutorials/lab-for-friends.md)).

Sie entsteht nie von Hand, sondern aus dem committeten Stand der privaten Fassung
durch einen Export, den ein **Wächter** prüft. Die Werkzeuge dafür sind
nur in der privaten Fassung vorhanden und gehören nicht zu dieser.


## Secrets gehören nicht in die öffentliche Fassung

Der Export lässt den Ordner `secrets/` vollständig weg. Was darin kein Ciphertext ist (`README.md`,
`kustomization.yaml`, `ksops.yaml`, `*.sops.yaml.example`), liegt in der öffentlichen Fassung unter `secrets.example/`;
`lab.sh init` legt daraus `secrets/` an, wenn es fehlt, und `scripts/ci-tests.sh` testet gegen eine so ergänzte Kopie. Wächter,
Baumprüfung und Security-Scan lehnen jeden Pfad unter `secrets/` ab. `secrets_repo_url` und der `repoURL` der Apps
`secrets-*` zeigen in der öffentlichen Fassung auf einen neutralen Platzhalter
(`ssh://git@git.example.org/YOUR-NAME/k8s-lab-secrets.git`). Wie der Ciphertext in ein privates Secrets-Repo kommt
und wie ein Neuaufbau aus der öffentlichen Fassung geht: [Privates Secrets-Repo](private-secrets-repo.md).
