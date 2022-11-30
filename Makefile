CONSISTENT=false
N=10000
PARALLELISM=8

.PHONY: k8s deploy tunnel watch-acceptors watch-ledger generate-data propose

k8s:
	@minikube start

deploy:
	@kubectl apply -f ./k8s/manifest.yml --namespace=mc714-p2

scale:
	@kubectl scale statefulset mc714-p2 --replicas=$(REPLICAS) -n mc714-p2

tunnel:
	@minikube service mc714-p2-http -n mc714-p2 --url

logs:
	@kubectl logs --max-log-requests=10 --prefix=true -f -l app=mc714-p2 -n mc714-p2

watch-acceptors:
	@watch 'curl -s -H "x-consistent-read: $(CONSISTENT)" $(SERVICE_URL)/paxos-acceptors | jq .'

watch-ledger:
	@watch 'curl -s -H "x-consistent-read: $(CONSISTENT)" $(SERVICE_URL)/ledger | jq .'

generate-data:
	@parallel -j $(PARALLELISM) make -s propose SERVICE_URL=$(SERVICE_URL) VALUE={} ::: $(shell seq 1 $N)
	@wait

propose:
	@curl -s \
		-H 'Content-Type: application/json' \
		-d "{\"value\": \"$(VALUE)\"}" \
		-w "$(VALUE) - %{response_code}\n" \
		$(SERVICE_URL)/decree
