# Feature Flags API — containerização

## Sobre a entrega

Esta entrega acrescenta uma camada completa de containers para a API Node.js + TypeScript existente, sem modificar seu código ou dependências. Um único `Dockerfile` oferece os estágios `dev`, `build` e `production`; Compose fornece serviços separados para o ciclo de desenvolvimento e para execução da imagem publicada.

No desenvolvimento, Compose aguarda o PostgreSQL, executa as migrações na inicialização e oferece sincronização de `src/` e rebuild quando os manifestos npm mudam. Em produção, a imagem contém somente dependências de runtime e código compilado; o entrypoint aplica as migrações antes de iniciar o servidor.

## Imagem no Docker Hub

- Repositório: [deividroger/fc4-desafio-docker-node-api](https://hub.docker.com/r/deividroger/fc4-desafio-docker-node-api)
- Tags publicadas: `1.0.0` e `latest`
- Pull: `docker pull deividroger/fc4-desafio-docker-node-api:1.0.0`
- Digest do manifest index: `sha256:dc434d98a91801784e36fbed5cb59da5c529873e9e375d679aaf5cb73e32993b` (tags semver e `latest`).
- Plataformas verificadas: `linux/amd64` e `linux/arm64`; o index inclui attestations de SBOM e provenance.
- Comparação local em 11/11/2026, medida com `docker image ls` após builds sem `--network=none`: `dev` (`fc4-desafio-docker-node-api:validation-dev-20261111`, ID `38ce559cdaa2`) **298 MB**; `production` (`fc4-desafio-docker-node-api:validation-production-20261111`, ID `6963f9128db9`) **246 MB**. A imagem dev ficou **52 MB maior**; production está abaixo do limite de 350 MB. Essas tags são locais de validação, não publicadas.

O digest é o index multiarch; os manifestos de plataforma e attestations podem ser inspecionados com o comando abaixo.

## Decisões técnicas

- **Base:** `node:22.23.4-alpine3.23` tem tags explícitas de Node e Alpine e uma base enxuta adequada à aplicação. `node:22.23.4-bookworm-slim` foi considerada como alternativa: oferece ecossistema baseado em glibc e pode facilitar compatibilidade de binários nativos, mas traz mais componentes e tende a aumentar a imagem. Alpine usa musl, então dependências nativas devem ser verificadas; as dependências atuais são instaladas para a plataforma-alvo. O estágio base atualiza pacotes Alpine (`apk upgrade`) para incluir correções de segurança disponíveis.
- **Cache:** `package.json` e `package-lock.json` são copiados antes do código e `npm ci` usa cache BuildKit em `/root/.npm`. Mudanças só no código reutilizam a camada de dependências. O estágio `build` compila TypeScript; `production-deps` instala apenas dependências de runtime.
- **Correções observadas pelo Scout:** o scan inicial encontrou `proxy-addr` abaixo da versão corrigida `2.0.8`; como os manifestos da aplicação são protegidos, `production-deps` instala explicitamente essa versão compatível com a faixa declarada, sem alterar os arquivos do repositório. O npm é removido da imagem final porque não é necessário em runtime.
- **Sinais e encerramento:** o entrypoint de produção usa `exec` para que o Node receba SIGTERM diretamente. A verificação de saúde usa o `fetch` nativo do Node, sem adicionar `curl` ou `wget`.
- **Supply chain:** o comando de publicação abaixo pede manifest multi-plataforma, SBOM e provenance. Esses metadados só podem ser confirmados no registry depois de uma publicação bem-sucedida.

## Como rodar (desenvolvimento)

Requer Docker Engine/Desktop recente, Compose v2 e Buildx.

Execute o bloco como script `sh`: em caso de falha ele encerra o shell com status não zero. Ajuste a porta se `PORT` no `.env` não for 3000.

```sh
cp .env.example .env || exit 1
docker compose up --build --wait || exit 1
http_200() {
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$1") || return 1
  [ "$status" = 200 ]
}
ready=0
for attempt in $(seq 1 30); do
  if http_200 http://localhost:3000/health; then ready=1; break; fi
  [ "$attempt" -eq 30 ] || sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "Erro: readiness expirou após 30 tentativas" >&2
  exit 1
fi
http_200 http://localhost:3000/health || { echo "Erro: /health não retornou HTTP 200" >&2; exit 1; }
http_200 http://localhost:3000/flags || { echo "Erro: /flags não retornou HTTP 200" >&2; exit 1; }
```

O serviço `app` espera o healthcheck do PostgreSQL, aplica as migrações e inicia `npm run dev`. Para sincronizar alterações de `src/` sem rebuild e reconstruir após alterações nos manifestos:

```sh
docker compose up --watch
```

Em cópia temporária, `up --watch` sincronizou `src/` e reconstruiu o app após alteração em `package.json`; o banco permaneceu saudável e a API voltou a responder. A falha anterior com `watch --no-up` e override não foi reproduzida nesse fluxo, mas sua causa não foi isolada. A alteração de `package-lock.json` ainda não foi testada; veja a tabela de validação.

A rede de desenvolvimento é nomeada pelo Compose com o prefixo do projeto, para evitar compartilhamento acidental de DNS e banco entre projetos. Instalações anteriores que usavam a rede de nome fixo `flags-network` podem precisar recriar seus containers ao adotar essa configuração; os dados continuam no volume nomeado do projeto.

Para disponibilizar o Adminer em <http://localhost:8081>:

```sh
docker compose --profile tools up --build --wait
```

Conecte-se no Adminer com servidor `db` e as credenciais locais do `.env`. O UID do processo da API pode ser conferido com `docker compose exec app id -u` (a imagem usa o usuário não-root `node`).

## Como rodar (produção)

O `.env.example` contém somente credenciais de desenvolvimento local, úteis também para a avaliação local do Compose de produção. Em produção real, use um gerenciador de secrets e credenciais próprias.

Execute também este bloco como script `sh`; ele falha se o Compose ou qualquer endpoint falhar, inclusive para códigos HTTP diferentes de 200.

```sh
cp .env.example .env || exit 1
docker compose -f compose.prod.yaml up -d --wait || exit 1
http_200() {
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$1") || return 1
  [ "$status" = 200 ]
}
http_200 http://localhost:3000/health || { echo "Erro: /health não retornou HTTP 200" >&2; exit 1; }
http_200 http://localhost:3000/flags || { echo "Erro: /flags não retornou HTTP 200" >&2; exit 1; }
docker compose -f compose.prod.yaml ps || exit 1
```

O Compose de produção consome a tag semver, não faz build, mantém dados em volume nomeado e define restart policy e limites de recursos. As migrações são executadas pelo entrypoint da imagem.

## Segurança e supply chain

O usuário configurado na imagem é `node`, não root. Para inspecionar usuário, healthcheck e labels OCI:

```sh
docker image inspect deividroger/fc4-desafio-docker-node-api:1.0.0 \
  --format 'User={{.Config.User}} Healthcheck={{json .Config.Healthcheck}} Labels={{json .Config.Labels}}'
```

Build e publicação multiarch autorizada para Docker Hub (requer login, Buildx multi-plataforma e acesso ao registry):

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --target production \
  --build-arg VERSION=1.0.0 \
  --tag deividroger/fc4-desafio-docker-node-api:1.0.0 \
  --tag deividroger/fc4-desafio-docker-node-api:latest \
  --sbom=true --provenance=true --push .
```

Confira os manifestos e compare o digest resultante à tag `latest`:

```sh
docker buildx imagetools inspect deividroger/fc4-desafio-docker-node-api:1.0.0
docker buildx imagetools inspect deividroger/fc4-desafio-docker-node-api:latest
```

### Inspeção de attestations (instrução)

O comando abaixo é **somente inspeção manual**: percorre os manifestos de attestation apontados pelo index e imprime o `predicateType` de cada camada in-toto (requer `jq`). Não falha necessariamente se um tipo estiver ausente ou se um comando do pipeline falhar; não prova completude, autenticidade nem assinatura das attestations. É uma instrução, não uma execução feita nesta revisão:

```sh
IMAGE=deividroger/fc4-desafio-docker-node-api:1.0.0
docker buildx imagetools inspect --raw "$IMAGE" |
  jq -r '.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") | .digest' |
  while IFS= read -r digest; do
    docker buildx imagetools inspect --raw "${IMAGE%@*}@$digest" |
      jq -r '.layers[].annotations["in-toto.io/predicate-type"] // empty'
  done
```

Examine manualmente a saída para procurar SBOM pelo predicate SPDX (por exemplo, `https://spdx.dev/Document`) e provenance pelo predicate SLSA (prefixo `https://slsa.dev/provenance/`, por exemplo, `/v1` ou `/v0.2`). A presença de um tipo não comprova a presença do outro, nem valida os conteúdos ou suas assinaturas. Para medir a imagem amd64:

```sh
docker pull --platform linux/amd64 deividroger/fc4-desafio-docker-node-api:1.0.0
docker image ls deividroger/fc4-desafio-docker-node-api:1.0.0
```

### Docker Scout

Saída stdout completa de `docker scout cves` para a imagem publicada: [`reports/scout-cves.txt`](reports/scout-cves.txt). Em 11/11/2026, Scout v1.19.0 analisou o manifesto `linux/amd64` `9e088a8df4ea` do index acima e encontrou **0 CRITICAL, 0 HIGH, 1 MEDIUM e 0 LOW**. A saída foi comparada byte a byte com o relatório existente e coincidiu exatamente (1.338 bytes; SHA-256 `9365506ff8d4c93d772d760ac6cf6a34cbb24c02bda6a9e69496079046fba922`). Mensagens de progresso e sugestões são emitidas em stderr e não fazem parte do arquivo. O filtro `--only-severity critical --only-fixed` não encontrou pacotes vulneráveis; seus totais filtrados não representam as demais severidades.

Única CVE remanescente no resultado consultado: **CVE-2025-60876**, severidade MEDIUM, pacote Alpine `ssl_client`/BusyBox `1.37.0-r30`; o Scout indicou “Fixed version: not fixed”. Acompanhe atualizações da imagem Alpine/Node e reanalise ao reconstruir.

Para reproduzir e substituir o relatório:

```sh
docker scout cves registry://deividroger/fc4-desafio-docker-node-api:1.0.0 > reports/scout-cves.txt
docker scout cves --only-severity critical --only-fixed registry://deividroger/fc4-desafio-docker-node-api:1.0.0
```

## Validação

Cada linha abaixo corresponde a um critério de aceite do README-base. Os comandos de runtime devem ser executados em uma cópia temporária do projeto e com um nome de projeto Compose exclusivo se não se deseja reutilizar os volumes locais. Não use `down -v` em dados que queira preservar.

Os blocos de verificação revisados abaixo e nas seções de execução são instruções: não foram reexecutados nesta revisão. Evidências anteriores não são prova de execução desses novos comandos.

| Critério de aceite | Comando reproduzível | Evidência / estado |
|---|---|---|
| Dockerfile único na raiz, com estágios `dev`, `build` e `production` | `grep -nE '^FROM .* AS (dev|build|production)$' Dockerfile` | Passou: os três estágios estão declarados no mesmo Dockerfile. |
| Nenhuma imagem base sem tag ou com `latest` | `grep -nE '^(FROM|[[:space:]]+image:)' Dockerfile compose.yaml compose.prod.yaml` | Passou por inspeção: tags explícitas em todas as referências. |
| `.dockerignore` exclui `node_modules`, `dist`, `.git` e `.env` | `grep -nE '^(node_modules|dist|\.git|\.env\*)$' .dockerignore` | Passou: também exclui `reports`. |
| Instalações usam cache BuildKit do npm | `grep -n -- '--mount=type=cache,target=/root/.npm' Dockerfile` | Passou: as instalações nos estágios de dependências usam cache. |
| Build dos estágios `dev` e `production` conclui | `docker build --target dev --tag fc4-desafio-docker-node-api:validation-dev-20261111 .`<br>`docker build --target production --build-arg VERSION=validation-20261111 --tag fc4-desafio-docker-node-api:validation-production-20261111 .` | **Passou nesta validação**, sem `--network=none`; ambas as imagens foram construídas localmente. |
| `cp .env.example .env` e Compose dev deixam a API pronta, migrada, com `GET /flags` 200 | Bloco em “Como rodar (desenvolvimento)”, com polling e verificação de HTTP 200 em `/health` e `/flags` | Evidência anterior em cópia temporária: migração `001 - create-flags` confirmada e endpoints responderam 200. `up --wait` sozinho não espera readiness da API dev. |
| `db` com healthcheck e `app` aguardando `service_healthy` | `docker compose config` | Passou em configuração dos dois Compose nesta validação, usando uma cópia temporária com `.env.example`. |
| Watch sincroniza `src/` e reconstrói ao mudar `package.json` | `docker compose up --watch` | Passou em cópia temporária para mudança de `src/server.ts` e `package.json`; `package-lock.json` não faz parte deste critério e não foi exercitado. |
| Adminer somente no profile `tools`, disponível em `localhost:8081` | `docker compose --profile tools up --build --wait`<br>`status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:8081) && test "$status" = 200` | Profile declarado; subida e HTTP não foram repetidos nesta validação. |
| `docker compose exec app id -u` não retorna zero | `docker compose exec app id -u` | Evidência anterior: UID 1000 em dev e production. |
| `.env` ignorado e `.env.example` versionado com valores funcionais | `git check-ignore .env`<br>`git ls-files --error-unmatch .env.example` | `.env` está ignorado e o exemplo contém credenciais apenas locais; **o `.env.example` está atualmente não rastreado**, então a parte “versionado” ainda depende de adicioná-lo a um commit. |
| Registry lista `linux/amd64` e `linux/arm64` | `docker buildx imagetools inspect deividroger/fc4-desafio-docker-node-api:1.0.0` | Evidência anterior no Docker Hub: ambas as plataformas listadas. |
| Registry exibe attestations SBOM e provenance | Inspeção manual na subseção “Inspeção de attestations”: `docker buildx imagetools inspect --raw` e `jq` | Evidência anterior no registry; a inspeção não foi executada nesta revisão e não comprova completude nem assinatura. Não foram geradas/publicadas novas attestations. |
| Tags `1.0.0` e `latest` apontam ao mesmo digest | `docker buildx imagetools inspect deividroger/fc4-desafio-docker-node-api:1.0.0`<br>`docker buildx imagetools inspect deividroger/fc4-desafio-docker-node-api:latest` | Evidência anterior no Docker Hub: digest index igual. |
| Pull amd64 e imagem production de até 350 MB | `docker pull --platform linux/amd64 deividroger/fc4-desafio-docker-node-api:1.0.0`<br>`docker image ls deividroger/fc4-desafio-docker-node-api:1.0.0` | Production local recém-buildada: 246 MB. O dado publicado de 246 MB também consta na evidência anterior; nenhuma imagem foi enviada nesta validação. |
| Imagem production tem usuário não-root, healthcheck e quatro labels OCI | `docker image inspect fc4-desafio-docker-node-api:validation-production-20261111 --format 'User={{.Config.User}} Healthcheck={{json .Config.Healthcheck}} Labels={{json .Config.Labels}}'` | Evidência anterior de imagem production local: `User=node`, healthcheck e quatro labels. |
| Com banco acessível, app production fica healthy pelo healthcheck da imagem | Bloco em “Como rodar (produção)”: `up -d --wait`, verificação HTTP 200 e `ps` | Passou anteriormente em projeto temporário com banco novo; healthchecks de app e banco ficaram healthy. |
| `docker stop` encerra em menos de 10 segundos sem SIGKILL | Bloco “Verificação de shutdown” abaixo | Exige container inicialmente Running, tempo inferior a 10 s e exit code 0. Evidência anterior: 0,52 s dev e 0,41 s production, com exit code 0; o bloco revisado não foi executado nesta revisão. |
| `reports/scout-cves.txt` contém saída completa de Scout para a imagem publicada | `docker scout cves registry://deividroger/fc4-desafio-docker-node-api:1.0.0` | Relatório existente comparado byte a byte à saída stdout consultada anteriormente; não foi substituído nesta validação. |
| Zero CRITICAL com correção disponível | `docker scout cves --only-severity critical --only-fixed registry://deividroger/fc4-desafio-docker-node-api:1.0.0` | Evidência anterior: filtro sem pacotes; consulte a ressalva sobre CVE MEDIUM abaixo. |
| CVEs HIGH e CRITICAL sem correção, se existirem, estão justificadas | `docker scout cves registry://deividroger/fc4-desafio-docker-node-api:1.0.0` | Relatório consultado anteriormente: 0 HIGH e 1 MEDIUM (`CVE-2025-60876`, sem correção indicada); detalhado na seção Docker Scout. |
| Compose production usa tag semver, sem `build` | `docker compose -f compose.prod.yaml config` | Passou na configuração temporária nesta validação; usa `deividroger/fc4-desafio-docker-node-api:1.0.0`. |
| `app` e `db` production têm restart policy e limites de CPU/memória | `docker compose -f compose.prod.yaml config` | Passou por inspeção: restart e limites definidos nos dois serviços. |
| Sem bind mount de código; PostgreSQL usa volume nomeado | `docker compose -f compose.prod.yaml config` | Passou por inspeção: volume nomeado `postgres-data`, sem bind mount de código. |
| Fluxo production deixa API migrada/saudável com `GET /flags` 200 | Bloco em “Como rodar (produção)”, com verificação de HTTP 200 em `/health` e `/flags` | Passou anteriormente em projeto temporário com banco novo; app e banco healthy e endpoints 200. |
| README contém todas as seções obrigatórias | `grep -nE '^## (Sobre a entrega|Imagem no Docker Hub|Decisões técnicas|Como rodar|Segurança e supply chain|Validação)' README.md` | Passou: seções listadas estão presentes. |
| README tem link Docker Hub e comando `docker pull` | `grep -nE 'hub.docker.com|docker pull' README.md` | Passou. |
| README justifica a base de produção comparada a uma alternativa | `grep -nE 'Base:|bookworm-slim' README.md` | Passou: comparação com `node:22.23.4-bookworm-slim`. |
| Seção Validação mapeia cada critério a verificações | Tabela desta seção; valide a presença com `grep -n 'Critério de aceite' README.md` | Passou nesta revisão: há uma linha por critério do checklist base e comandos associados. |
| Código protegido não foi alterado | `git diff --exit-code HEAD -- src package.json package-lock.json tsconfig.json` | Confira também arquivos não rastreados em `src/`; nenhum arquivo protegido alterado na verificação desta revisão. |
| Sem credenciais hardcoded nos Dockerfiles/Compose; exemplo contém somente credenciais locais | `grep -nE '(PASSWORD|SECRET|TOKEN)[=:]' Dockerfile compose.yaml compose.prod.yaml`<br>`grep -nE '^(PORT|DB_HOST|DB_PORT|DB_USER|DB_PASSWORD|DB_NAME)=' .env.example` | Passou por inspeção: arquivos de container referenciam variáveis; valores de desenvolvimento estão apenas em `.env.example`. |

### Verificação de shutdown

Em uma cópia/projeto Compose temporário com o app em execução, rode o bloco como script `sh`. Ele **para o app**; não o use em containers que não queira parar. Para produção, substitua a primeira linha por `app_id=$(docker compose -f compose.prod.yaml ps -q app) || exit 1`.

```sh
app_id=$(docker compose ps -q app) || exit 1
[ -n "$app_id" ] || { echo "Erro: nenhum app em execução" >&2; exit 1; }
python3 -c '
import json, subprocess, sys, time
c = sys.argv[1]
def state():
    return json.loads(subprocess.check_output(
        ["docker", "inspect", "--format", "{{json .State}}", c], text=True))
if not state()["Running"]:
    sys.exit("Erro: app não estava Running antes do stop")
start = time.monotonic()
subprocess.run(["docker", "stop", "-t", "10", c], check=True)
elapsed = time.monotonic() - start
after = state()
code = after["ExitCode"]
running = after["Running"]
print(f"elapsed={elapsed:.2f}s; Running={running}; exit={code}")
if running or elapsed >= 10 or code != 0:
    sys.exit("Erro: shutdown não foi gracioso")
' "$app_id" || exit 1
```

O exit code 0 é mais restritivo que apenas excluir 137 (SIGKILL). O tempo inclui a execução do comando `docker stop`.

## Estado da validação desta entrega

Em 11/11/2026, Docker Desktop 4.58.0, Engine 29.1.5 e Compose v5.0.1: testes em cópia temporária com projetos `flagsvalidate94812dev` e `flagsvalidate94812prod`, `.env.example` e overrides fora do repositório. As portas foram alocadas dinamicamente em loopback (62327 em dev e 62326 em production no primeiro teste), sem usar a porta 3000 do host. Em dev, o override também substituiu o nome fixo da rede `flags-network` por uma rede exclusiva. Os volumes criados tinham os respectivos labels de projeto e foram removidos com seus containers e redes após o teste; recursos anteriores não foram parados nem removidos. O `npm ci` no build dev temporário registrou ainda 3 vulnerabilidades no audit (1 moderada, 1 alta e 1 crítica); não confundir esse conjunto de dependências com o resultado Scout da imagem publicada.

No follow-up, na mesma versão de Docker e Compose, `docker compose -p <projeto> up --watch` foi executado sem override em cópias temporárias, com `PORT` alterado no `.env` temporário para evitar a porta 3000 ocupada. Antes da correção, o projeto `flagswatcha7a5ce2a6a` reutilizou a rede fixa preexistente e emitiu aviso; apesar disso, o rebuild de `package.json` passou sem recriar o banco. Após remover o nome global da rede em `compose.yaml`, o projeto `flagswatchdc4aa2a6fb` criou sua própria rede e passou nos testes de sync e rebuild descritos acima. Os containers, volumes, rede própria, imagens temporárias e cópias criados pelo follow-up foram removidos; a rede preexistente foi preservada. O cache compartilhado de build não foi limpo. Esses testes não reexecutaram o cenário anterior com `watch --no-up` e override nem o rebuild de `package-lock.json`.

### Reteste local dos targets

Em 11/11/2026, os builds que haviam ficado `BLOCKED` somente porque o validator tentara desabilitar a rede foram executados localmente **sem `--network=none`** e concluíram com sucesso. Os tags de validação foram confirmados inexistentes antes do build e são exclusivos; nenhum tag preexistente foi sobrescrito. Comandos e resultados:

```sh
docker build --target dev --tag fc4-desafio-docker-node-api:validation-dev-20261111 .
docker build --target production --build-arg VERSION=validation-20261111 --tag fc4-desafio-docker-node-api:validation-production-20261111 .
docker image ls fc4-desafio-docker-node-api:validation-dev-20261111
docker image ls fc4-desafio-docker-node-api:validation-production-20261111
```

`docker image ls` reportou dev `298 MB` (ID `38ce559cdaa2`) e production `246 MB` (ID `6963f9128db9`): diferença medida de `52 MB`. Esses builds locais não alteraram tecnicamente a imagem Docker publicada, portanto ela não foi republicada. Nenhum commit ou push para o GitHub foi realizado.

Nesta revisão, `.env.example` e os demais novos arquivos de containerização e documentação continuam não rastreados; não houve stage, commit ou push. Versioná-los continua sendo uma ação pendente.
