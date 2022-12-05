# MC714.P2

Usa [Minikube](https://minikube.sigs.k8s.io/docs/).

Inicialização (roda o minikube, opcional caso já esteja em execução):

    make k8s

Faça build da imagem docker:

    eval $(minikube docker-env)
    docker build -t mc714_p2:2.0.0 .

Faça deploy do serviço no k8s:

    make deploy

Abra um tunel pelo minikube (permite enviar requisições HTTP para o serviço):
  
    make tunnel

Copie a URL da saída e exporte como variável de ambiente da seguinte forma:

    export SERVICE_URL=<URL>

É possível interagir com o serviço de várias formas:

- Ler logs dos pods: `make logs`

- Escalar a aplicação: `make scale REPLICAS=<N>`

- Ler a lista de acceptors do Paxos (atualiza a cada 2s): `make watch-acceptors`

- Ler a lista de valores decidida por consenso (atualiza a cada 2s): `make watch-ledger`

- Inserir um valor na lista: `make propose VALUE="foo"`

- Inserir dados em paralelo: `make generate-data PARALELLISM=1 N=1000` (1 thread, 1000 valores)
